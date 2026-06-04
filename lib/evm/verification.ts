/**
 * lib/evm/verification.ts
 *
 * EVM-side cryptographic utilities for the binding system.
 *
 * Smart Account support
 * ─────────────────────
 * CDP ERC-4337 Smart Accounts sign messages via their underlying passkey or
 * OAuth credential. The resulting signature is an ERC-1271 proof verified by
 * calling `isValidSignature(bytes32 hash, bytes sig)` on the contract.
 *
 * viem's `verifyMessage` handles both paths automatically:
 *   - If `address` is an EOA → recovers the signer via ecrecover and compares.
 *   - If `address` is a contract → calls `isValidSignature` via eth_call.
 *
 * The `client` parameter is required to enable the on-chain path.
 */

import { verifyMessage, getAddress } from "viem";
import { basePublicClient } from "./client";
import type { HexString, EvmAddressChecksummed } from "../binding/schema";

/**
 * Returns the EIP-55 checksummed form of `address` as a branded
 * `EvmAddressChecksummed`, or `null` if the input is not a valid Ethereum
 * address.
 *
 * The branded return type ensures downstream callers work only with addresses
 * that have passed through viem's checksum validation. Use this as the
 * single entry point when normalising any externally-supplied EVM address.
 */
export function safeNormalizeAddress(address: string): EvmAddressChecksummed | null {
  try {
    return getAddress(address) as EvmAddressChecksummed;
  } catch {
    return null;
  }
}

/**
 * Verifies an EIP-191 personal_sign message against an expected address.
 *
 * Supports both:
 *   - EOA wallets     (ecrecover path, no network call)
 *   - ERC-1271 Smart Accounts (isValidSignature eth_call to Base RPC)
 *
 * Returns `false` on any error rather than throwing, so callers can use
 * the result as a plain boolean guard.
 *
 * @param message          Plain-text string that was signed (pre-hash).
 * @param signature        0x-prefixed hex EIP-191 signature.
 * @param expectedAddress  EIP-55 checksummed address of the expected signer.
 */
export async function verifyEVMSignature(
  message: string,
  signature: HexString,
  expectedAddress: string,
): Promise<boolean> {
  try {
    return await verifyMessage({
      // Providing `client` enables ERC-1271 on-chain verification.
      // viem falls back to ecrecover for EOAs automatically.
      client: basePublicClient,
      address: expectedAddress as `0x${string}`,
      message,
      signature,
    });
  } catch (err) {
    // Log a structured entry so infrastructure failures (Alchemy down,
    // rate-limited) are distinguishable from bad signatures in log aggregators.
    console.error(
      JSON.stringify({
        module: "evm/verification",
        fn: "verifyEVMSignature",
        expectedAddress,
        error: err instanceof Error ? err.message : String(err),
      }),
    );
    return false;
  }
}