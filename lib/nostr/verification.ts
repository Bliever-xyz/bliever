/**
 * lib/nostr/verification.ts
 *
 * Nostr cryptographic verification utilities.
 *
 * Uses `nostr-tools/pure` – a sub-path export that contains no browser or
 * DOM dependencies, making it safe to import in any Node.js/Edge runtime.
 *
 * `verifyEvent` validates:
 *   - The SHA-256 event id matches the serialised event fields.
 *   - The Schnorr signature over the id is valid for the pubkey.
 */

import { verifyEvent } from "nostr-tools/pure";
import type { NostrBindingEvent } from "../binding/schema";

/**
 * Verifies the cryptographic integrity of a Nostr binding event.
 *
 * Returns `true` if and only if:
 *   1. The event `id` is the correct SHA-256 of the canonical serialisation.
 *   2. The Schnorr `sig` over the `id` is valid for the given `pubkey`.
 *
 * Any malformed input (wrong types, missing fields) returns `false` rather
 * than throwing, so callers can treat the result as a plain boolean guard.
 *
 * @param event - The full Nostr event including `id`, `pubkey`, and `sig`.
 */
export async function verifyNostrEvent(
  event: NostrBindingEvent,
): Promise<boolean> {
  try {
    // nostr-tools `verifyEvent` is synchronous; async wrapper provides a
    // consistent interface in case we migrate to a WASM-based implementation.
    return verifyEvent(event as Parameters<typeof verifyEvent>[0]);
  } catch {
    // Treat any exception (malformed event, wrong field types) as invalid.
    return false;
  }
}