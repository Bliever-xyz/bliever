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

const chainId = process.env.NEXT_PUBLIC_BASE_CHAIN_ID;
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