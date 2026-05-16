/**
 * app/api/verify-identity/route.ts
 *
 * POST /api/verify-identity
 * ──────────────────────────
 * Stateless, read-only verification of the Nostr-side binding proof.
 *
 * Unlike /api/bind-identity (which requires BOTH signatures and is used
 * during onboarding/re-linking), this endpoint only needs the Nostr event.
 * It is designed for fast profile loading:
 *
 *   "Before showing the Tip button on Alice's profile, verify her binding."
 *
 * Flow:
 *   1. Client fetches Alice's Kind 30078 event from Nostr relays.
 *   2. Client sends { npub, evmAddress, nostrEvent } to this endpoint.
 *   3. Server verifies Schnorr signature + claim field consistency.
 *   4. On success, client enables SocialFi features for Alice.
 *
 * The EVM consent signature is intentionally excluded – verifying the
 * on-chain ERC-1271 proof on every profile view would be unnecessarily
 * expensive. Trust is established once at bind time; queried quickly here.
 *
 * ─── Request  ────────────────────────────────────────────────────────────────
 * Body (JSON): VerifyIdentityPayload
 * {
 *   npub:        string
 *   evmAddress:  string
 *   nostrEvent:  NostrBindingEvent
 * }
 *
 * ─── Response ────────────────────────────────────────────────────────────────
 * 200 VerifySuccessResponse  { valid: true,  npub, evmAddress }
 * 400 VerifyErrorResponse    { valid: false, reason: string   }
 * 500 VerifyErrorResponse    { valid: false, reason: "internal_error" }
 */

import { NextRequest, NextResponse } from "next/server";
import type {
  VerifyIdentityPayload,
  VerifyResponse,
} from "@/lib/binding/schema";
import {
  checkNostrEventStructure,
  parseBindingClaim,
} from "@/lib/binding/validator";
import { verifyNostrEvent } from "@/lib/nostr/verification";
import { safeNormalizeAddress } from "@/lib/evm/verification";

export async function POST(
  request: NextRequest,
): Promise<NextResponse<VerifyResponse>> {
  // ── 1. Parse request body ─────────────────────────────────────────────────
  let payload: VerifyIdentityPayload;

  try {
    payload = (await request.json()) as VerifyIdentityPayload;
  } catch {
    return NextResponse.json(
      { valid: false, reason: "invalid_payload" } as VerifyResponse,
      { status: 400 },
    );
  }

  const { npub, evmAddress, nostrEvent } = payload;

  // ── 2. Presence guard ─────────────────────────────────────────────────────
  if (!npub || !evmAddress || !nostrEvent) {
    return NextResponse.json(
      { valid: false, reason: "invalid_payload" } as VerifyResponse,
      { status: 400 },
    );
  }

  try {
    // ── 3. Nostr event structure ───────────────────────────────────────────
    const structureResult = checkNostrEventStructure(nostrEvent);
    if (!structureResult.ok) {
      return NextResponse.json(
        { valid: false, reason: structureResult.reason } as VerifyResponse,
        { status: 400 },
      );
    }

    // ── 4. Pubkey match ────────────────────────────────────────────────────
    if (nostrEvent.pubkey !== npub) {
      return NextResponse.json(
        { valid: false, reason: "nostr_pubkey_mismatch" } as VerifyResponse,
        { status: 400 },
      );
    }

    // ── 5. Schnorr signature ──────────────────────────────────────────────
    const sigValid = await verifyNostrEvent(nostrEvent);
    if (!sigValid) {
      return NextResponse.json(
        { valid: false, reason: "invalid_nostr_signature" } as VerifyResponse,
        { status: 400 },
      );
    }

    // ── 6. Claim parsing ──────────────────────────────────────────────────
    const parseResult = parseBindingClaim(nostrEvent.content);
    if ("error" in parseResult) {
      return NextResponse.json(
        { valid: false, reason: parseResult.error } as VerifyResponse,
        { status: 400 },
      );
    }

    // ── 7. EVM address consistency ────────────────────────────────────────
    const normalizedExpected = safeNormalizeAddress(evmAddress);
    const normalizedClaim = safeNormalizeAddress(parseResult.claim.evmAddress);

    if (!normalizedExpected || !normalizedClaim) {
      return NextResponse.json(
        { valid: false, reason: "evm_address_invalid" } as VerifyResponse,
        { status: 400 },
      );
    }

    if (normalizedClaim !== normalizedExpected) {
      return NextResponse.json(
        { valid: false, reason: "evm_address_mismatch" } as VerifyResponse,
        { status: 400 },
      );
    }

    // ── 8. Success ────────────────────────────────────────────────────────
    return NextResponse.json(
      {
        valid: true,
        npub,
        evmAddress: normalizedExpected,
      } as VerifyResponse,
      { status: 200 },
    );
  } catch (err) {
    console.error("[verify-identity] Unexpected error:", err);
    return NextResponse.json(
      { valid: false, reason: "internal_error" } as VerifyResponse,
      { status: 500 },
    );
  }
}