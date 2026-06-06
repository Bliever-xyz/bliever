/**
 * lib/binding/schema.ts
 *
 * Single source of truth for every constant, type, and response shape used
 * across the onboarding binding system.
 *
 * ─── Layer model ─────────────────────────────────────────────────────────────
 *   Social  → Nostr keypair (secp256k1)  – generated client-side
 *   Value   → CDP ERC-4337 Smart Account – created by Coinbase Developer Platform
 *   Linking → Kind 30078 event + EIP-191 signature (dual-signature proof)
 */

// ─── Protocol constants ───────────────────────────────────────────────────────

/** Semantic version stamped into every binding claim. Bump = breaking change. */
export const ONBOARDING_VERSION = "1.0" as const;

/** NIP-78 application-specific replaceable event kind used for binding. */
export const NOSTR_BINDING_KIND = 30078 as const;

/** `d` tag value that namespaces this binding within Kind 30078 events. */
export const NOSTR_BINDING_D_TAG = "identity-binding" as const;

/**
 * Freshness window for binding timestamps (seconds).
 * Requests older than this are rejected to prevent replay attacks.
 */
export const BINDING_TIMESTAMP_WINDOW_SEC = 300 as const;

/** Application identifier embedded in every binding claim and consent message. */
export const APP_ID = "bliever-v1" as const;

/**
 * Validates that an npub is a raw 64-character lowercase hex string.
 * Rejects bech32-encoded `npub1…` strings, which look valid to a presence
 * check but fail the pubkey-match step with a misleading `nostr_pubkey_mismatch`
 * error. Catching the format mismatch early produces `invalid_payload` instead.
 */
export const NPUB_HEX_REGEX = /^[0-9a-f]{64}$/;

/**
 * The only two valid Base chain identifiers.
 * Using a union prevents accidental assignment of arbitrary strings
 * (e.g. a mistyped env var) from silently routing to the wrong network.
 */
export type BaseChainId = "8453" | "84532";

/**
 * Base chain ID resolved at runtime. Defaults to Base Sepolia (84532).
 * Runtime validation happens in `lib/evm/client.ts` at module load.
 */
export const BASE_CHAIN_ID =
  (process.env.NEXT_PUBLIC_BASE_CHAIN_ID ?? "84532") as BaseChainId;

// ─── Nostr types ─────────────────────────────────────────────────────────────

/**
 * Typed representation of the three binding-specific tags.
 * Used internally when constructing or inspecting binding events.
 * `NostrBindingEvent.tags` remains `string[][]` for nostr-tools compatibility,
 * but helpers that build or read tags should use this union.
 */
export type BindingTag =
  | ["d", typeof NOSTR_BINDING_D_TAG]
  | ["binding", string]
  | ["evm", string];

/**
 * Minimal Nostr event shape required for binding verification.
 * Matches the structure produced by `finalizeEvent` from nostr-tools.
 */
export interface NostrBindingEvent {
  /** SHA-256 event id (hex). */
  id: string;
  /** Hex-encoded secp256k1 public key of the signer. */
  pubkey: string;
  /** Must equal NOSTR_BINDING_KIND (30078). */
  kind: number;
  /** Unix timestamp (seconds). */
  created_at: number;
  /**
   * Must include `d`, `binding`, and `evm` tags (see validator).
   * `string[][]` is kept for nostr-tools compatibility; use `BindingTag`
   * when constructing or reading these tags.
   */
  tags: string[][];
  /** JSON-stringified NostrBindingClaim. */
  content: string;
  /** Schnorr signature over the serialised event. */
  sig: string;
}

/**
 * Payload embedded in `NostrBindingEvent.content`.
 * Both sides of the binding are embedded here so the claim is
 * self-contained and can be verified without external state.
 */
export interface NostrBindingClaim {
  /** Checksummed EIP-55 EVM address of the CDP Smart Account. */
  evmAddress: string;
  /** Unix timestamp (seconds) – must match the parent payload. */
  timestamp: number;
  /** UUID v4 – ties this claim to the EVM consent signature. */
  bindingId: string;
  /**
   * Must equal ONBOARDING_VERSION.
   * Narrowed to `typeof ONBOARDING_VERSION` so the compiler enforces the
   * contract stated in the comment — a plain `string` would accept any value.
   */
  version: typeof ONBOARDING_VERSION;
  /** Must equal APP_ID. */
  appId: string;
}

// ─── Utility types ────────────────────────────────────────────────────────────

/** 0x-prefixed hex string (EVM signature, address, etc.). */
export type HexString = `0x${string}`;

