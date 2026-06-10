import { getAddress } from "viem";     
import { basePublicClient } from "./client";
import type { HexString, EvmAddressChecksummed } from "../binding/schema";

/**
 * Returns the EIP-55 checksummed form of `address` as a branded
 * `EvmAddressChecksummed`, or `null` if the input is not a valid Ethereum
 * address.
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
 * - EOA wallets     (ecrecover path, no network call)
 * - ERC-1271 Smart Accounts (isValidSignature eth_call to Base RPC)
 */
export async function verifyEVMSignature(
  message: string,
  signature: HexString,
  expectedAddress: string,
): Promise<boolean> {
  try {
    // Calling verifyMessage on the client invokes the Action, 
    // which natively handles both EOA recovery and ERC-1271 verification.
    return await basePublicClient.verifyMessage({
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