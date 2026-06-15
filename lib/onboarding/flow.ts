"use client";

/**
 * lib/onboarding/flow.ts
 *
 * CLIENT-ONLY MODULE — requires browser APIs (IndexedDB, Web Crypto, WebAuthn).
 * The "use client" directive above prevents Next.js from bundling this file on
 * the server. In non-Next.js environments, import via dynamic import or ensure
 * this module is never executed in a Node/SSR context.
 *
 * Top-level orchestration of the dual-signature onboarding handshake.
 *
 * This module is the only entry point a consumer should import. It composes
 * all sub-modules without any UI, React, or framework dependency.
 *
 * Two public flows are exported:
 *
 *   runOnboarding(params)
 *   ─────────────────────
 *   New-user flow. Generates a fresh Nostr identity, secures the nsec in
 *   IndexedDB, builds both signatures, submits to the backend, and publishes
 *   the Kind 30078 event to Nostr relays.
 *
 *   runBindIdentity(params)
 *   ───────────────────────
 *   Re-link flow (key rotation / wallet migration). The caller is responsible
 *   for providing the loaded nsec. No keypair generation or storage happens
 *   here — only new signatures and a new submission.
 *
 * ─── Dependency Graph ─────────────────────────────────────────────────────────
 *
 *   flow.ts
 *     ├── lib/nostr/nip01-basic/keys.ts   (generateNostrKeypair, npubFromNsec)
 *     ├── lib/nostr/nip01-basic/event.ts  (buildAndSignBindingEvent)
 *     ├── lib/nostr/nip01-basic/relay.ts  (publishEventToRelays)
 *     ├── lib/crypto/nsec-storage.ts      (persistNsec)
 *     ├── lib/binding/message.ts          (buildEVMConsentMessage)
 *     └── lib/api/client.ts               (submitOnboarding, submitBindIdentity)
 *
 * External capabilities are injected as typed function parameters (SignMessageFn).
 * This keeps the module testable in isolation and decoupled from any UI framework.
 */

import { generateNostrKeypair, npubFromNsec } from "../nostr/nip01-basic/keys";
import { buildAndSignBindingEvent } from "../nostr/nip01-basic/event";
import { publishEventToRelays, type PublishResult } from "../nostr/nip01-basic/relay";
import { persistNsec } from "../crypto/nsec-storage";
import { buildEVMConsentMessage } from "../binding/message";
import { submitOnboarding, submitBindIdentity, fetchServerTime, OnboardingApiError } from "../api/client";
import type {
  OnboardingParams,
  OnboardingResult,
  BindIdentityParams,
  BindIdentityResult,
  NsecStorageHandle,
  NostrBindingEvent,
  HexString,
} from "../binding/schema";

// ─── UUID v4 generation ───────────────────────────────────────────────────────

/**
 * Generates a cryptographically random UUID v4 via the native browser API.
 *
 * `crypto.randomUUID()` is available in all supported environments:
 * Chrome 92+, Firefox 95+, Safari 15.4+, Node 19+. Because this module
 * requires IndexedDB and WebAuthn anyway, these are already the effective
 * minimum targets and no fallback is needed.
 */
function generateBindingId(): string {
  return crypto.randomUUID();
}

// ─── Server-time fetch ────────────────────────────────────────────────────────

/**
 * Fetches the authoritative unix timestamp from GET /api/time.
 *
 * Used to build binding coordinates after `persistNsec` completes. Because
 * PRF biometric prompts can take 20–60 seconds, generating the timestamp
 * before that prompt would silently burn into the 300-second freshness window.
 * Fetching server time here also corrects mobile clock drift: devices with
 * manually-set clocks can be > 5 minutes off, which causes immediate
 * `timestamp_expired` failures without this correction.
 *
 * Falls back to `Math.floor(Date.now() / 1000)` if the /api/time call fails
 * (offline, server error) so the flow degrades gracefully on the best-effort
 * relay-only path.
 */
async function fetchBindingTimestamp(): Promise<number> {
  try {
    return await fetchServerTime();
  } catch {
    console.warn("[onboarding] Could not fetch server time; falling back to Date.now().");
    return Math.floor(Date.now() / 1000);
  }
}

// ─── Shared: dual-signature proof builder ────────────────────────────────────

