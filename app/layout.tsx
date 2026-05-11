// app/layout.tsx
import { CDPReactProvider } from "@coinbase/cdp-react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { http, createConfig } from "wagmi";
import { baseAccount } from "@base-org/account";

// Create wagmi config for Base Account support
const config = createConfig({
  chains: [baseSepolia],
  transports: {
    [baseSepolia.id]: http(),
  },
  connectors: [
    baseAccount(), // Base Account connector
  ],
});

const queryClient = new QueryClient();

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <CDPReactProvider
          config={{
            projectId: process.env.NEXT_PUBLIC_CDP_PROJECT_ID!,
            appName: process.env.NEXT_PUBLIC_CDP_APP_NAME!,
            ethereum: {
              createOnLogin: "smart", // ✅ ERC-4337 Smart Account
              chainId: parseInt(process.env.NEXT_PUBLIC_BASE_CHAIN_ID || "84532"),
            },
          }}
        >
          <WagmiProvider config={config}>
            <QueryClientProvider client={queryClient}>
              {children}
            </QueryClientProvider>
          </WagmiProvider>
        </CDPReactProvider>
      </body>
    </html>
  );
}