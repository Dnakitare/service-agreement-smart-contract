"use client";

import { BrowserProvider, Contract, JsonRpcSigner, ethers } from "ethers";
import abi from "./abi.json";

// The proxy address is read from NEXT_PUBLIC_CONTRACT_ADDRESS at build time.
// For local Hardhat: set this to whatever upgrades.deployProxy printed.
export const CONTRACT_ADDRESS =
  (process.env.NEXT_PUBLIC_CONTRACT_ADDRESS as `0x${string}`) ?? "";

// Optional chain-id pin. Recommended in production. Ex. for Hardhat: 31337.
export const EXPECTED_CHAIN_ID = process.env.NEXT_PUBLIC_CHAIN_ID
  ? BigInt(process.env.NEXT_PUBLIC_CHAIN_ID)
  : null;

declare global {
  interface Window {
    ethereum?: any;
  }
}

export const ZERO = ethers.ZeroAddress;
export const FEE_BPS = 100n; // matches PLATFORM_FEE_BPS in the contract
export const BPS = 10_000n;

export function getProvider() {
  if (typeof window === "undefined" || !window.ethereum) {
    throw new Error("No injected wallet found. Install a wallet (e.g., MetaMask) or use a browser with one.");
  }
  return new BrowserProvider(window.ethereum);
}

export async function assertExpectedChain(): Promise<void> {
  if (EXPECTED_CHAIN_ID === null) return;
  const provider = getProvider();
  const network = await provider.getNetwork();
  if (network.chainId !== EXPECTED_CHAIN_ID) {
    throw new Error(
      `Wrong network: wallet is on chainId ${network.chainId}, this dapp expects ${EXPECTED_CHAIN_ID}. ` +
        `Switch your wallet's network and reload.`
    );
  }
}

export async function getSigner(): Promise<JsonRpcSigner> {
  const provider = getProvider();
  await provider.send("eth_requestAccounts", []);
  await assertExpectedChain();
  return provider.getSigner();
}

export async function getReadContract(): Promise<Contract> {
  if (!CONTRACT_ADDRESS) {
    throw new Error("Set NEXT_PUBLIC_CONTRACT_ADDRESS in frontend/.env.local");
  }
  const provider = getProvider();
  return new Contract(CONTRACT_ADDRESS, abi, provider);
}

export async function getWriteContract(): Promise<Contract> {
  if (!CONTRACT_ADDRESS) {
    throw new Error("Set NEXT_PUBLIC_CONTRACT_ADDRESS in frontend/.env.local");
  }
  const signer = await getSigner();
  return new Contract(CONTRACT_ADDRESS, abi, signer);
}

// Strongly-typed shape mirrors getAgreementDetails return tuple.
export interface AgreementDetails {
  id: bigint;
  client: string;
  provider: string;
  totalAmount: bigint;
  remainingAmount: bigint;
  deadline: bigint;
  createdAt: bigint;
  completed: boolean;
  disputed: boolean;
  cancelled: boolean;
  paymentToken: string;
  terms: string;
}

export async function getAgreement(id: number | bigint): Promise<AgreementDetails> {
  const c = await getReadContract();
  const a = await c.getAgreementDetails(id);
  return {
    id: BigInt(id),
    client: a[0],
    provider: a[1],
    totalAmount: a[2],
    remainingAmount: a[3],
    deadline: a[4],
    createdAt: a[5],
    completed: a[6],
    disputed: a[7],
    cancelled: a[8],
    paymentToken: a[9],
    terms: a[10],
  };
}

export interface MilestoneDetails {
  index: number;
  deadline: bigint;
  amount: bigint;
  completed: boolean;
  paid: boolean;
  evidenceHash: string;
}

export async function getMilestones(id: number | bigint): Promise<MilestoneDetails[]> {
  const c = await getReadContract();
  const ms = await c.getMilestones(id);
  return ms.map((m: any, i: number) => ({
    index: i,
    deadline: m.deadline,
    amount: m.amount,
    completed: m.completed,
    paid: m.paid,
    evidenceHash: m.evidenceHash,
  }));
}

export function statusOf(a: AgreementDetails): "active" | "disputed" | "cancelled" | "completed" {
  if (a.cancelled) return "cancelled";
  if (a.completed) return "completed";
  if (a.disputed) return "disputed";
  return "active";
}

export function fmtEth(wei: bigint): string {
  return `${ethers.formatEther(wei)} ETH`;
}

export function fmtAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function fmtTime(unix: bigint | number): string {
  const ts = typeof unix === "bigint" ? Number(unix) : unix;
  return new Date(ts * 1000).toLocaleString();
}

/// Compute keccak256(bytes(evidenceHash)) for the on-chain commitment check.
export function evidenceCommitment(evidenceHash: string): string {
  return ethers.keccak256(ethers.toUtf8Bytes(evidenceHash));
}