/**
 * Raw 32-byte hex-encoded Nostr public key (no `npub` bech32 prefix).
 *
 * Branded to prevent accidental passing of bech32-encoded npub strings
 * to functions that expect raw hex — a mix-up that causes silent
 * cryptographic failures rather than a type error.
 *
 * Use `toHexNpub(bech32)` from `lib/nostr/keys.ts` to convert from bech32.
 */
export type NostrPubkeyHex = string & { readonly __brand: unique symbol };

/**
 * EIP-55 checksummed Ethereum address.
 *
 * Branded to prevent raw/lowercase addresses from reaching comparison
 * logic — case differences cause address-mismatch failures that are
 * hard to diagnose. Use `safeNormalizeAddress` from `lib/evm/verification.ts`
 * to produce values of this type.
 */
export type EvmAddressChecksummed = string & { readonly __brand: unique symbol };

// ─── Inbound API payload types ────────────────────────────────────────────────

/**
 * Body expected by POST /api/bind-identity and POST /api/onboarding.
 *
 * The client must supply both cryptographic proofs:
 *   1. nostrEvent  – Kind 30078 signed by the Nostr private key.
 *   2. evmSignature – EIP-191 personal_sign signed by the CDP Smart Account.
 */
export interface BindIdentityPayload {
  /**
   * Raw hex Nostr public key — 64 lowercase hex characters, no `npub` bech32.
   * See `NostrPubkeyHex` for the branded form used in internal helpers.
   */
  npub: string;
  /** EVM address of the CDP ERC-4337 Smart Account. */
  evmAddress: string;
  /** Signed Nostr Kind 30078 binding event. */
  nostrEvent: NostrBindingEvent;
  /** EIP-191 signature from the CDP Smart Account over the consent message. */
  evmSignature: HexString;
  /** UUID v4 that ties both signatures together. Must match event content. */
  bindingId: string;
  /** Unix timestamp (seconds). Must match event content and be within 5 min. */
  timestamp: number;
}

/** POST /api/onboarding shares the same shape as BindIdentityPayload. */
export type OnboardingPayload = BindIdentityPayload;

/**
 * Body expected by POST /api/verify-identity.
 * EVM consent signature is NOT required here – this endpoint only
 * validates the Nostr-side proof for fast client-side profile loading.
 */
export interface VerifyIdentityPayload {
  npub: string;
  evmAddress: string;
  nostrEvent: NostrBindingEvent;
}

// ─── Outbound API response types ─────────────────────────────────────────────

export interface BindingSuccessResponse {
  success: true;
  bindingId: string;
  /** Raw hex Nostr public key, as supplied. */
  npub: string;
  /** EIP-55 checksummed EVM address. */
  evmAddress: string;
  /** Server-side verification timestamp (unix seconds). */
  verifiedAt: number;
}

export interface BindingErrorResponse {
  success: false;
  reason: BindingErrorReason;
}

export type BindingResponse = BindingSuccessResponse | BindingErrorResponse;

export interface OnboardingSuccessResponse extends BindingSuccessResponse {
  onboardingComplete: true;
}

export type OnboardingResponse = OnboardingSuccessResponse | BindingErrorResponse;

export interface VerifySuccessResponse {
  valid: true;
  npub: string;
  /** EIP-55 checksummed EVM address. */
  evmAddress: string;
}

export interface VerifyErrorResponse {
  valid: false;
  reason: string;
}

export type VerifyResponse = VerifySuccessResponse | VerifyErrorResponse;

// ─── Error reason catalogue ───────────────────────────────────────────────────

/**
 * Exhaustive list of machine-readable failure reasons.
 * Indexers and clients should switch on these to decide retry/display logic.
 */
export type BindingErrorReason =
  // Request shape
  | "invalid_payload"
  // Timing
  | "timestamp_expired"
  // Nostr event structure
  | "wrong_event_kind"
  | "wrong_d_tag"
  | "missing_binding_tag"
  | "missing_evm_tag"
  // Nostr identity
  | "nostr_pubkey_mismatch"
  | "invalid_nostr_signature"
  // Claim content
  | "invalid_content_json"
  | "invalid_claim_fields"
  // EVM identity
  | "evm_address_invalid"
  | "evm_address_mismatch"
  | "invalid_evm_signature"
  // Cross-field consistency
  | "binding_id_mismatch"
  | "invalid_binding_id"
  // Rate limiting
  | "rate_limited"
  // Server
  | "internal_error";

// ─── Client-only flow types ───────────────────────────────────────────────────
// These types are used exclusively by the client-side orchestrator (flow.ts)
// and the nsec storage module. They have no server-side counterpart.

/**
 * Raw secp256k1 Nostr keypair generated by `generateNostrKeypair()`.
 * The `nsec` bytes must be encrypted and stored via `persistNsec` immediately.
 * Never place these bytes in component state, logs, or non-ephemeral storage.
 */
