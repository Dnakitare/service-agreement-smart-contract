import Link from "next/link";

export default function Home() {
  return (
    <div className="space-y-8">
      <section>
        <h1 className="text-3xl font-semibold text-zinc-100">Reference dapp</h1>
        <p className="mt-3 text-zinc-300 max-w-2xl">
          A minimal Next.js / ethers v6 frontend that demonstrates the main flows of the
          {" "}
          <code className="font-mono text-zinc-400">ServiceAgreement</code> contract: create an
          agreement, submit and approve milestones, withdraw payouts. Built so an integrator can
          read the source and see how each call is constructed.
        </p>
      </section>

      <section className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <Card
          href="/agreements"
          title="Agreements"
          body="List your agreements — both as client and provider. Drill into a single agreement to act on it."
        />
        <Card
          href="/create"
          title="Create"
          body="Open a new agreement. Fund it with ETH or a whitelisted ERC20. Pick a template or write custom terms."
        />
        <Card
          href="/withdraw"
          title="Withdraw"
          body="Pull-payment claim. Anyone with credited balance (provider, team member, fee collector, refund) calls this."
        />
      </section>

      <section className="text-sm text-zinc-400">
        <p>
          Configure the contract address by setting{" "}
          <code className="font-mono text-zinc-300">NEXT_PUBLIC_CONTRACT_ADDRESS</code> in
          {" "}
          <code className="font-mono text-zinc-300">frontend/.env.local</code>. Source for every
          page is in{" "}
          <code className="font-mono text-zinc-300">frontend/app/</code>.
        </p>
      </section>
    </div>
  );
}

function Card({ href, title, body }: { href: string; title: string; body: string }) {
  return (
    <Link
      href={href}
      className="block rounded border border-zinc-800 hover:border-zinc-600 p-4 transition-colors"
    >
      <div className="text-zinc-100 font-medium">{title}</div>
      <div className="text-zinc-400 text-sm mt-2">{body}</div>
    </Link>
  );
}
