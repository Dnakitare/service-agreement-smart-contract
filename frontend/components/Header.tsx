"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { CONTRACT_ADDRESS, EXPECTED_CHAIN_ID, fmtAddr } from "@/lib/contract";

export default function Header() {
  const [chainId, setChainId] = useState<bigint | null>(null);

  useEffect(() => {
    if (typeof window === "undefined" || !window.ethereum) return;
    const read = async () => {
      try {
        const hex: string = await window.ethereum.request({ method: "eth_chainId" });
        setChainId(BigInt(hex));
      } catch {
        setChainId(null);
      }
    };
    read();
    const onChange = () => {
      // Full reload is the standard dapp pattern: drop all cached state.
      window.location.reload();
    };
    window.ethereum.on?.("chainChanged", onChange);
    return () => window.ethereum?.removeListener?.("chainChanged", onChange);
  }, []);

  const chainOk = EXPECTED_CHAIN_ID === null || chainId === EXPECTED_CHAIN_ID;

  return (
    <header className="border-b border-zinc-800">
      <div className="max-w-5xl mx-auto px-6 py-4 flex items-center justify-between gap-4 flex-wrap">
        <Link href="/" className="font-mono text-zinc-200 hover:text-white">
          ServiceAgreement
        </Link>
        <nav className="flex gap-4 text-sm text-zinc-400">
          <Link href="/agreements">Agreements</Link>
          <Link href="/create">Create</Link>
          <Link href="/withdraw">Withdraw</Link>
          <a href="https://github.com/dnakitare/service-agreement" target="_blank" rel="noreferrer">
            Repo
          </a>
        </nav>
      </div>
      <div className="max-w-5xl mx-auto px-6 pb-3 text-xs text-zinc-500 flex flex-wrap gap-x-4 gap-y-1">
        <span>
          Contract:{" "}
          <code className="font-mono text-zinc-300">
            {CONTRACT_ADDRESS ? fmtAddr(CONTRACT_ADDRESS) : "(not set)"}
          </code>
        </span>
        <span className={chainOk ? "" : "text-red-400"}>
          Chain:{" "}
          <code className="font-mono">
            {chainId === null ? "—" : String(chainId)}
            {EXPECTED_CHAIN_ID !== null && (
              <>
                {" "}
                / expected {String(EXPECTED_CHAIN_ID)} {chainOk ? "✓" : "✗"}
              </>
            )}
          </code>
        </span>
      </div>
    </header>
  );
}
