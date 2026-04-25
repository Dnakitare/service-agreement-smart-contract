"use client";

import { useState } from "react";
import { ethers } from "ethers";
import { useRouter } from "next/navigation";
import WalletGate from "@/components/WalletGate";
import { getWriteContract, ZERO } from "@/lib/contract";

export default function CreatePage() {
  return (
    <WalletGate>
      {() => <CreateForm />}
    </WalletGate>
  );
}

interface MilestoneRow {
  amount: string; // ETH (or token units, written by the user)
  daysFromNow: string;
}

function CreateForm() {
  const router = useRouter();
  const [provider, setProvider] = useState("");
  const [terms, setTerms] = useState("Build a marketing site per spec…");
  const [milestones, setMilestones] = useState<MilestoneRow[]>([
    { amount: "1", daysFromNow: "7" },
  ]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function addRow() {
    setMilestones((prev) => [...prev, { amount: "", daysFromNow: "" }]);
  }
  function removeRow(i: number) {
    setMilestones((prev) => prev.filter((_, j) => j !== i));
  }
  function updateRow(i: number, k: keyof MilestoneRow, v: string) {
    setMilestones((prev) => prev.map((m, j) => (j === i ? { ...m, [k]: v } : m)));
  }

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      if (!ethers.isAddress(provider)) throw new Error("Provider must be a valid address");
      const now = Math.floor(Date.now() / 1000);
      const dueDates: bigint[] = [];
      const amounts: bigint[] = [];
      let total = 0n;
      for (const m of milestones) {
        const days = Number(m.daysFromNow);
        if (!Number.isFinite(days) || days <= 0) throw new Error("Each milestone needs days > 0");
        const ts = BigInt(now + Math.round(days * 86400));
        dueDates.push(ts);
        const wei = ethers.parseEther(m.amount || "0");
        if (wei <= 0n) throw new Error("Each milestone needs amount > 0");
        amounts.push(wei);
        total += wei;
      }
      // chronological sanity (UI side)
      for (let i = 1; i < dueDates.length; i++) {
        if (dueDates[i] <= dueDates[i - 1]) throw new Error("Milestone deadlines must be strictly increasing");
      }

      const c = await getWriteContract();
      const tx = await c.createAgreement(provider, terms, dueDates, amounts, ZERO, { value: total });
      const receipt = await tx.wait();

      // Find the AgreementCreated event to grab the new ID.
      const log = receipt.logs
        .map((l: any) => {
          try { return c.interface.parseLog(l); } catch { return null; }
        })
        .find((p: any) => p && p.name === "AgreementCreated");
      const newId = log?.args?.agreementId;

      if (newId !== undefined) router.push(`/agreements/${newId}`);
      else router.push("/agreements");
    } catch (e: any) {
      setError(e?.shortMessage || e?.message || String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-6 max-w-2xl">
      <h1 className="text-2xl font-semibold text-zinc-100">Create agreement (ETH)</h1>

      <Field label="Provider">
        <input
          className="w-full"
          placeholder="0x…"
          value={provider}
          onChange={(e) => setProvider(e.target.value)}
        />
      </Field>

      <Field label="Terms">
        <textarea
          className="w-full"
          rows={3}
          value={terms}
          onChange={(e) => setTerms(e.target.value)}
        />
      </Field>

      <div>
        <div className="text-sm text-zinc-400 mb-1">Milestones</div>
        <div className="space-y-2">
          {milestones.map((m, i) => (
            <div key={i} className="flex gap-2 items-center">
              <span className="text-zinc-500 text-xs w-6">#{i}</span>
              <input
                className="w-32"
                placeholder="Amount (ETH)"
                value={m.amount}
                onChange={(e) => updateRow(i, "amount", e.target.value)}
              />
              <input
                className="w-32"
                placeholder="Days from now"
                value={m.daysFromNow}
                onChange={(e) => updateRow(i, "daysFromNow", e.target.value)}
              />
              {milestones.length > 1 && (
                <button
                  className="text-zinc-400 text-sm hover:text-zinc-200"
                  onClick={() => removeRow(i)}
                >
                  remove
                </button>
              )}
            </div>
          ))}
        </div>
        <button
          className="mt-2 text-sm text-blue-400 hover:text-blue-300"
          onClick={addRow}
        >
          + add milestone
        </button>
      </div>

      <button
        disabled={busy}
        className="px-4 py-2 rounded bg-blue-600 hover:bg-blue-500 text-white"
        onClick={submit}
      >
        {busy ? "Submitting…" : "Create & fund"}
      </button>

      {error && <div className="text-red-400 text-sm">{error}</div>}

      <p className="text-zinc-500 text-xs">
        ETH only on this form. For ERC20 funding, see <code>scripts/deploy.js</code> and the
        scenarios doc — the same flow applies but the client must <code>approve</code> the
        contract for the token total before submitting.
      </p>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <div className="text-sm text-zinc-400 mb-1">{label}</div>
      {children}
    </label>
  );
}
