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

/** Base chain ID resolved at runtime. Defaults to Base Sepolia (84532). */
export const BASE_CHAIN_ID =
  process.env.NEXT_PUBLIC_BASE_CHAIN_ID ?? "84532";

// ─── Nostr types ─────────────────────────────────────────────────────────────

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
  /** Must include `d`, `binding`, and `evm` tags (see validator). */
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
  /** Must equal ONBOARDING_VERSION. */
  version: string;
  /** Must equal APP_ID. */
  appId: string;
}

// ─── Utility types ────────────────────────────────────────────────────────────

/** 0x-prefixed hex string (EVM signature, address, etc.). */
export type HexString = `0x${string}`;

// ─── Inbound API payload types ────────────────────────────────────────────────

/**
 * Body expected by POST /api/bind-identity and POST /api/onboarding.
 *
 * The client must supply both cryptographic proofs:
 *   1. nostrEvent  – Kind 30078 signed by the Nostr private key.
 *   2. evmSignature – EIP-191 personal_sign signed by the CDP Smart Account.
 */
export interface BindIdentityPayload {
  /** Hex Nostr public key (no `npub` bech32 – raw hex). */
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
  // Server
  | "internal_error";