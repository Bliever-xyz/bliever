/**
 * lib/api/client.ts
 *
 * Typed, thin HTTP wrappers for the three onboarding backend endpoints.
 *
 * Design principles:
 *   • Zero business logic — each function is a pure async fetch wrapper.
 *   • Typed error surface — non-2xx responses throw `OnboardingApiError`
 *     with the machine-readable `reason` string from the server payload.
 *     Callers switch on `reason` for retry / user-facing message logic.
 *   • No retry logic — the orchestrator (`flow.ts`) decides retry strategy.
 *   • Rate-limit awareness — `OnboardingApiError` exposes `status` (HTTP code)
 *     so callers can distinguish 429 (back off) from 400 (fix the payload).
 *   • Request timeout — every fetch is guarded by `AbortSignal.timeout` so
 *     a hung server response cannot block the flow indefinitely.
 *
 * Base URL:
 *   Resolved from `NEXT_PUBLIC_API_BASE_URL` (Next.js public env var).
 *   Defaults to `""` (same-origin relative URL), which is correct for the
 *   standard Next.js deployment where client and API share the same origin.
 *   Override in environments where the API lives on a different origin.
 */

import type {
  NostrBindingEvent,
  HexString,
  BindingErrorReason,
} from "../binding/schema";

// ─── Request / response shapes (mirrors server lib/binding/schema.ts) ─────────

/** Body sent to POST /api/onboarding and POST /api/bind-identity. */
export interface BindingPayload {
  npub: string;
  evmAddress: string;
  nostrEvent: NostrBindingEvent;
  evmSignature: HexString;
  bindingId: string;
  timestamp: number;
}

export interface OnboardingSuccessResponse {
  success: true;
  onboardingComplete: true;
  bindingId: string;
  npub: string;
  evmAddress: string;
  verifiedAt: number;
}

export interface BindingSuccessResponse {
  success: true;
  bindingId: string;
  npub: string;
  evmAddress: string;
  verifiedAt: number;
}

export interface ErrorResponse {
  success: false;
  reason: BindingErrorReason;
}

/** Body sent to POST /api/verify-identity. */
export interface VerifyPayload {
  npub: string;
  evmAddress: string;
  nostrEvent: NostrBindingEvent;
}

export interface VerifySuccessResponse {
  valid: true;
  npub: string;
  evmAddress: string;
}

export interface VerifyErrorResponse {
  valid: false;
  reason: string;
}

// ─── Error class ──────────────────────────────────────────────────────────────

/**
 * Thrown when a backend endpoint returns a non-2xx response.
 *
 * `reason`  – machine-readable code from the server response body.
 * `status`  – HTTP status code (400 = bad payload, 429 = rate limited, 500 = server).
 *
 * Usage:
 *   ```ts
 *   try {
 *     await submitOnboarding(payload);
 *   } catch (err) {
 *     if (err instanceof OnboardingApiError) {
 *       if (err.status === 429) { // back off }
 *       if (err.reason === "timestamp_expired") { // regenerate payload }
 *     }
 *   }
 *   ```
 */
export class OnboardingApiError extends Error {
  constructor(
    message: string,
    public readonly reason: BindingErrorReason | "unknown_error",
    public readonly status: number,
  ) {
    super(message);
    this.name = "OnboardingApiError";
  }
}

// ─── Internal: generic POST helper ───────────────────────────────────────────

const BASE_URL: string =
  process.env.NEXT_PUBLIC_API_BASE_URL ?? "";

/**
 * Per-request timeout in milliseconds.
 * A hung server response (e.g. RPC provider hangs during ERC-1271 verification)
 * would otherwise block the flow indefinitely. 15 seconds covers the ERC-1271
 * RPC call under typical network conditions while providing a clear failure
 * signal rather than an infinite wait.
 */
const REQUEST_TIMEOUT_MS = 15_000;

async function postJson<TBody, TSuccess>(
  path: string,
  body: TBody,
): Promise<TSuccess> {
  let response: Response;
  try {
    response = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (networkErr) {
    // fetch() throws on network failure (offline, DNS failure) and on
    // AbortError when REQUEST_TIMEOUT_MS is exceeded.
    throw new OnboardingApiError(
      `Network error calling ${path}: ${networkErr instanceof Error ? networkErr.message : String(networkErr)}`,
      "internal_error",
      0, // no HTTP status available
    );
  }

  const data = await response.json() as Record<string, unknown>;

  if (!response.ok) {
    const reason = (data["reason"] as BindingErrorReason | undefined) ?? "unknown_error";
    throw new OnboardingApiError(
      `POST ${path} failed with HTTP ${response.status}: ${reason}`,
      reason as BindingErrorReason,
      response.status,
    );
  }

  return data as TSuccess;
}

// ─── Public endpoint functions ─────────────────────────────────────────────────

/**
 * Fetches the authoritative unix timestamp from GET /api/time.
 *
 * Used by `flow.ts` to generate binding coordinates after `persistNsec`
 * completes, correcting for mobile clock drift that would otherwise cause
 * immediate `timestamp_expired` failures on devices with inaccurate clocks.
 *
 * @throws if the network request fails or the response is malformed.
 */
export async function fetchServerTime(): Promise<number> {
  let response: Response;
  try {
    response = await fetch(`${BASE_URL}/api/time`, {
      method: "GET",
      signal: AbortSignal.timeout(5_000),
    });
  } catch (networkErr) {
    throw new Error(
      `[api/client] fetchServerTime: network error: ${networkErr instanceof Error ? networkErr.message : String(networkErr)}`,
    );
  }
  if (!response.ok) {
    throw new Error(`[api/client] fetchServerTime: HTTP ${response.status}`);
  }
  const data = await response.json() as { now?: number };
  if (typeof data.now !== "number") {
    throw new Error("[api/client] fetchServerTime: response missing 'now' field.");
  }
  return data.now;
}

/**
 * Submits the completed dual-signature proof to POST /api/onboarding.
 *
 * Used during new-user registration. The server verifies both the Nostr
 * Schnorr signature and the EVM ERC-1271 signature before returning success.
 *
 * @throws `OnboardingApiError` on any non-2xx response or request timeout.
 */
export async function submitOnboarding(
  payload: BindingPayload,
): Promise<OnboardingSuccessResponse> {
  return postJson<BindingPayload, OnboardingSuccessResponse>(
    "/api/onboarding",
    payload,
  );
}

/**
 * Submits the completed dual-signature proof to POST /api/bind-identity.
 *
 * Used for re-link flows (Nostr key rotation, Smart Account migration).
 * Semantically identical to submitOnboarding but hits the re-link endpoint.
 *
 * @throws `OnboardingApiError` on any non-2xx response or request timeout.
 */
export async function submitBindIdentity(
  payload: BindingPayload,
): Promise<BindingSuccessResponse> {
  return postJson<BindingPayload, BindingSuccessResponse>(
    "/api/bind-identity",
    payload,
  );
}

/**
 * Checks the Nostr-side binding proof via POST /api/verify-identity.
 *
 * Read-only and fast: no ERC-1271 RPC call on the server side.
 * Used before enabling SocialFi features on a user's profile.
 *
 * @throws `OnboardingApiError` on any non-2xx response or request timeout.
 */
export async function verifyIdentity(
  payload: VerifyPayload,
): Promise<VerifySuccessResponse> {
  return postJson<VerifyPayload, VerifySuccessResponse>(
    "/api/verify-identity",
    payload,
  );
}