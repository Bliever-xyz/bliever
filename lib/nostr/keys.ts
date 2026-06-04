/**
 * lib/nostr/keys.ts
 *
 * Nostr keypair generation and binary-encoding utilities.
 *
 * Cryptographic primitives are provided by nostr-tools, which uses
 * `crypto.getRandomValues` for all entropy. The `nsec` (Uint8Array[32]) is
 * the raw secp256k1 private key. It is treated as the most sensitive piece
 * of data in the system and must flow directly to the crypto/nsec-storage
 * module without being logged, serialised, or placed in non-ephemeral state.
 *
 * Encoding helpers (base64 / base64url) are colocated here because they
 * are needed by the storage module for serialising IV and ciphertext, and
 * keeping them in one place avoids a third utility file.
 */

import { generateSecretKey, getPublicKey } from "nostr-tools";
import * as nip19 from "nostr-tools/nip19";
import type { NostrKeypair, NostrPubkeyHex } from "../binding/schema";

// ─── Keypair generation ───────────────────────────────────────────────────────

/**
 * Generates a fresh secp256k1 Nostr keypair using platform entropy.
 *
 * Entropy source: `crypto.getRandomValues` (Web Crypto / Node 19+).
 *
 * The returned `nsec` is a 32-byte Uint8Array. Callers MUST encrypt it and
 * hand it to `persistNsec` before the call stack returns. Do not store raw
 * bytes in component state, localStorage, or logs.
 *
 * @returns `NostrKeypair` with raw `nsec` and 64-char hex `npub`.
 */
export function generateNostrKeypair(): NostrKeypair {
  const nsec = generateSecretKey(); // Uint8Array[32], secp256k1 private key
  const npub = getPublicKey(nsec);  // 64-char lowercase hex public key
  return { nsec, npub };
}

/**
 * Derives the hex-encoded public key from a raw secret key.
 * Useful after recovering the nsec from storage, when the npub must be
 * recomputed for signing a new event.
 *
 * Returns a branded `NostrPubkeyHex` so downstream callers are type-checked
 * against accidental use of bech32-encoded strings. `getPublicKey` always
 * returns exactly 64 lowercase hex characters, so the cast is safe.
 *
 * @param nsec - Raw 32-byte Nostr secret key.
 * @returns    Branded 64-char lowercase hex public key.
 * @throws     If `nsec` is not exactly 32 bytes — catches truncated or
 *             corrupted key material before it reaches the cryptographic layer.
 */
export function npubFromNsec(nsec: Uint8Array): NostrPubkeyHex {
  if (nsec.length !== 32) {
    throw new Error(
      `nsec must be exactly 32 bytes; received ${nsec.length}. ` +
      `The key material may be truncated or corrupted.`,
    );
  }
  return getPublicKey(nsec) as NostrPubkeyHex;
}

// ─── NIP-19 bech32 encoding/decoding ─────────────────────────────────────────

/**
 * Converts a Nostr public key to a branded `NostrPubkeyHex`.
 *
 * Accepts two input forms so callers don't need to pre-check the format:
 *   • 64-char lowercase hex string — validated and branded directly.
 *   • `npub1…` bech32 string — decoded via NIP-19, checksum validated by
 *     `nostr-tools/nip19`, then branded.
 *
 * This is the correct entry point when accepting user-supplied npub values
 * (e.g. from a paste or URL param). Once the value passes through here it
 * is safe to pass anywhere a `NostrPubkeyHex` is required.
 *
 * @param input - Either a 64-char hex pubkey or an `npub1…` bech32 string.
 * @returns     Branded `NostrPubkeyHex`.
 * @throws      If the input is neither valid hex nor a valid `npub1…` string.
 */
export function toHexNpub(input: string): NostrPubkeyHex {
  // Case 1: already raw hex — validate format and brand it.
  // Must be exactly 64 lowercase hex chars to match NPUB_HEX_REGEX.
  if (/^[0-9a-f]{64}$/.test(input)) {
    return input as NostrPubkeyHex;
  }

  // Case 2: bech32 npub1… — decode with built-in checksum validation.
  try {
    const decoded = nip19.decode(input);
    if (decoded.type !== "npub") {
      throw new Error(
        `Expected npub, got "${decoded.type}". ` +
        `Pass a 64-char hex pubkey or an npub1… bech32 string.`,
      );
    }
    return decoded.data as NostrPubkeyHex;
  } catch (err) {
    throw new Error(
      `[keys] toHexNpub: invalid input "${input.slice(0, 20)}…". ` +
      `Expected 64-char lowercase hex or npub1… bech32. ` +
      `Cause: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

/**
 * Encodes a branded hex public key to its human-readable `npub1…` bech32
 * representation for display in the UI.
 *
 * `npubEncode` and `toHexNpub` are exact inverses:
 *   `toHexNpub(toDisplayNpub(hex)) === hex`
 *
 * @param hexNpub - Branded 64-char hex public key.
 * @returns       `npub1…` bech32 string suitable for display or sharing.
 */
export function toDisplayNpub(hexNpub: NostrPubkeyHex): string {
  return nip19.npubEncode(hexNpub);
}

// ─── Binary encoding utilities ────────────────────────────────────────────────
// Used by nsec-storage.ts for IV / ciphertext serialisation into IndexedDB.

/**
 * Encodes a Uint8Array to a standard base64 string.
 * Used for storing ciphertext and IV values in IndexedDB JSON records.
 */
export function toBase64(bytes: Uint8Array): string {
  // btoa works on binary strings; chunk approach handles large buffers.
  let binary = "";
  const chunk = 8192;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/**
 * Decodes a standard base64 string to a Uint8Array.
 */
export function fromBase64(str: string): Uint8Array {
  const binary = atob(str);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * Encodes a Uint8Array to a URL-safe base64url string (no padding).
 * Used for serialising WebAuthn credentialId values (per WebAuthn spec).
 */
export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Decodes a base64url string (with or without padding) to a Uint8Array.
 */
export function fromBase64Url(str: string): Uint8Array {
  const base64 = str.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(
    base64.length + ((4 - (base64.length % 4)) % 4),
    "=",
  );
  return fromBase64(padded);
}