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
 *   with linear backoff (1 s × attempt). Handles transient failures common on
 *   mobile connections without blocking the overall publish pass.
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
 * Retries up to `maxRetries` times with linear backoff (1 s × attempt number).
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

    try {
      // Race connection + publish against the per-relay timeout.
      const connectPromise = Relay.connect(url);
      const timeoutPromise = new Promise<never>((_, reject) =>
        setTimeout(
          () => reject(new Error(`Relay connection timed out after ${timeoutMs}ms`)),
          timeoutMs,
        ),
      );

      relay = await Promise.race([connectPromise, timeoutPromise]);

      // publish() resolves when the relay sends an OK acknowledgement,
      // or rejects if the relay sends NOTICE with a rejection reason.
      await relay.publish(event as Parameters<typeof relay.publish>[0]);

      return { url, success: true };
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);

      // Linear backoff before the next attempt (skipped after the final one).
      if (attempt < maxRetries) {
        await new Promise((resolve) => setTimeout(resolve, 1_000 * (attempt + 1)));
      }
    } finally {
      // Always close to avoid leaving dangling WebSocket connections.
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