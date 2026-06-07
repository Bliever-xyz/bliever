"use client";

/**
 * lib/nostr/nip01-basic/relay.ts
 *
 * CLIENT-ONLY MODULE — requires browser WebSocket APIs.
 *
 * NIP-01 relay interactions: event publication and event subscription.
 *
 * ─── Publication ──────────────────────────────────────────────────────────────
 *
 * `publishEventToRelays` sends a fully signed event to one or more relays in
 * parallel. Each relay gets its own independent timeout and retry budget.
 *
 * Design decisions:
 *
 *   Parallel publication — all relays are attempted concurrently. There is no
 *   reason to serialise; individual relay failures are non-fatal.
 *
 *   Per-relay timeout — each relay gets its own timeout (default 8 s). A slow
 *   relay does not block the others.
 *
 *   Per-relay retry — each relay is retried up to `maxRetries` times (default 2)
 *   with linear backoff (1 s × attempt). Retries only fire on transient errors
 *   (timeout, network drop, WebSocket close). Permanent relay rejections such as
 *   "BAD EVENT" or "blocked" break immediately — retrying them wastes time and
 *   delays the overall publish outcome.
 *
 *   Partial success is ok — the caller (`flow.ts`) only needs at least one
 *   relay to accept the event for the social graph to be discoverable.
 *   If zero relays accept, a warning is logged but onboarding is not rolled
 *   back (the backend has already confirmed the cryptographic binding).
 *
 *   Connection cleanup — each Relay connection is closed in the `finally`
 *   block regardless of outcome. No persistent WebSocket connections are kept
 *   open by this module.
 *
 * ─── Subscription / Reading ───────────────────────────────────────────────────
 *
 * `fetchNostrEvents` reads stored events from one or more relays using
 * nostr-tools `SimplePool`. A pool manages multiple WebSocket connections
 * concurrently, so slow or offline relays do not block delivery from the
 * others.
 *
 * Every received event is cryptographically verified (id + Schnorr sig) before
 * being returned. Malicious or malformed events are silently dropped.
 *
 * The pool is closed in a `finally` block to release all WebSocket connections
 * once the EOSE (End of Stored Events) signal is received from each relay.
 * No persistent connections are maintained by this module.
 */

import { Relay, SimplePool, verifyEvent } from "nostr-tools";
import type { Filter } from "nostr-tools";
import type { NostrBindingEvent } from "../../binding/schema";

// ─── Result types ─────────────────────────────────────────────────────────────

/** Outcome for a single relay URL. */
export interface RelayPublishOutcome {
  url: string;
  success: boolean;
  /** Error message if `success` is false. */
  error?: string;
}

/** Aggregated result across all attempted relays. */
export interface PublishResult {
  outcomes: RelayPublishOutcome[];
  /** True when at least one relay acknowledged the event. */
  atLeastOneSuccess: boolean;
}

// ─── Internal: URL validation ─────────────────────────────────────────────────

/**
 * Returns `true` if `url` is a syntactically valid WebSocket URL.
 * Filters out common mistakes such as http:// URLs or bare hostnames before
 * the connection attempt, preventing an 8-second timeout on a locally-
 * detectable error.
 */
function isValidRelayUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "wss:" || parsed.protocol === "ws:";
  } catch {
    return false;
  }
}

// ─── Internal: single-relay publish ──────────────────────────────────────────

/**
 * Connects to one relay, publishes the event, and closes the connection.
 *
 * A single `timeoutMs` budget covers the **entire** attempt — both the
 * initial `Relay.connect()` and the subsequent `relay.publish()`. This
 * prevents a relay that accepts the connection but then goes silent from
 * hanging the slot indefinitely.
 *
 * Retries up to `maxRetries` times with linear backoff (1 s × attempt
 * number), but ONLY on transient errors (timeout, network drop, WebSocket
 * close). Permanent relay rejections (e.g. "BAD EVENT", "blocked",
 * "duplicate") break immediately — retrying them cannot succeed.
 *
 * Returns a resolved outcome regardless of success/failure (never throws).
 */
