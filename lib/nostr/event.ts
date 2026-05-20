/**
 * lib/nostr/event.ts
 *
 * Builds and cryptographically finalises the Kind 30078 Nostr binding event.
 *
 * The output of this module must satisfy all nine steps of the server's
 * structural validator (checkNostrEventStructure + verifyNostrEvent):
 *
 *   ✓ kind === 30078
 *   ✓ tags contain ["d", "identity-binding"]
 *   ✓ tags contain ["binding", <bindingId>]
 *   ✓ tags contain ["evm", <evmAddress>]
 *   ✓ content is JSON-stringified NostrBindingClaim (key order must be stable)
 *   ✓ id  = SHA-256( [0, pubkey, created_at, kind, tags, content] )
 *   ✓ sig = Schnorr(id, nsec)   (BIP-340 / secp256k1)
 *
 * All cryptographic work is delegated to nostr-tools `finalizeEvent`, which
 * handles serialisation, hashing, and signing atomically.
 */

import { finalizeEvent, type EventTemplate } from "nostr-tools";
import {
  NOSTR_BINDING_KIND,
  NOSTR_BINDING_D_TAG,
  ONBOARDING_VERSION,
  APP_ID,
  type NostrBindingEvent,
  type NostrBindingClaim,
} from "../binding/schema";

// ─── Parameters ───────────────────────────────────────────────────────────────

export interface BuildBindingEventParams {
  /** 64-char hex Nostr public key. Used only to document intent; finalizeEvent
   *  derives pubkey from nsec automatically. Provided for caller clarity. */
  npub: string;
  /** EIP-55 checksummed CDP Smart Account address. */
  evmAddress: string;
  /** UUID v4 tying this event to the EVM consent signature. */
  bindingId: string;
  /** Unix seconds — must equal the timestamp in the EVM consent message. */
  timestamp: number;
  /** Raw 32-byte Nostr secret key. finalizeEvent uses this to produce id + sig. */
  nsec: Uint8Array;
}

// ─── Builder ──────────────────────────────────────────────────────────────────

/**
 * Builds a Kind 30078 binding event template, JSON-stringifies its content,
 * and calls `finalizeEvent` to produce the id (SHA-256) and sig (Schnorr).
 *
 * Key ordering in the claim JSON is determined by the object literal order
 * below. Do not reorder the fields — the server does not rely on key order for
 * JSON parsing, but any future canonical-form requirement would be fragile if
 * key order were inconsistent.
 *
 * `finalizeEvent` MUTATES the template internally to attach `pubkey`, computes
 * the event id, then produces the Schnorr signature. The returned object is a
 * fully-formed, server-ready NostrBindingEvent.
 *
 * @param params - All fields needed to construct the binding event.
 * @returns       Finalised event with `id`, `pubkey`, `sig` populated.
 */
export function buildAndSignBindingEvent(
  params: BuildBindingEventParams,
): NostrBindingEvent {
  const { evmAddress, bindingId, timestamp, nsec } = params;

  // ── Construct the embedded claim ──────────────────────────────────────────
  // The claim is the semantic payload. Every field is cross-validated by the
  // server's `parseBindingClaim` and `validateBindingPayload` steps.
  const claim: NostrBindingClaim = {
    evmAddress,
    timestamp,
    bindingId,
    version: ONBOARDING_VERSION,
    appId: APP_ID,
  };

  // The content MUST be stringified BEFORE finalizeEvent is called.
  // finalizeEvent includes the raw content string in the canonical serialisation
  // it hashes. Stringifying afterwards would produce a different hash.
  const content = JSON.stringify(claim);

  // ── Build the event template ──────────────────────────────────────────────
  const template: EventTemplate = {
    kind: NOSTR_BINDING_KIND,
    created_at: timestamp,   // server checks created_at is within 5-min window
    tags: [
      // d-tag: namespaces this event as an identity binding within Kind 30078
      ["d", NOSTR_BINDING_D_TAG],
      // binding-tag: relay-queryable index linking event ↔ EVM consent sig
      ["binding", bindingId],
      // evm-tag: relay-queryable index for EVM address lookup
      ["evm", evmAddress],
    ],
    content,
  };

  // ── Finalise: computes id and sig atomically ───────────────────────────────
  // finalizeEvent(template, secretKey):
  //   1. Sets template.pubkey = getPublicKey(secretKey)
  //   2. Serialises: JSON.stringify([0, pubkey, created_at, kind, tags, content])
  //   3. id  = SHA-256(serialised bytes)
  //   4. sig = schnorrSign(id, secretKey)
  const signed = finalizeEvent(template, nsec);

  // Cast through unknown: finalizeEvent returns nostr-tools' internal
  // VerifiedEvent type, which is structurally identical to NostrBindingEvent.
  return signed as unknown as NostrBindingEvent;
}