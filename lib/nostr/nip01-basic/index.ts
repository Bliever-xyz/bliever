/**
 * lib/nostr/nip01-basic/index.ts
 *
 * Public API re-export for the NIP-01 module.
 *
 * Consumers can import anything from this folder through a single path:
 *   import { buildAndSignBindingEvent, fetchNostrEvents } from "@/lib/nostr/nip01-basic"
 *
 * Or through the root nostr barrel:
 *   import { buildAndSignBindingEvent, fetchNostrEvents } from "@/lib/nostr"
 */

// Keypair generation, NIP-19 encoding, and binary helpers
export {
  generateNostrKeypair,
  npubFromNsec,
  toHexNpub,
  toDisplayNpub,
  toBase64,
  fromBase64,
  toBase64Url,
  fromBase64Url,
} from "./keys";

// Kind 30078 binding event builder + finalizer
export { buildAndSignBindingEvent } from "./event";
export type { BuildBindingEventParams } from "./event";

// NIP-01 publish (Relay) + subscribe/read (SimplePool)
export {
  publishEventToRelays,
  fetchNostrEvents,
} from "./relay";
export type {
  PublishResult,
  RelayPublishOutcome,
  FetchEventsParams,
} from "./relay";

// Schnorr signature verifier (server-safe, nostr-tools/pure)
export { verifyNostrEvent } from "./verification";