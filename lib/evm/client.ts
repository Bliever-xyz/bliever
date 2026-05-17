/**
 * lib/evm/client.ts
 *
 * Singleton viem public client connected to Base (mainnet or Sepolia).
 *
 * Chain selection:
 *   NEXT_PUBLIC_BASE_CHAIN_ID=8453  → Base Mainnet
 *   NEXT_PUBLIC_BASE_CHAIN_ID=84532 → Base Sepolia (default / dev)
 *
 * RPC endpoint priority (tried in order via viem fallback transport):
 *   1. BASE_RPC_URL          – primary Alchemy key (recommended for production)
 *   2. BASE_RPC_FALLBACK_URL – secondary Alchemy key or QuickNode
 *   3. Public Base endpoint  – rate-limited, last resort / local dev only
 *
 * Each transport has a 10 s timeout and up to 2 automatic retries with a
 * 1 s delay before viem advances to the next transport in the chain.
 *
 * This client is used exclusively for ERC-1271 `isValidSignature` calls
 * during Smart Account signature verification. No write operations are
 * performed through this client.
 */

import { createPublicClient, http, fallback } from "viem";
import { base, baseSepolia } from "viem/chains";

cocdnst VALID_CHAIN_IDS = ["8453", "84532"] as const;
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

const publicFallbackUrl = isMainnet
  ? "https://mainnet.base.org"
  : "https://sepolia.base.org";

// ─── Transport chain (primary → fallback → public) ────────────────────────────
// viem's `fallback` transport tries each entry in order.
// A transport is skipped only if it throws or times out — not if the RPC
// returns a valid error response (e.g. eth_call reverts for ERC-1271).
const transportChain = [
  // 1️⃣  Primary Alchemy RPC
  ...(process.env.BASE_RPC_URL
    ? [http(process.env.BASE_RPC_URL, { timeout: 10_000, retryCount: 2, retryDelay: 1_000 })]
    : []),
  // 2️⃣  Secondary RPC (backup Alchemy key, QuickNode, etc.)
  ...(process.env.BASE_RPC_FALLBACK_URL
    ? [http(process.env.BASE_RPC_FALLBACK_URL, { timeout: 10_000, retryCount: 2, retryDelay: 1_000 })]
    : []),
  // 3️⃣  Public Base endpoint – rate-limited, always present as last resort
  http(publicFallbackUrl, { timeout: 10_000, retryCount: 2, retryDelay: 1_000 }),
];

export const basePublicClient = createPublicClient({
  chain,
  transport: fallback(transportChain),
});