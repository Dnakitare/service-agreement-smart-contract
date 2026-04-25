"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import WalletGate from "@/components/WalletGate";
import {
  AgreementDetails,
  MilestoneDetails,
  fmtAddr,
  fmtEth,
  fmtTime,
  getAgreement,
  getMilestones,
  getWriteContract,
  statusOf,
  ZERO,
} from "@/lib/contract";

export default function AgreementDetailPage() {
  return (
    <WalletGate>
      {(account) => <AgreementDetail account={account} />}
    </WalletGate>
  );
}

function AgreementDetail({ account }: { account: string }) {
  const params = useParams<{ id: string }>();
  const id = Number(params.id);
  const router = useRouter();

  const [agreement, setAgreement] = useState<AgreementDetails | null>(null);
  const [milestones, setMilestones] = useState<MilestoneDetails[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function refresh() {
    setError(null);
    try {
      const a = await getAgreement(id);
      setAgreement(a);
      setMilestones(await getMilestones(id));
    } catch (e: any) {
      setError(e?.message ?? String(e));
    }
  }

  useEffect(() => {
    refresh();
  }, [id]);

  async function withTx<T>(label: string, fn: () => Promise<T>): Promise<T | null> {
    setBusy(true);
    setError(null);
    try {
      const r = await fn();
      await refresh();
      return r;
    } catch (e: any) {
      setError(`${label}: ${e?.shortMessage || e?.message || String(e)}`);
      return null;
    } finally {
      setBusy(false);
    }
  }

  if (error && !agreement) return <div className="text-red-400">{error}</div>;
  if (!agreement) return <div className="text-zinc-400">Loading…</div>;

  const isClient = account.toLowerCase() === agreement.client.toLowerCase();
  const isProvider = account.toLowerCase() === agreement.provider.toLowerCase();
  const status = statusOf(agreement);

  return (
    <div className="space-y-6">
      <div>
        <button
          onClick={() => router.push("/agreements")}
          className="text-sm text-zinc-400 hover:text-zinc-200"
        >
          ← Back
        </button>
        <h1 className="text-2xl font-semibold text-zinc-100 mt-2">
          Agreement #{String(agreement.id)}
        </h1>
      </div>

      <section className="rounded border border-zinc-800 p-4 grid grid-cols-2 md:grid-cols-3 gap-4 text-sm">
        <Field k="Status" v={status} />
        <Field k="Client" v={fmtAddr(agreement.client)} />
        <Field k="Provider" v={fmtAddr(agreement.provider)} />
        <Field k="Total" v={fmtEth(agreement.totalAmount)} />
        <Field k="Remaining" v={fmtEth(agreement.remainingAmount)} />
        <Field k="Deadline" v={fmtTime(agreement.deadline)} />
        <Field k="Created" v={fmtTime(agreement.createdAt)} />
        <Field k="Token" v={agreement.paymentToken === ZERO ? "ETH" : fmtAddr(agreement.paymentToken)} />
        <Field k="Your role" v={isClient ? "client" : isProvider ? "provider" : "third party"} />
      </section>

      <section>
        <h2 className="text-lg font-medium text-zinc-100 mb-2">Terms</h2>
        <p className="text-zinc-300 whitespace-pre-wrap text-sm bg-zinc-900/40 p-3 rounded border border-zinc-800">
          {agreement.terms}
        </p>
      </section>

      <section>
        <h2 className="text-lg font-medium text-zinc-100 mb-2">Milestones</h2>
        <table className="w-full text-sm border border-zinc-800">
          <thead className="bg-zinc-900 text-left text-zinc-400">
            <tr>
              <th className="px-3 py-2">#</th>
              <th className="px-3 py-2">Amount</th>
              <th className="px-3 py-2">Deadline</th>
              <th className="px-3 py-2">Evidence</th>
              <th className="px-3 py-2">Paid</th>
              <th className="px-3 py-2">Action</th>
            </tr>
          </thead>
          <tbody>
            {milestones.map((m) => (
              <MilestoneRow
                key={m.index}
                m={m}
                isClient={isClient}
                isProvider={isProvider}
                status={status}
                busy={busy}
                onSubmitEvidence={(hash) =>
                  withTx("submitMilestoneEvidence", async () => {
                    const c = await getWriteContract();
                    const tx = await c.submitMilestoneEvidence(id, m.index, hash);
                    await tx.wait();
                  })
                }
                onApprove={() =>
                  withTx("approveMilestone", async () => {
                    const c = await getWriteContract();
                    const tx = await c.approveMilestone(id, m.index);
                    await tx.wait();
                  })
                }
              />
            ))}
          </tbody>
        </table>
      </section>

      <section className="flex flex-wrap gap-2">
        {isClient && status === "active" && (
          <button
            disabled={busy}
            className="px-3 py-2 rounded bg-amber-700 hover:bg-amber-600 text-white text-sm"
            onClick={() => {
              const reason = prompt("Dispute reason?") ?? "";
              if (!reason) return;
              return withTx("raiseDispute (client)", async () => {
                const c = await getWriteContract();
                const tx = await c.raiseDispute(id, reason);
                await tx.wait();
              });
            }}
          >
            Raise dispute (client)
          </button>
        )}
        {isProvider && status === "active" && (
          <button
            disabled={busy}
            className="px-3 py-2 rounded bg-amber-700 hover:bg-amber-600 text-white text-sm"
            onClick={() => {
              const reason = prompt("Dispute reason?") ?? "";
              if (!reason) return;
              return withTx("raiseDispute (provider)", async () => {
                const c = await getWriteContract();
                const tx = await c.raiseDispute(id, reason);
                await tx.wait();
              });
            }}
          >
            Raise dispute (provider; only after deadline)
          </button>
        )}
        {isClient && status === "active" && (
          <button
            disabled={busy}
            className="px-3 py-2 rounded bg-zinc-700 hover:bg-zinc-600 text-white text-sm"
            onClick={() =>
              withTx("cancelAgreement", async () => {
                const reason = prompt("Cancellation reason?") ?? "";
                const c = await getWriteContract();
                const tx = await c.cancelAgreement(id, reason);
                await tx.wait();
              })
            }
          >
            Cancel (within 24h, no paid milestones)
          </button>
        )}
      </section>

      {error && (
        <div className="text-red-400 text-sm">{error}</div>
      )}
    </div>
  );
}

function Field({ k, v }: { k: string; v: string }) {
  return (
    <div>
      <div className="text-zinc-500 text-xs uppercase tracking-wide">{k}</div>
      <div className="text-zinc-200 font-mono mt-0.5 break-all">{v}</div>
    </div>
  );
}

function MilestoneRow({
  m,
  isClient,
  isProvider,
  status,
  busy,
  onSubmitEvidence,
  onApprove,
}: {
  m: MilestoneDetails;
  isClient: boolean;
  isProvider: boolean;
  status: ReturnType<typeof statusOf>;
  busy: boolean;
  onSubmitEvidence: (hash: string) => Promise<unknown>;
  onApprove: () => Promise<unknown>;
}) {
  const canApprove = isClient && status === "active" && !m.paid && m.evidenceHash !== "";
  const canSubmit = isProvider && status === "active" && !m.paid;

  return (
    <tr className="border-t border-zinc-800">
      <td className="px-3 py-2 font-mono">{m.index}</td>
      <td className="px-3 py-2">{fmtEth(m.amount)}</td>
      <td className="px-3 py-2">{fmtTime(m.deadline)}</td>
      <td className="px-3 py-2 font-mono text-xs break-all">{m.evidenceHash || <span className="text-zinc-500">—</span>}</td>
      <td className="px-3 py-2">{m.paid ? "yes" : "no"}</td>
      <td className="px-3 py-2 space-x-2">
        {canSubmit && (
          <button
            disabled={busy}
            className="px-2 py-1 rounded bg-blue-700 hover:bg-blue-600 text-white text-xs"
            onClick={() => {
              const hash = prompt("Evidence hash (IPFS CID, etc.)") ?? "";
              if (hash) return onSubmitEvidence(hash);
            }}
          >
            Submit evidence
          </button>
        )}
        {canApprove && (
          <button
            disabled={busy}
            className="px-2 py-1 rounded bg-emerald-700 hover:bg-emerald-600 text-white text-xs"
            onClick={() => onApprove()}
          >
            Approve & pay
          </button>
        )}
      </td>
    </tr>
  );
}