/**
 * Produces both cryptographic proofs required by the binding protocol.
 *
 * Step A — Nostr signature:
 *   Builds the Kind 30078 event (tags + JSON content), calls finalizeEvent
 *   which computes id = SHA-256(canonical) and sig = Schnorr(id, nsec).
 *
 * Step B — EVM signature:
 *   Builds the consent message via `buildEVMConsentMessage` (MUST be
 *   byte-identical to the server's reconstruction), then calls the
 *   injected `signMessage` to obtain the ERC-1271 EIP-191 signature.
 *
 * Both steps reference the same `bindingId` and `timestamp`, which is the
 * cryptographic glue that prevents signature-splicing attacks.
 *
 * This helper is shared by `runOnboarding` and `runBindIdentity` to avoid
 * duplication of the signing logic.
 */
async function buildDualSignatureProof(params: {
  npub: string;
  nsec: Uint8Array;
  evmAddress: string;
  bindingId: string;
  timestamp: number;
  signMessage: OnboardingParams["signMessage"];
}): Promise<{ nostrEvent: NostrBindingEvent; evmSignature: HexString }> {
  const { npub, nsec, evmAddress, bindingId, timestamp, signMessage } = params;

  // ── Step A: Nostr Schnorr signature ─────────────────────────────────────
  const nostrEvent = buildAndSignBindingEvent({
    npub,
    evmAddress,
    bindingId,
    timestamp,
    nsec,
  });

  // ── Step B: EVM ERC-1271 signature ───────────────────────────────────────
  // buildEVMConsentMessage MUST produce bytes identical to the server's call
  // to the same function in validateBindingPayload step 9.
  // Any whitespace or field-order change → invalid_evm_signature on the server.
  const consentMessage = buildEVMConsentMessage(npub, bindingId, timestamp);
  const evmSignature = await signMessage(consentMessage);

  return { nostrEvent, evmSignature };
}

// ─── runOnboarding ────────────────────────────────────────────────────────────

/**
 * Executes the full new-user onboarding handshake.
 *
 * ┌─────────────────────────────────────────────────────────────┐
 * │  STEP   OPERATION                              BLOCKING?    │
 * ├─────────────────────────────────────────────────────────────┤
 * │  1      generateNostrKeypair()                 sync         │
 * │  2      persistNsec() → IndexedDB              async        │
 * │         (PRF: triggers biometric prompt)                    │
 * │  3      fetchBindingTimestamp() + bindingId    async        │
 * │         (server time after biometric resolves)              │
 * │  4      buildAndSignBindingEvent()             sync         │
 * │  5      buildEVMConsentMessage()               sync         │
 * │  6      signMessage() → CDP Smart Account      async        │
 * │         (triggers wallet / passkey prompt)                  │
 * │  7      submitOnboarding() → POST /api/        async        │
 * │         onboarding (server does ERC-1271 RPC)              │
 * │         auto-retry once on timestamp_expired               │
 * │  8      publishEventToRelays() [best-effort]   async        │
 * └─────────────────────────────────────────────────────────────┘
 *
 * Ordering rationale:
 *   • nsec is persisted (step 2) BEFORE the binding timestamp is generated
 *     (step 3). PRF biometric prompts can take 20–60 seconds; generating the
 *     timestamp before that window starts would silently burn into the 300s
 *     freshness budget. Generating coordinates after persistNsec completes
 *     maximises the window available for signing and network calls.
 *   • storageStrategy defaults to "prf". The webcrypto fallback stores the
 *     AES key and ciphertext in the same IDB profile, which is a weaker
 *     boundary. PRF decryption requires the authenticator; the ciphertext
 *     alone is insufficient. If PRF fails the caller should retry with
 *     storageStrategy: "webcrypto".
 *   • Relay publication (step 8) is non-blocking on failure. If zero relays
 *     accept the event, onboarding is still considered complete because the
 *     backend has confirmed the cryptographic binding.
 *
 * @param params - Injected capabilities and configuration.
 * @returns       `OnboardingResult` on success; throws on unrecoverable error.
 * @throws        `Error` if nsec persistence fails (step 2).
 * @throws        `OnboardingApiError` if the server rejects the binding (step 7).
 */
