"use client";

import { PrivyProvider } from "@privy-io/react-auth";
import { base } from "@privy-io/chains";

export default function Providers({ children }: { children: React.ReactNode }) {
  return (
    <PrivyProvider
      appId={process.env.NEXT_PUBLIC_PRIVY_APP_ID!}
      clientId={process.env.NEXT_PUBLIC_PRIVY_CLIENT_ID!}
      config={{
        appearance: {
          walletList: ['base_account'],
          showWalletLoginFirst: true
        },
        loginMethods: ['email', 'passkey'],
        defaultChain: base,

        subAccounts: {
          creation: 'on-connect',        // Auto-create on login
          defaultAccount: 'sub',         // Use sub for all transactions
          funding: 'spend-permissions'   // Auto-fund from main account
        }
      }}
    >
      {children}
    </PrivyProvider>
  );
}