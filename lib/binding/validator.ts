/**
 * lib/binding/validator.ts
 *
 * Core validation logic for the dual-signature identity binding.
 *
 * Design principles
 * ─────────────────
 * • Pure where possible – synchronous helpers have no side effects.
 * • Fail-fast ordering  – cheapest checks (timestamp, structure) run first
 *   so expensive network calls (ERC-1271 on-chain verification) only happen
 *   when all local checks pass.
 * • Single responsibility – each function validates exactly one invariant
 *   and returns a typed discriminated union result.
 */

import {
  NOSTR_BINDING_KIND,
  NOSTR_BINDING_D_TAG,
  BINDING_TIMESTAMP_WINDOW_SEC,
  type BindIdentityPayload,
  type BindingErrorReason,
  type NostrBindingClaim,
  type NostrBindingEvent,
} from "./schema";
import { buildEVMConsentMessage } from "./message";
import { verifyNostrEvent } from "../nostr/verification";
import { verifyEVMSignature, safeNormalizeAddress } from "../evm/verification";

// ─── Result types ─────────────────────────────────────────────────────────────

export interface ValidationOk {
  valid: true;
  /** EIP-55 checksummed EVM address extracted & normalised from the claim. */
  normalizedEvmAddress: string;
  /** Parsed and validated claim from the Nostr event content. */
  claim: NostrBindingClaim;
}

export interface ValidationFail {
  valid: false;
  reason: BindingErrorReason;
}

export type ValidationResult = ValidationOk | ValidationFail;

type StructureOk = { ok: true };
type StructureFail = { ok: false; reason: BindingErrorReason };
type StructureResult = StructureOk | StructureFail;

type ParseOk = { claim: NostrBindingClaim };
type ParseFail = { error: BindingErrorReason };
type ParseResult = ParseOk | ParseFail;

// ─── Individual validators (pure / synchronous) ───────────────────────────────

/**
 * Returns `true` when the timestamp is within the allowed freshness window.
 * Prevents replay attacks using stale binding proofs.
 */
export function checkTimestamp(timestamp: number): boolean {
  const now = Math.floor(Date.now() / 1000);
  return Math.abs(now - timestamp) <= BINDING_TIMESTAMP_WINDOW_SEC;
}

/**
 * Validates the structural invariants of a Nostr Kind 30078 binding event.
 *
 * Required tags:
 *   d       → "identity-binding"  (namespaces the event within Kind 30078)
 *   binding → the UUID v4         (links event to the EVM consent signature)
 *   evm     → the EVM address     (queryable index tag for relay lookup)
 */
export function checkNostrEventStructure(
  event: NostrBindingEvent,
): StructureResult {
  if (event.kind !== NOSTR_BINDING_KIND) {
    return { ok: false, reason: "wrong_event_kind" };
  }

  const dTag = event.tags.find((t) => t[0] === "d")?.[1];
  if (dTag !== NOSTR_BINDING_D_TAG) {
    return { ok: false, reason: "wrong_d_tag" };
  }

  if (!event.tags.some((t) => t[0] === "binding")) {
    return { ok: false, reason: "missing_binding_tag" };
  }

  if (!event.tags.some((t) => t[0] === "evm")) {
    return { ok: false, reason: "missing_evm_tag" };
  }

  return { ok: true };
}

/**
 * Parses and minimally validates the JSON claim embedded in the event content.
 * Does NOT perform cryptographic checks – that is the caller's responsibility.
 */
export function parseBindingClaim(content: string): ParseResult {
  try {
    const raw = JSON.parse(content) as Partial<NostrBindingClaim>;

    if (
      typeof raw.evmAddress !== "string" ||
      typeof raw.timestamp !== "number" ||
      typeof raw.bindingId !== "string" ||
      typeof raw.version !== "string" ||
      typeof raw.appId !== "string"
    ) {
      return { error: "invalid_claim_fields" };
    }

    return { claim: raw as NostrBindingClaim };
  } catch {
    return { error: "invalid_content_json" };
  }
}

// ─── Main validator (async – calls external services) ────────────────────────

/**
 * Full dual-signature binding validation.
 *
 * Execution order (fail-fast, cheapest-first):
 *   1. Timestamp freshness          (local, O(1))
 *   2. Nostr event structure        (local, O(tags))
 *   3. Nostr pubkey match           (local, O(1))
 *   4. Nostr Schnorr signature      (local CPU, secp256k1)
 *   5. Claim JSON parsing           (local, O(content))
 *   6. EVM address normalisation    (local, O(1))
 *   7. EVM address match in claim   (local, O(1))
 *   8. BindingId cross-field match  (local, O(1))
 *   9. EVM ERC-1271 signature       (network call to Base RPC)
 *
 * The ERC-1271 call at step 9 is the only network-dependent step and is
 * intentionally last to minimise unnecessary RPC usage.
 */
export async function validateBindingPayload(
  payload: BindIdentityPayload,
): Promise<ValidationResult> {
  const {
    npub,
    evmAddress,
    nostrEvent,
    evmSignature,
    bindingId,
    timestamp,
  } = payload;

  // ── Timestamp redundancy note ─────────────────────────────────────────────
  // `timestamp` appears in three places: the top-level payload, the Nostr
  // event's `created_at`, and inside `NostrBindingClaim.timestamp` (content).
  // This redundancy is intentional: each layer is signed independently, so
  // an attacker cannot alter the timestamp in one place without invalidating
  // a cryptographic proof in another. Do not collapse these fields.

  // 1. Timestamp
  if (!checkTimestamp(timestamp)) {
    return { valid: false, reason: "timestamp_expired" };
  }

  // 2. Nostr event structure
  const structureResult = checkNostrEventStructure(nostrEvent);
  if (!structureResult.ok) {
    return { valid: false, reason: structureResult.reason };
  }

  // 3. Nostr pubkey must match the supplied npub
  if (nostrEvent.pubkey !== npub) {
    return { valid: false, reason: "nostr_pubkey_mismatch" };
  }

  // 4. Nostr Schnorr signature verification (CPU-only, no network)
  const nostrSigValid = await verifyNostrEvent(nostrEvent);
  if (!nostrSigValid) {
    return { valid: false, reason: "invalid_nostr_signature" };
  }

  // 5. Parse embedded claim
  const parseResult = parseBindingClaim(nostrEvent.content);
  if ("error" in parseResult) {
    return { valid: false, reason: parseResult.error };
  }
  const { claim } = parseResult;

  // 6. Normalise addresses (validates format as a side-effect)
  const normalizedExpected = safeNormalizeAddress(evmAddress);
  const normalizedClaim = safeNormalizeAddress(claim.evmAddress);

  if (!normalizedExpected || !normalizedClaim) {
    return { valid: false, reason: "evm_address_invalid" };
  }

  // 7. EVM address consistency
  if (normalizedClaim !== normalizedExpected) {
    return { valid: false, reason: "evm_address_mismatch" };
  }

  // 8. BindingId cross-field consistency
  if (claim.bindingId !== bindingId) {
    return { valid: false, reason: "binding_id_mismatch" };
  }

  // 9. EVM consent signature – ERC-1271 on-chain call for Smart Accounts
  const consentMessage = buildEVMConsentMessage(npub, bindingId, timestamp);
  const evmSigValid = await verifyEVMSignature(
    consentMessage,
    evmSignature,
    normalizedExpected,
  );
  if (!evmSigValid) {
    return { valid: false, reason: "invalid_evm_signature" };
  }

  return { valid: true, normalizedEvmAddress: normalizedExpected, claim };
}
