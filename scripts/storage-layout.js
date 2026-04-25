/**
 * Extract the ServiceAgreement storage layout from compiler artifacts and write
 * a normalized JSON snapshot to docs/storage-layout.json.
 *
 * Run with: `npm run storage` (regenerate) or pass `--check` to verify the
 * committed snapshot matches the current contract.
 *
 * Why this exists: UUPS upgrade safety hinges on storage layout NOT shifting
 * across versions. Hardhat's `--force compile` produces full layouts; we extract
 * and pin the relevant pieces so any silent layout change shows up as a CI diff.
 */
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const ARTIFACT_DIR = path.join(__dirname, "..", "artifacts", "build-info");
const SNAPSHOT_PATH = path.join(__dirname, "..", "docs", "storage-layout.json");
const TARGETS = ["contracts/ServiceAgreement.sol:ServiceAgreement"];

function ensureFreshArtifacts() {
  // Build with storage layout enabled. We invoke solc directly via Hardhat task
  // to keep the existing toolchain.
  execSync("npx hardhat compile --force", { stdio: "inherit" });
}

function findLayout() {
  // Hardhat doesn't include storage layout in its default artifact JSONs, but
  // the build-info file produced by the compiler does. Search build-info/*.json.
  const files = fs.existsSync(ARTIFACT_DIR)
    ? fs.readdirSync(ARTIFACT_DIR).filter((f) => f.endsWith(".json"))
    : [];
  if (files.length === 0) {
    throw new Error("No build-info artifacts found. Did `hardhat compile` run?");
  }
  for (const f of files) {
    const data = JSON.parse(fs.readFileSync(path.join(ARTIFACT_DIR, f), "utf8"));
    const out = data.output && data.output.contracts;
    if (!out) continue;
    for (const target of TARGETS) {
      const [file, name] = target.split(":");
      if (out[file] && out[file][name] && out[file][name].storageLayout) {
        return { target, layout: out[file][name].storageLayout };
      }
    }
  }
  throw new Error("Storage layout not found in build-info. Make sure outputSelection includes 'storageLayout'.");
}

function normalize(layout) {
  // Drop the AST IDs (which can change between unrelated compiles) and keep
  // just the structurally meaningful fields per slot.
  return {
    storage: layout.storage.map((s) => ({
      label: s.label,
      offset: s.offset,
      slot: s.slot,
      type: s.type,
      contract: s.contract,
    })),
    types: Object.fromEntries(
      Object.entries(layout.types).map(([k, v]) => [
        k,
        {
          encoding: v.encoding,
          label: v.label,
          numberOfBytes: v.numberOfBytes,
          ...(v.members
            ? {
                members: v.members.map((m) => ({
                  label: m.label,
                  offset: m.offset,
                  slot: m.slot,
                  type: m.type,
                })),
              }
            : {}),
          ...(v.base ? { base: v.base } : {}),
          ...(v.key ? { key: v.key } : {}),
          ...(v.value ? { value: v.value } : {}),
        },
      ])
    ),
  };
}

function main() {
  const args = process.argv.slice(2);
  const checkOnly = args.includes("--check");

  ensureFreshArtifacts();
  const { target, layout } = findLayout();
  const normalized = normalize(layout);
  const serialized = JSON.stringify({ target, layout: normalized }, null, 2) + "\n";

  if (checkOnly) {
    if (!fs.existsSync(SNAPSHOT_PATH)) {
      console.error(`Snapshot ${SNAPSHOT_PATH} does not exist. Generate it with 'npm run storage'.`);
      process.exit(1);
    }
    const existing = fs.readFileSync(SNAPSHOT_PATH, "utf8");
    if (existing !== serialized) {
      console.error("Storage layout has drifted from the committed snapshot.");
      console.error("If this change is intentional and upgrade-safe (append-only), regenerate:");
      console.error("  npm run storage");
      console.error("Otherwise, fix the contract.");
      process.exit(1);
    }
    console.log(`Storage layout matches snapshot at ${path.relative(process.cwd(), SNAPSHOT_PATH)}.`);
  } else {
    fs.mkdirSync(path.dirname(SNAPSHOT_PATH), { recursive: true });
    fs.writeFileSync(SNAPSHOT_PATH, serialized);
    console.log(`Wrote ${path.relative(process.cwd(), SNAPSHOT_PATH)}.`);
  }
}

main();
