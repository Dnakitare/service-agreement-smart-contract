"use client";

import { useEffect, useState } from "react";
import { ethers } from "ethers";
import WalletGate from "@/components/WalletGate";
import {
  fmtAddr,
  fmtEth,
  getReadContract,
  getWriteContract,
  ZERO,
} from "@/lib/contract";

export default function WithdrawPage() {
  return (
    <WalletGate>
      {(account) => <WithdrawPanel account={account} />}
    </WalletGate>
  );
}

function WithdrawPanel({ account }: { account: string }) {
  const [tokenInput, setTokenInput] = useState<string>("");
  const [pending, setPending] = useState<bigint | null>(null);
  const [token, setToken] = useState<string>(ZERO);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function refresh(t: string) {
    try {
      setError(null);
      const c = await getReadContract();
      const p: bigint = await c.pendingWithdrawals(t, account);
      setPending(p);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    }
  }

  useEffect(() => {
    refresh(ZERO);
  }, [account]);

  async function setTokenAndRefresh() {
    let t = tokenInput.trim();
    if (!t) t = ZERO;
    if (t !== ZERO && !ethers.isAddress(t)) {
      setError("Not a valid address");
      return;
    }
    setToken(t);
    refresh(t);
  }

  async function withdraw() {
    setBusy(true);
    setError(null);
    try {
      const c = await getWriteContract();
      const tx = await c.withdraw(token);
      await tx.wait();
      await refresh(token);
    } catch (e: any) {
      setError(e?.shortMessage || e?.message || String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4 max-w-xl">
      <h1 className="text-2xl font-semibold text-zinc-100">Withdraw</h1>
      <p className="text-zinc-400 text-sm">
        All payouts are pull payments. The contract holds your balance until you withdraw.
        Connected as <code className="font-mono">{fmtAddr(account)}</code>.
      </p>

      <div className="flex gap-2 items-end">
        <div className="flex-1">
          <div className="text-sm text-zinc-400 mb-1">Token (blank = ETH)</div>
          <input
            className="w-full"
            placeholder="0x… or leave empty for ETH"
            value={tokenInput}
            onChange={(e) => setTokenInput(e.target.value)}
          />
        </div>
        <button
          className="px-3 py-2 rounded bg-zinc-700 hover:bg-zinc-600 text-white text-sm"
          onClick={setTokenAndRefresh}
        >
          Check balance
        </button>
      </div>

      <div className="rounded border border-zinc-800 p-4">
        <div className="text-zinc-500 text-xs uppercase tracking-wide">Pending</div>
        <div className="font-mono text-zinc-100 mt-1">
          {pending === null ? "—" : token === ZERO ? fmtEth(pending) : `${pending.toString()} (raw token units)`}
        </div>
      </div>

      <button
        disabled={busy || !pending || pending === 0n}
        className="px-4 py-2 rounded bg-emerald-700 hover:bg-emerald-600 text-white"
        onClick={withdraw}
      >
        {busy ? "Withdrawing…" : "Withdraw"}
      </button>

      {error && <div className="text-red-400 text-sm">{error}</div>}
    </div>
  );
}
