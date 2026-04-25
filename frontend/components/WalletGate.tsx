"use client";

import { useEffect, useState } from "react";

export default function WalletGate({ children }: { children: (account: string) => React.ReactNode }) {
  const [account, setAccount] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (typeof window === "undefined" || !window.ethereum) return;
    window.ethereum
      .request({ method: "eth_accounts" })
      .then((accts: string[]) => {
        if (accts[0]) setAccount(accts[0]);
      })
      .catch(() => {});

    const onChange = (accts: string[]) => setAccount(accts[0] ?? null);
    window.ethereum.on?.("accountsChanged", onChange);
    return () => {
      window.ethereum?.removeListener?.("accountsChanged", onChange);
    };
  }, []);

  async function connect() {
    setError(null);
    try {
      if (typeof window === "undefined" || !window.ethereum) {
        throw new Error("No wallet detected. Install MetaMask or another EIP-1193 wallet.");
      }
      const accts: string[] = await window.ethereum.request({ method: "eth_requestAccounts" });
      setAccount(accts[0] ?? null);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    }
  }

  if (!account) {
    return (
      <div className="flex flex-col items-start gap-3 max-w-xl">
        <button
          className="px-4 py-2 rounded bg-blue-600 hover:bg-blue-500 text-white"
          onClick={connect}
        >
          Connect wallet
        </button>
        {error && <div className="text-red-400 text-sm">{error}</div>}
        <p className="text-zinc-400 text-sm">
          This reference dapp uses an injected EIP-1193 wallet (MetaMask, Rabby, Frame, etc.). No
          wallet kit is bundled.
        </p>
      </div>
    );
  }

  return <>{children(account)}</>;
}
