/**
 * lib/evm/client.ts
 *
 * Singleton viem public client connected to Base (mainnet or Sepolia).
 *
 * Chain selection:
 *   NEXT_PUBLIC_BASE_CHAIN_ID=8453  → Base Mainnet
 *   NEXT_PUBLIC_BASE_CHAIN_ID=84532 → Base Sepolia (default / dev)
 *
 * RPC transport priority (tried in order via viem's `fallback` transport):
 *   1. BASE_RPC_URL          – primary private RPC (Alchemy, recommended)
 *   2. BASE_RPC_FALLBACK_URL – secondary private RPC (backup Alchemy key, QuickNode, etc.)
 *   3. Public Base endpoint  – rate-limited last resort (always present)
 *
 * Each transport has a 10 s timeout and 2 automatic retries (1 s delay).
 * A transport is skipped only on a network-level failure (timeout, connection
 * refused). A valid RPC error response (e.g. an ERC-1271 revert) does NOT
 * trigger failover — viem propagates it directly to the caller.
 *
 * This client is used exclusively for ERC-1271 `isValidSignature` calls
 * during Smart Account signature verification. No write operations are
 * performed through this client.
 */

import { createPublicClient, http, fallback } from "viem";
import { base, baseSepolia } from "viem/chains";

const VALID_CHAIN_IDS = ["8453", "84532"] as const;
const chainId = process.env.NEXT_PUBLIC_BASE_CHAIN_ID ?? "84532";

if (!VALID_CHAIN_IDS.includes(chainId as (typeof VALID_CHAIN_IDS)[number])) {
  throw new Error(
    `[lib/evm/client] Invalid NEXT_PUBLIC_BASE_CHAIN_ID: "${chainId}". ` +
    `Must be "8453" (Base Mainnet) or "84532" (Base Sepolia). ` +
    `Check your .env / deployment environment variables.`,
  );
}

const isMainnet = chainId === "8453";

const chain = isMainnet ? base : baseSepolia;

const publicRpcUrl = isMainnet
  ? "https://mainnet.base.org"
  : "https://sepolia.base.org";

const transportOptions = { timeout: 10_000, retryCount: 2, retryDelay: 1_000 };

// Build the ordered transport list. Only include env-var transports when the
// variable is actually set — avoids sending requests to an empty string URL.
const transports = [
  process.env.BASE_RPC_URL
    ? http(process.env.BASE_RPC_URL, transportOptions)
    : null,
  process.env.BASE_RPC_FALLBACK_URL
    ? http(process.env.BASE_RPC_FALLBACK_URL, transportOptions)
    : null,
  http(publicRpcUrl, { ...transportOptions, retryCount: 1 }),
].filter((t) => t !== null);

export const basePublicClient = createPublicClient({
  chain,
  transport: fallback(transports),
});