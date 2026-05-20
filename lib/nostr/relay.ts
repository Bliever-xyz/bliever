/**
 * lib/nostr/relay.ts
 *
 * Publishes the signed Kind 30078 binding event to one or more Nostr relays.
 *
 * Design decisions:
 *
 *   Parallel publication — all relays are attempted concurrently. There is no
 *   reason to serialise; individual relay failures are non-fatal.
 *
 *   Per-relay timeout — each relay gets its own AbortController-backed timeout
 *   (default 8 s). A slow relay does not block the others.
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
 * Returns a resolved outcome regardless of success/failure (never throws).
 */
async function publishToOne(
  event: NostrBindingEvent,
  url: string,
  timeoutMs: number,
): Promise<RelayPublishOutcome> {
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
    return {
      url,
      success: false,
      error: err instanceof Error ? err.message : String(err),
    };
  } finally {
    // Always close to avoid leaving dangling WebSocket connections.
    relay?.close();
  }
}

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Publishes a signed Nostr event to multiple relays in parallel.
 *
 * All relays are attempted concurrently. Each relay has an independent timeout.
 * Individual relay failures are captured and returned; they do NOT throw.
 *
 * @param event      Fully signed Kind 30078 binding event.
 * @param relayUrls  WebSocket relay URLs (wss://…).
 * @param timeoutMs  Per-relay connect+publish timeout. Default 8 000 ms.
 * @returns          Aggregated `PublishResult` with per-relay outcomes.
 */
export async function publishEventToRelays(
  event: NostrBindingEvent,
  relayUrls: string[],
  timeoutMs = 8_000,
): Promise<PublishResult> {
  if (relayUrls.length === 0) {
    return { outcomes: [], atLeastOneSuccess: false };
  }

  // allSettled: we want every relay's outcome, even if some throw.
  const settled = await Promise.allSettled(
    relayUrls.map((url) => publishToOne(event, url, timeoutMs)),
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