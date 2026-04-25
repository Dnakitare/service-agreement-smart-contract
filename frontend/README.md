# Reference dapp

A minimal Next.js + ethers v6 frontend that demonstrates the main `ServiceAgreement` flows. Use it as a starting point for your own integration; the source intentionally has no abstractions over the contract calls.

## What it covers

- **Connect wallet** — injected EIP-1193 wallet (MetaMask, Rabby, Frame, etc.). No wallet kit bundled.
- **List agreements** — pulls `getUserAgreements(account)` and renders status, role, counterparty, total.
- **Detail page** — shows agreement + milestones; renders role-specific actions (submit evidence as provider, approve+pay as client, raise dispute, cancel).
- **Create** — funds an ETH agreement with one or more milestones.
- **Withdraw** — pull-payment claim by token. ETH is blank-token.

What's deliberately not here: ERC20 funding (the principle is the same — `approve(serviceAgreement, total)` then call `createAgreement(...)`), arbitrator UI (resolveDispute), team propose/approve UI, ratings, owner / timelock UI. Add as needed.

## Setup

```bash
cd frontend
npm install
cp .env.example .env.local
# edit .env.local: NEXT_PUBLIC_CONTRACT_ADDRESS=0x...
npm run dev
```

If you're running against a local Hardhat node, deploy the proxy first (`npx hardhat run scripts/deploy.js` from the repo root) and paste the proxy address into `.env.local`. Make sure your wallet is on the right chain (chainId 31337 for `npx hardhat node`).

## Source layout

```
app/
  layout.tsx              # Root layout, header, nav.
  page.tsx                # Home / orientation.
  agreements/
    page.tsx              # Lists agreements for the connected account.
    [id]/page.tsx         # Detail + actions per role.
  create/page.tsx         # Create form (ETH).
  withdraw/page.tsx       # Pull-payment claim.
components/
  WalletGate.tsx          # Connect wallet, expose account to children.
lib/
  abi.json                # ABI exported from contract artifacts.
  contract.ts             # ethers wiring + small typed helpers.
```

## Why no wallet kit?

Wallet kits (RainbowKit, ConnectKit, Web3Modal) are great for production dapps but obscure the actual ethers call sequence. This reference is here to teach the contract surface — `lib/contract.ts` is ~120 lines of straightforward ethers v6.
