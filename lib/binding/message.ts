/**
 * lib/binding/message.ts
 *
 * Deterministic builder for the EVM consent message that the CDP Smart Account
 * signs during the dual-signature binding handshake.
 *
 *  IMMUTABILITY CONTRACT
 * ─────────────────────────
 * The exact byte sequence produced by `buildEVMConsentMessage` MUST be
 * identical between this server module and the client-side call to
 * `signMessage` in the CDP hooks.
 *
 * Any change to the template (whitespace, newlines, field order) is a
 * BREAKING CHANGE: all in-flight signatures will become unverifiable.
 *
 * If the format must evolve, bump ONBOARDING_VERSION in schema.ts and
 * handle the old version in the validator.
 */

import { APP_ID, BASE_CHAIN_ID, ONBOARDING_VERSION } from "./schema";

/**
 * Builds the human-readable EVM consent message.
 *
 * The message is deliberately verbose so users can read and understand
 * exactly what they are signing in any wallet or passkey prompt.
 *
 * @param npub       Hex Nostr public key of the social identity.
 * @param bindingId  UUID v4 that uniquely identifies this binding attempt.
 * @param timestamp  Unix seconds at which the binding was initiated.
 * @returns          Plain-text string to be signed via EIP-191 personal_sign.
 */
export function buildEVMConsentMessage(
  npub: string,
  bindingId: string,
  timestamp: number,
): string {
  // Array-join gives precise control over every newline.
  // Do NOT use template literals with indentation here.
  return [
    `${APP_ID} Identity Binding v${ONBOARDING_VERSION}`,
    ``,
    `Nostr pubkey: ${npub}`,
    `Binding ID:   ${bindingId}`,
    `Timestamp:    ${timestamp}`,
    `Chain ID:     ${BASE_CHAIN_ID}`,
    ``,
    `By signing, I confirm this Smart Account consents to be linked`,
    `with the above Nostr identity.`,
  ].join("\n");
}