export interface NostrKeypair {
  /** Raw 32-byte Nostr secret key. Zeroize with `nsec.fill(0)` after use. */
  nsec: Uint8Array;
  /** 64-char lowercase hex public key derived from `nsec`. */
  npub: string;
}

/**
 * Chooses how the nsec is encrypted at rest in IndexedDB.
 *
 * `"prf"`       — WebAuthn PRF extension. AES key derived from authenticator;
 *                 never stored. Decryption requires biometric / PIN prompt.
 *                 Strongest option; not supported by all browsers (e.g. Firefox).
 * `"webcrypto"` — Random AES-256-GCM CryptoKey generated by Web Crypto.
 *                 Stored as a non-extractable structured clone in IndexedDB.
 *                 Silent recovery; weaker boundary than PRF.
 */
export type NsecStorageStrategy = "prf" | "webcrypto";

/**
 * Opaque reference to the encrypted nsec bundle in IndexedDB.
 * Returned by `persistNsec`; must be passed to `recoverNsec` later.
 * Safe to persist in `localStorage` — it contains no key material.
 */
export interface NsecStorageHandle {
  strategy: NsecStorageStrategy;
  /** PRF strategy only: base64url-encoded WebAuthn credential rawId. */
  credentialId?: string;
}

/**
 * Injected signing capability from the CDP Smart Account SDK.
 *
 * The orchestrator never imports the CDP SDK directly. Instead, the consumer
 * wraps the CDP `signMessage` hook and passes it here. This decouples
 * `flow.ts` from any specific SDK version or framework.
 *
 * @param message - Plain-text string to be signed via EIP-191 personal_sign.
 * @returns        0x-prefixed hex ERC-1271 signature.
 */
export type SignMessageFn = (message: string) => Promise<HexString>;

/**
 * Parameters accepted by `runOnboarding()`.
 */
export interface OnboardingParams {
  /** EIP-55 checksummed CDP Smart Account address. */
  evmAddress: string;
  /** Injected CDP signing capability — see `SignMessageFn`. */
  signMessage: SignMessageFn;
  /** WebSocket relay URLs the Kind 30078 event should be published to. */
  relayUrls?: string[];
  /**
   * nsec encryption strategy. Prefer `"prf"`; fall back to `"webcrypto"` if
   * the authenticator does not support the PRF extension.
   * @default "webcrypto"
   */
  storageStrategy?: NsecStorageStrategy;
  /**
   * PRF strategy only: WebAuthn relying-party ID (usually `window.location.hostname`).
   * Required when `storageStrategy === "prf"`.
   */
  prfRpId?: string;
}

/**
 * Returned by `runOnboarding()` on success.
 */
export interface OnboardingResult {
  /** 64-char hex Nostr public key — the user's permanent social identity. */
  npub: string;
  /** EIP-55 checksummed Smart Account address, as confirmed by the server. */
  evmAddress: string;
  /** UUID v4 — for logging and debugging only. */
  bindingId: string;
  /** Unix seconds — server-side verification time. */
  verifiedAt: number;
  /** Signed Kind 30078 event — can be re-published to relays at any time. */
  nostrEvent: NostrBindingEvent;
  /** Opaque IDB reference — persist this in `localStorage` for session recovery. */
  storageHandle: NsecStorageHandle;
}

/**
 * Parameters accepted by `runBindIdentity()`.
 */
export interface BindIdentityParams {
  /** 64-char hex Nostr public key. Must correspond to `nsec`. */
  npub: string;
  /**
   * Raw 32-byte Nostr secret key recovered via `recoverNsec()`.
   * Will be zeroized (`nsec.fill(0)`) inside `runBindIdentity` after signing.
   */
  nsec: Uint8Array;
  /** New or existing EIP-55 checksummed Smart Account address to bind. */
  evmAddress: string;
  /** Injected CDP signing capability — see `SignMessageFn`. */
  signMessage: SignMessageFn;
  /** WebSocket relay URLs the replacement Kind 30078 event should be sent to. */
  relayUrls?: string[];
}

/**
 * Returned by `runBindIdentity()` on success.
 */
export interface BindIdentityResult {
  /** 64-char hex Nostr public key. */
  npub: string;
  /** EIP-55 checksummed Smart Account address, as confirmed by the server. */
  evmAddress: string;
  /** UUID v4 — for logging and debugging only. */
  bindingId: string;
  /** Unix seconds — server-side verification time. */
  verifiedAt: number;
  /** Signed Kind 30078 event — can be re-published to relays at any time. */
  nostrEvent: NostrBindingEvent;
}