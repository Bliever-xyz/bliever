/**
 * lib/evm/client.ts
 *
 * Singleton viem public client connected to Base (mainnet or Sepolia).
 *
 * Chain selection:
 *   NEXT_PUBLIC_BASE_CHAIN_ID=8453  → Base Mainnet
 *   NEXT_PUBLIC_BASE_CHAIN_ID=84532 → Base Sepolia (default / dev)
 *
 * RPC endpoint priority:
 *   1. BASE_RPC_URL env var (private RPC, recommended for production)
 *   2. Public fallback (rate-limited, dev only)
 *
 * This client is used exclusively for ERC-1271 `isValidSignature` calls
 * during Smart Account signature verification. No write operations are
 * performed through this client.
 */

import { createPublicClient, http } from "viem";
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

const rpcUrl =
  process.env.BASE_RPC_URL ??
  (isMainnet
    ? "https://mainnet.base.org"
    : "https://sepolia.base.org");

export const basePublicClient = createPublicClient({
  chain,
  transport: http(rpcUrl),
});