async function publishToOne(
  event: NostrBindingEvent,
  url: string,
  timeoutMs: number,
  maxRetries: number,
): Promise<RelayPublishOutcome> {
  let lastError = "";

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    let relay: Relay | null = null;
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined;

    try {
      // One timeout promise covers both connect AND publish for this attempt.
      // The handle is cleared on success to avoid a dangling timer.
      const timeoutPromise = new Promise<never>((_, reject) => {
        timeoutHandle = setTimeout(
          () => reject(new Error(`Relay timed out after ${timeoutMs}ms`)),
          timeoutMs,
        );
      });

      relay = await Promise.race([Relay.connect(url), timeoutPromise]);

      // publish() resolves on relay OK, rejects on NOTICE rejection.
      // The same timeoutPromise guards against a silent relay post-connect.
      await Promise.race([
        relay.publish(event as Parameters<typeof relay.publish>[0]),
        timeoutPromise,
      ]);

      return { url, success: true };
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);

      // Retry only on transient failures; fail fast on permanent rejections.
      const isTransient = /timeout|network|websocket/i.test(lastError);
      if (attempt < maxRetries && isTransient) {
        await new Promise((resolve) => setTimeout(resolve, 1_000 * (attempt + 1)));
      } else if (!isTransient) {
        break; // Permanent relay rejection — skip remaining attempts.
      }
    } finally {
      clearTimeout(timeoutHandle);
      relay?.close();
    }
  }

  return { url, success: false, error: lastError };
}

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Publishes a signed Nostr event to multiple relays in parallel.
 *
 * All relays are attempted concurrently. Each relay has an independent timeout
 * and is retried up to `maxRetries` times with linear backoff on failure.
 * Individual relay failures are captured and returned; they do NOT throw.
 *
 * URLs that are not valid WebSocket addresses (wss:// or ws://) are rejected
 * immediately without attempting a connection. Their outcomes are returned with
 * `success: false` so the caller can identify misconfigured relay lists.
 *
 * @param event       Fully signed Kind 30078 binding event.
 * @param relayUrls   WebSocket relay URLs (wss://…).
 * @param timeoutMs   Per-relay connect+publish timeout per attempt. Default 8 000 ms.
 * @param maxRetries  How many additional attempts to make per relay on failure. Default 2.
 * @returns           Aggregated `PublishResult` with per-relay outcomes.
 */
export async function publishEventToRelays(
  event: NostrBindingEvent,
  relayUrls: string[],
  timeoutMs = 8_000,
  maxRetries = 2,
): Promise<PublishResult> {
  if (relayUrls.length === 0) {
    return { outcomes: [], atLeastOneSuccess: false };
  }

  // Partition URLs up front: invalid URLs get an immediate failure outcome
  // rather than wasting a full timeoutMs slot before failing.
  const validUrls = relayUrls.filter(isValidRelayUrl);
  const invalidUrls = relayUrls.filter((u) => !isValidRelayUrl(u));

  if (invalidUrls.length > 0) {
    console.warn(
      "[relay] Skipping invalid relay URLs (must start with wss:// or ws://):",
      invalidUrls,
    );
  }

  const invalidOutcomes: RelayPublishOutcome[] = invalidUrls.map((url) => ({
    url,
    success: false,
    error: "Invalid relay URL: must be a wss:// or ws:// WebSocket address.",
  }));

  if (validUrls.length === 0) {
    return { outcomes: invalidOutcomes, atLeastOneSuccess: false };
  }

  // allSettled: we want every relay's outcome, even if some throw.
  const settled = await Promise.allSettled(
    validUrls.map((url) => publishToOne(event, url, timeoutMs, maxRetries)),
  );

  const validOutcomes: RelayPublishOutcome[] = settled.map((result, i) => {
    if (result.status === "fulfilled") return result.value;
    // A rejected promise from publishToOne means an unexpected throw;
    // publishToOne is written to never throw, but defensive guard stays.
    return {
      url: validUrls[i] ?? "unknown",
      success: false,
      error: result.reason instanceof Error
        ? result.reason.message
        : String(result.reason),
    };
  });

  const outcomes = [...validOutcomes, ...invalidOutcomes];

  return {
    outcomes,
    atLeastOneSuccess: outcomes.some((o) => o.success),
  };
}

// ─── Subscription / Reading ───────────────────────────────────────────────────

/**
 * NIP-01 filter parameters for `fetchNostrEvents`.
 * Maps directly onto the NIP-01 REQ filter object.
 */
export interface FetchEventsParams {
  /** WebSocket relay URLs to subscribe to (wss://…). */
  relayUrls: string[];
  /**
   * Restrict results to events signed by these public keys (64-char hex).
   * Omit to fetch events from all authors.
   */
  authors?: string[];
  /**
   * Restrict results to these event kinds (e.g. `[0]` for profiles,
   * `[1]` for text notes, `[30078]` for binding events).
   */
  kinds?: number[];
  /**
   * Return only events created after this unix timestamp.
   * Useful for incremental sync: pass the `created_at` of the newest
   * locally-cached event to fetch only what is newer.
   */
  since?: number;
  /**
   * Return only events created before this unix timestamp.
   * Useful for pagination: pass the `created_at` of the oldest event
   * in the current page to fetch the next page back in time.
   */
  until?: number;
  /**
   * Maximum number of events to request per relay.
   * Relays are not obligated to honour this exactly.
   * @default 50
   */
  limit?: number;
}

/**
 * Fetches stored Nostr events from one or more relays using `SimplePool`.
 *
 * A `SimplePool` manages multiple WebSocket connections concurrently, merging
 * results across relays. This is the standard NIP-01 reading pattern:
 * subscribing until the EOSE (End of Stored Events) signal is received, then
 * closing the subscription.
 *
 * Every received event is cryptographically verified (event `id` integrity +
 * Schnorr signature) before inclusion in the result. Events that fail
 * verification are silently dropped with a console warning — a relay sending
 * invalid events should not surface forged data to the application.
 *
 * The pool is fully closed in a `finally` block once EOSE is received from
 * every subscribed relay. No persistent WebSocket connections remain open.
 *
 * Results are sorted newest-first (`created_at` descending).
 *
 * @param params - Filter parameters. All fields except `relayUrls` are optional.
 * @returns       Verified events sorted newest-first. Empty array on error.
 */
export async function fetchNostrEvents(
  params: FetchEventsParams,
): Promise<NostrBindingEvent[]> {
  const { relayUrls, authors, kinds, since, until, limit = 50 } = params;

  if (relayUrls.length === 0) {
    return [];
  }

  // Validate relay URLs up front — same logic as publishEventToRelays.
  // Invalid URLs would cause SimplePool to throw or silently fail.
  const validUrls = relayUrls.filter(isValidRelayUrl);
  if (validUrls.length === 0) {
    console.warn(
      "[relay] fetchNostrEvents: no valid relay URLs provided (must be wss:// or ws://).",
    );
    return [];
  }

  const pool = new SimplePool();
  const verified: NostrBindingEvent[] = [];

  try {
    // Build the NIP-01 REQ filter — omit undefined keys so the relay does
    // not interpret them as empty-set constraints.
    // nostr-tools 2.x SimplePool.subscribeMany accepts a single Filter object.
    const filter: Filter = {
      ...(authors && { authors }),
      ...(kinds && { kinds }),
      ...(since !== undefined && { since }),
      ...(until !== undefined && { until }),
      limit,
    };

    await new Promise<void>((resolve) => {
      const sub = pool.subscribeMany(validUrls, filter, {
        onevent(event) {
          // Cryptographically verify id and Schnorr sig before accepting.
          // Relays should do this themselves, but a malicious relay could
          // serve unsigned or tampered events.
          if (verifyEvent(event)) {
            // Cast is safe: NostrBindingEvent is structurally identical to
            // the nostr-tools Event type (id, pubkey, kind, created_at,
            // tags, content, sig).
            verified.push(event as unknown as NostrBindingEvent);
          } else {
            console.warn("[relay] Dropped unverifiable event:", event.id);
          }
        },
        oneose() {
          // End of Stored Events — the relay has delivered all historical
          // events matching the filter. Close the subscription and resolve.
          sub.close();
          resolve();
        },
      });
    });

    // Sort newest-first for consistent consumer behaviour.
    return verified.sort((a, b) => b.created_at - a.created_at);
  } catch (err) {
    console.error("[relay] fetchNostrEvents error:", err);
    return [];
  } finally {
    // Release all WebSocket connections regardless of outcome.
    pool.close(validUrls);
  }
}