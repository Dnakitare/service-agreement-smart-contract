"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import WalletGate from "@/components/WalletGate";
import {
  AgreementDetails,
  fmtAddr,
  fmtEth,
  getAgreement,
  getReadContract,
  statusOf,
} from "@/lib/contract";

export default function AgreementsPage() {
  return (
    <WalletGate>
      {(account) => <AgreementsList account={account} />}
    </WalletGate>
  );
}

function AgreementsList({ account }: { account: string }) {
  const [items, setItems] = useState<AgreementDetails[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const c = await getReadContract();
        const ids: bigint[] = await c.getUserAgreements(account);
        const details = await Promise.all(ids.map((id) => getAgreement(id)));
        setItems(details);
      } catch (e: any) {
        setError(e?.message ?? String(e));
      }
    })();
  }, [account]);

  if (error) return <div className="text-red-400">{error}</div>;
  if (!items) return <div className="text-zinc-400">Loading…</div>;
  if (items.length === 0)
    return (
      <div className="text-zinc-300">
        No agreements yet for <code className="font-mono">{fmtAddr(account)}</code>. Try{" "}
        <Link href="/create">creating one</Link>.
      </div>
    );

  return (
    <div className="space-y-3">
      <h1 className="text-2xl font-semibold text-zinc-100">Your agreements</h1>
      <div className="text-zinc-400 text-sm">
        Connected as <code className="font-mono">{fmtAddr(account)}</code>
      </div>
      <table className="w-full text-sm border border-zinc-800">
        <thead className="bg-zinc-900 text-left text-zinc-400">
          <tr>
            <th className="px-3 py-2">ID</th>
            <th className="px-3 py-2">Role</th>
            <th className="px-3 py-2">Counterparty</th>
            <th className="px-3 py-2">Total</th>
            <th className="px-3 py-2">Status</th>
            <th className="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          {items.map((a) => {
            const role = a.client.toLowerCase() === account.toLowerCase() ? "client" : "provider";
            const counterparty = role === "client" ? a.provider : a.client;
            return (
              <tr key={String(a.id)} className="border-t border-zinc-800">
                <td className="px-3 py-2 font-mono">{String(a.id)}</td>
                <td className="px-3 py-2">{role}</td>
                <td className="px-3 py-2 font-mono">{fmtAddr(counterparty)}</td>
                <td className="px-3 py-2">{fmtEth(a.totalAmount)}</td>
                <td className="px-3 py-2">
                  <StatusBadge s={statusOf(a)} />
                </td>
                <td className="px-3 py-2">
                  <Link
                    href={`/agreements/${a.id}`}
                    className="text-blue-400 hover:text-blue-300"
                  >
                    Open →
                  </Link>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function StatusBadge({ s }: { s: ReturnType<typeof statusOf> }) {
  const colors = {
    active: "bg-emerald-900/40 text-emerald-300 border-emerald-700",
    disputed: "bg-amber-900/40 text-amber-300 border-amber-700",
    cancelled: "bg-zinc-800 text-zinc-400 border-zinc-700",
    completed: "bg-blue-900/40 text-blue-300 border-blue-700",
  } as const;
  return (
    <span className={`inline-block px-2 py-0.5 rounded border text-xs ${colors[s]}`}>
      {s}
    </span>
  );
}
