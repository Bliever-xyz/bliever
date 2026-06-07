/**
 * lib/nostr/index.ts
 *
 * Master re-export for the Nostr protocol library.
 *
 * Structure follows a NIP-by-NIP modular pattern: each subfolder owns the
 * schema, builders, and resolvers for exactly one protocol extension.
 * Importing from this root barrel gives access to every public symbol
 * without coupling the consumer to the internal folder layout.
 *
 * Current modules:
 *   nip01-basic/     — Keypairs, event building, relay publish + subscribe
 *   nip09-deletions/ — Kind 5 tombstone events (placeholder, coming soon)
 *
 * Adding a new NIP:
 *   1. Create lib/nostr/nipXX-name/ with schema.ts, builder.ts, index.ts.
 *   2. Add `export * from "./nipXX-name"` below.
 *   3. The new module's API is instantly available to all consumers of this
 *      barrel without any other file needing to change.
 */

export * from "./nip01-basic";