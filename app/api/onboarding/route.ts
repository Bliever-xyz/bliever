/**
 * app/api/onboarding/route.ts
 *
 * POST /api/onboarding
 * ────────────────────
 * Unified entry point for the user onboarding flow.
 *
 * This endpoint receives the completed dual-signature proof that a new user
 * possesses both identities simultaneously:
 *
 *   ① Social  identity – a Nostr keypair (secp256k1), generated client-side.
 *   ② Value   identity – a CDP ERC-4337 Smart Account on Base, created by
 *                        Coinbase Developer Platform via email / SMS / OAuth.
 *   ③ Binding proof    – Kind 30078 Nostr event (signed by nsec) + EIP-191
 *                        consent message (signed by the Smart Account).
 *
 * Client-side responsibilities (NOT handled here):
 *   - CDP authentication (email OTP / SMS / Google / Apple) via @coinbase/cdp-react.
 *   - Nostr keypair generation with crypto.getRandomValues().
 *   - PRF / WebCrypto encryption of the nsec in IndexedDB.
 *   - Building and signing the Kind 30078 event with nostr-tools.
 *   - Signing the EVM consent message via CDP signMessage hook.
 *
 * Server responsibilities (this file):
 *   - Validate the incoming payload shape.
 *   - Delegate full dual-signature verification to validateBindingPayload.
 *   - Return a structured response suitable for the indexer service.
 *
 * No data is persisted here. Persistence is the indexer's responsibility.
 *
 * ─── Request  ────────────────────────────────────────────────────────────────
 * Body (JSON): OnboardingPayload
 * {
 *   npub:         string           // hex Nostr public key
 *   evmAddress:   string           // CDP Smart Account address
 *   nostrEvent:   NostrBindingEvent
 *   evmSignature: `0x${string}`
 *   bindingId:    string           // UUID v4
 *   timestamp:    number           // unix seconds
 * }
 *
 * ─── Response ────────────────────────────────────────────────────────────────
 * 200 OnboardingSuccessResponse
 * {
 *   success:           true
 *   onboardingComplete: true
 *   bindingId:         string
 *   npub:              string
 *   evmAddress:        string    // EIP-55 checksummed
 *   verifiedAt:        number    // unix seconds
 * }
 *
 * 400 BindingErrorResponse  { success: false, reason: BindingErrorReason }
 * 500 BindingErrorResponse  { success: false, reason: "internal_error"   }
 */

import { NextRequest, NextResponse } from "next/server";
import type { OnboardingPayload, OnboardingResponse } from "@/lib/binding/schema";
import { validateBindingPayload } from "@/lib/binding/validator";

export async function POST(
  request: NextRequest,
): Promise<NextResponse<OnboardingResponse>> {
  // ── 1. Parse request body ─────────────────────────────────────────────────
  let payload: OnboardingPayload;

  try {
    payload = (await request.json()) as OnboardingPayload;
  } catch {
    return NextResponse.json(
      { success: false, reason: "invalid_payload" } as OnboardingResponse,
      { status: 400 },
    );
  }

  // ── 2. Presence guard (structural, not cryptographic) ─────────────────────
  if (
    !payload.npub ||
    !payload.evmAddress ||
    !payload.nostrEvent ||
    !payload.evmSignature ||
    !payload.bindingId ||
    typeof payload.timestamp !== "number"
  ) {
    return NextResponse.json(
      { success: false, reason: "invalid_payload" } as OnboardingResponse,
      { status: 400 },
    );
  }

  // ── 3. Full dual-signature validation ─────────────────────────────────────
  try {
    const result = await validateBindingPayload(payload);

    if (!result.valid) {
      return NextResponse.json(
        { success: false, reason: result.reason } as OnboardingResponse,
        { status: 400 },
      );
    }

    // ── 4. Success – return all fields an indexer needs to persist ───────────
    return NextResponse.json(
      {
        success: true,
        onboardingComplete: true,
        bindingId: payload.bindingId,
        npub: payload.npub,
        evmAddress: result.normalizedEvmAddress,
        verifiedAt: Math.floor(Date.now() / 1000),
      } as OnboardingResponse,
      { status: 200 },
    );
  } catch (err) {
    console.error("[onboarding] Unexpected error:", err);
    return NextResponse.json(
      { success: false, reason: "internal_error" } as OnboardingResponse,
      { status: 500 },
    );
  }
}