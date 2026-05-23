"use client";

/**
 * lib/nostr/relay.ts
 *
 * CLIENT-ONLY MODULE — requires browser WebSocket APIs.
 *
 * Publishes the signed Kind 30078 binding event to one or more Nostr relays.
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
 */

import { Relay } from "nostr-tools";
import type { NostrBindingEvent } from "../binding/schema";

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

  // allSettled: we want every relay's outcome, even if some throw.
  const settled = await Promise.allSettled(
    relayUrls.map((url) => publishToOne(event, url, timeoutMs, maxRetries)),
  );

  const outcomes: RelayPublishOutcome[] = settled.map((result, i) => {
    if (result.status === "fulfilled") return result.value;
    // A rejected promise from publishToOne means an unexpected throw;
    // publishToOne is written to never throw, but defensive guard stays.
    return {
      url: relayUrls[i] ?? "unknown",
      success: false,
      error: result.reason instanceof Error
        ? result.reason.message
        : String(result.reason),
    };
  });

  return {
    outcomes,
    atLeastOneSuccess: outcomes.some((o) => o.success),
  };
}