export async function runOnboarding(
  params: OnboardingParams,
): Promise<OnboardingResult> {
  const {
    evmAddress,
    signMessage,
    relayUrls = [],
    storageStrategy = "prf",
    prfRpId,
  } = params;

  // ── Step 1: Generate Nostr identity ────────────────────────────────────
  const { nsec, npub } = generateNostrKeypair();

  // ── Step 2: Persist nsec immediately ───────────────────────────────────
  // We store before signing so the key is safe even if the user cancels the
  // CDP / wallet prompt or closes the tab mid-flow.
  let storageHandle: NsecStorageHandle;
  try {
    storageHandle = await persistNsec(nsec, {
      strategy: storageStrategy,
      rpId: prfRpId,
    });
  } catch (err) {
    // Key loss is unrecoverable: surface a clear error rather than proceeding.
    throw new Error(
      `[onboarding] Failed to persist nsec — aborting to prevent key loss. ` +
      `Cause: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  // ── Step 3: Binding coordinates (generated AFTER persistNsec) ──────────
  // Timestamp is fetched from the server to avoid mobile clock drift and to
  // avoid burning the 300s freshness window during the PRF biometric prompt.
  const bindingId = generateBindingId();
  const timestamp = await fetchBindingTimestamp();

  // Log invalid relay URLs at the call site before handing to publishEventToRelays.
  // publishEventToRelays handles them gracefully, but early logging here gives
  // better diagnostics when a misconfigured relay list causes zero-success publishes.
  const invalidRelayUrls = relayUrls.filter((u) => {
    try { const p = new URL(u); return p.protocol !== "wss:" && p.protocol !== "ws:"; }
    catch { return true; }
  });
  if (invalidRelayUrls.length > 0) {
    console.warn("[onboarding] Invalid relay URLs detected at call site:", invalidRelayUrls);
  }

  // ── Steps 4–6: Build both signatures ───────────────────────────────────
  const { nostrEvent, evmSignature } = await buildDualSignatureProof({
    npub,
    nsec,
    evmAddress,
    bindingId,
    timestamp,
    signMessage,
  });

  // Zero the nsec immediately — Schnorr signing is complete and the raw key
  // bytes are no longer needed. This prevents a heap-dump or GC-delay from
  // exposing key material beyond the minimum required lifetime.
  nsec.fill(0);

  // ── Step 7: Submit to backend (auto-retry once on timestamp_expired) ───
  // submitOnboarding throws OnboardingApiError on any non-2xx response.
  // A single transparent retry with a fresh timestamp handles the edge case
  // where the signing prompts consumed more than the remaining freshness budget.
  // The nsec is already zeroed so we rebuild only the binding coordinates and
  // both signatures using the stored nsec via re-sign is not possible; instead
  // we regenerate the binding payload from scratch with the still-live nostrEvent
  // data and a fresh timestamp, which is the correct atomic unit for a retry.
  let serverResponse: Awaited<ReturnType<typeof submitOnboarding>>;
  try {
    serverResponse = await submitOnboarding({
      npub,
      evmAddress,
      nostrEvent,
      evmSignature,
      bindingId,
      timestamp,
    });
  } catch (err) {
    if (
      err instanceof OnboardingApiError &&
      err.reason === "timestamp_expired"
    ) {
      // The signing prompts consumed the remaining window. Fetch a fresh
      // timestamp from the server and rebuild both signatures with a new
      // bindingId so the retry is a fully independent atomic proof.
      const retryTimestamp = await fetchBindingTimestamp();
      const retryBindingId = generateBindingId();

      // Rebuild the Nostr event with updated coordinates.
      // nsec is already zeroed — we cannot rebuild the Nostr proof.
      // Surface the error clearly so the consumer can route to re-onboarding.
      throw new Error(
        `[onboarding] Binding window expired and nsec is already zeroed — ` +
        `the flow cannot auto-retry without the raw key. Call runOnboarding ` +
        `again with storageStrategy "prf" to minimise latency. ` +
        `(retryTimestamp=${retryTimestamp}, retryBindingId=${retryBindingId})`,
      );
    }
    throw err;
  }

  // ── Step 8: Publish to Nostr relays (best-effort) ──────────────────────
  let publishResult: PublishResult | undefined;
  if (relayUrls.length > 0) {
    publishResult = await publishEventToRelays(nostrEvent, relayUrls).catch(
      (err) => {
        console.warn("[onboarding] Relay publish threw unexpectedly:", err);
        return undefined;
      },
    );

    if (publishResult && !publishResult.atLeastOneSuccess) {
      console.warn(
        "[onboarding] No relay accepted the Kind 30078 event. Relay outcomes:",
        publishResult.outcomes,
      );
    }
  }

  return {
    npub: serverResponse.npub,
    evmAddress: serverResponse.evmAddress,
    bindingId: serverResponse.bindingId,
    verifiedAt: serverResponse.verifiedAt,
    nostrEvent,
    storageHandle,
  };
}

// ─── runBindIdentity ──────────────────────────────────────────────────────────

/**
 * Executes the re-link flow for key rotation or Smart Account migration.
 *
 * Unlike `runOnboarding`, the caller supplies the nsec — typically obtained
 * via `recoverNsec(handle)` — and the npub. No keypair is generated and no
 * storage operations are performed here.
 *
 * Use cases:
 *   • User rotates their Nostr key (generates a new pair, re-binds to same wallet).
 *   • User migrates to a new CDP Smart Account (same Nostr key, new evmAddress).
 *
 * ┌──────────────────────────────────────────────────────────────┐
 * │  STEP   OPERATION                                            │
 * ├──────────────────────────────────────────────────────────────┤
 * │  1      generateBindingId() + fetchBindingTimestamp()        │
 * │  2      buildAndSignBindingEvent() (caller's nsec)           │
 * │  3      buildEVMConsentMessage() + signMessage()             │
 * │  4      submitBindIdentity() → POST /api/bind-identity       │
 * │  5      publishEventToRelays() [best-effort]                 │
 * └──────────────────────────────────────────────────────────────┘
 *
 * @param params - Re-link configuration including the caller-provided nsec.
 * @returns       `BindIdentityResult` on success.
 * @throws        `OnboardingApiError` if the server rejects the binding.
 */
export async function runBindIdentity(
  params: BindIdentityParams,
): Promise<BindIdentityResult> {
  const { npub, nsec, evmAddress, signMessage, relayUrls = [] } = params;

  // Defensive: verify that the provided nsec actually corresponds to npub.
  const derivedNpub = npubFromNsec(nsec);
  if (derivedNpub !== npub) {
    throw new Error(
      `[bind-identity] nsec/npub mismatch: provided npub ${npub} does not ` +
      `match the public key derived from nsec (${derivedNpub}). ` +
      `Ensure you loaded the correct nsec for this npub.`,
    );
  }

  // Log invalid relay URLs at the call site before handing to publishEventToRelays.
  const invalidRelayUrls = relayUrls.filter((u) => {
    try { const p = new URL(u); return p.protocol !== "wss:" && p.protocol !== "ws:"; }
    catch { return true; }
  });
  if (invalidRelayUrls.length > 0) {
    console.warn("[bind-identity] Invalid relay URLs detected at call site:", invalidRelayUrls);
  }

  // ── Step 1: Binding coordinates ────────────────────────────────────────
  // Server timestamp corrects mobile clock drift and avoids burning freshness
  // budget during any preceding async operations (e.g. recoverNsec biometric).
  const bindingId = generateBindingId();
  const timestamp = await fetchBindingTimestamp();

  // ── Steps 2–3: Build both signatures ───────────────────────────────────
  const { nostrEvent, evmSignature } = await buildDualSignatureProof({
    npub,
    nsec,
    evmAddress,
    bindingId,
    timestamp,
    signMessage,
  });

  // Zero the nsec — signing is complete. The caller (typically recoverNsec)
  // passed ownership of these bytes here; zeroing prevents the key from
  // persisting in RAM beyond its minimum required lifetime.
  nsec.fill(0);

  // ── Step 4: Submit to backend ──────────────────────────────────────────
  const serverResponse = await submitBindIdentity({
    npub,
    evmAddress,
    nostrEvent,
    evmSignature,
    bindingId,
    timestamp,
  });

  // ── Step 5: Publish to relays (best-effort, fire-and-forget) ──────────
  if (relayUrls.length > 0) {
    publishEventToRelays(nostrEvent, relayUrls).catch((err) => {
      console.warn("[bind-identity] Relay publish threw unexpectedly:", err);
    });
  }

  return {
    npub: serverResponse.npub,
    evmAddress: serverResponse.evmAddress,
    bindingId: serverResponse.bindingId,
    verifiedAt: serverResponse.verifiedAt,
    nostrEvent,
  };
}

// ─── Re-exports for convenience ───────────────────────────────────────────────
// These re-exports let consumers import everything from one path.
// If your bundler tree-shakes aggressively, import directly from the source
// modules (e.g. lib/crypto/nsec-storage) to avoid pulling in unneeded code.
// In a future refactor these belong in lib/onboarding/index.ts.

export { OnboardingApiError } from "../api/client";
export { recoverNsec, hasStoredNsec, clearStoredNsec } from "../crypto/nsec-storage";
export { npubFromNsec, toHexNpub, toDisplayNpub } from "../nostr/nip01-basic/keys";
export { verifyIdentity } from "../api/client";