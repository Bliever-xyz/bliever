/**
 * app/api/bind-identity/route.ts
 *
 * POST /api/bind-identity
 * ────────────────────────
 * Standalone dual-signature binding verification.
 *
 * Used when re-linking identities (e.g. user rotates Nostr key or migrates
 * to a new Smart Account) without going through the full onboarding flow.
 *
 * The binding protocol requires TWO independent cryptographic proofs:
 *
 *   Proof A – Nostr → EVM claim:
 *     A Kind 30078 Nostr event signed by the user's nsec, whose JSON content
 *     asserts ownership of the EVM address.
 *
 *   Proof B – EVM → Nostr consent:
 *     An EIP-191 personal_sign message signed by the CDP Smart Account,
 *     asserting consent to be linked with the npub.
 *
 * Both proofs reference the same `bindingId` (UUID v4) and `timestamp`,
 * preventing:
 *   - Replay attacks (timestamp window of ±5 minutes).
 *   - Impersonation (attacker needs BOTH keys simultaneously).
 *   - Address hijacking (EVM signature requires passkey/OAuth interaction).
 *
 * No data is persisted here. The indexer service should call this endpoint
 * and store the result only after receiving a 200 response.
 *
 * ─── Rate limiting ───────────────────────────────────────────────────────────
 * An in-memory sliding-window limiter caps each source IP at 10 requests per
 * minute. For multi-instance deployments this must be replaced with a shared
 * backing store (e.g. Redis via Upstash). Exceeding the limit returns 429 with
 * reason "rate_limited".
 *
 * ─── Request  ────────────────────────────────────────────────────────────────
 * Body (JSON): BindIdentityPayload
 * {
 *   npub:         string
 *   evmAddress:   string
 *   nostrEvent:   NostrBindingEvent
 *   evmSignature: `0x${string}`
 *   bindingId:    string
 *   timestamp:    number
 * }
 *
 * ─── Response ────────────────────────────────────────────────────────────────
 * 200 BindingSuccessResponse
 * 400 BindingErrorResponse  (see BindingErrorReason for all codes)
 * 429 BindingErrorResponse  { reason: "rate_limited" }
 * 500 BindingErrorResponse  { reason: "internal_error" }
 */

import { NextRequest, NextResponse } from "next/server";
import type {
  BindIdentityPayload,
  BindingResponse,
} from "@/lib/binding/schema";
import { validateBindingPayload } from "@/lib/binding/validator";

// ─── Rate limiting ────────────────────────────────────────────────────────────
// Simple in-memory sliding-window limiter (per source IP).
// Replace the backing store with Redis for multi-instance deployments.
const RL_MAX_REQUESTS = 10;
const RL_WINDOW_MS = 60_000; // 1 minute

const _rlStore = new Map<string, { count: number; resetAt: number }>();

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = _rlStore.get(ip);
  if (!entry || now >= entry.resetAt) {
    _rlStore.set(ip, { count: 1, resetAt: now + RL_WINDOW_MS });
    return false;
  }
  if (entry.count >= RL_MAX_REQUESTS) return true;
  entry.count += 1;
  return false;
}

export async function POST(
  request: NextRequest,
): Promise<NextResponse<BindingResponse>> {
  // ── 0. Rate limit ─────────────────────────────────────────────────────────
  const ip =
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  if (isRateLimited(ip)) {
    return NextResponse.json(
      { success: false, reason: "rate_limited" } as BindingResponse,
      { status: 429 },
    );
  }

  // ── 1. Parse request body ─────────────────────────────────────────────────
  let payload: BindIdentityPayload;

  try {
    payload = (await request.json()) as BindIdentityPayload;
  } catch {
    return NextResponse.json(
      { success: false, reason: "invalid_payload" } as BindingResponse,
      { status: 400 },
    );
  }

  // ── 2. Presence guard ─────────────────────────────────────────────────────
  if (
    !payload.npub ||
    !payload.evmAddress ||
    !payload.nostrEvent ||
    !payload.evmSignature ||
    !payload.bindingId ||
    typeof payload.timestamp !== "number"
  ) {
    return NextResponse.json(
      { success: false, reason: "invalid_payload" } as BindingResponse,
      { status: 400 },
    );
  }

  // ── 3. Dual-signature validation ──────────────────────────────────────────
  try {
    const result = await validateBindingPayload(payload);

    if (!result.valid) {
      return NextResponse.json(
        { success: false, reason: result.reason } as BindingResponse,
        { status: 400 },
      );
    }

    return NextResponse.json(
      {
        success: true,
        bindingId: payload.bindingId,
        npub: payload.npub,
        evmAddress: result.normalizedEvmAddress,
        verifiedAt: Math.floor(Date.now() / 1000),
      } as BindingResponse,
      { status: 200 },
    );
  } catch (err) {
    console.error("[bind-identity] Unexpected error:", err);
    return NextResponse.json(
      { success: false, reason: "internal_error" } as BindingResponse,
      { status: 500 },
    );
  }
}