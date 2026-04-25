import type { Metadata } from "next";
import "./globals.css";
import Link from "next/link";

export const metadata: Metadata = {
  title: "ServiceAgreement reference dapp",
  description: "Reference frontend for the ServiceAgreement contract.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <header className="border-b border-zinc-800">
          <div className="max-w-5xl mx-auto px-6 py-4 flex items-center justify-between">
            <Link href="/" className="font-mono text-zinc-200 hover:text-white">
              ServiceAgreement
            </Link>
            <nav className="flex gap-4 text-sm text-zinc-400">
              <Link href="/agreements">Agreements</Link>
              <Link href="/create">Create</Link>
              <Link href="/withdraw">Withdraw</Link>
              <a
                href="https://github.com/dnakitare/service-agreement"
                target="_blank"
                rel="noreferrer"
              >
                Repo
              </a>
            </nav>
          </div>
        </header>
        <main className="max-w-5xl mx-auto px-6 py-8">{children}</main>
      </body>
    </html>
  );
}
