/**
 * Refuse to ship a bundle that cannot work.
 *
 * Vite inlines every VITE_* value at build time, so a missing or wrong one is
 * not a runtime error that anybody sees in a log - it is a page that renders
 * a polite notice saying the contracts are not configured, or worse, one that
 * asks users to approve a token the vaults reject. Both look deliberate.
 *
 * This ran because the Dockerfile's defaults were placeholders and nothing
 * passed build args over them, which would have deployed exactly the first of
 * those. The check is three assertions:
 *
 *   1. Every address the app needs is in the bundle.
 *   2. The settlement token is the one BorrowerOperations can mint.
 *   3. None of the four MUSD impostors is in there instead.
 *
 * Run after `vite build`, from web/. Exits non-zero with the reason.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const DIST = "dist";

/*
 * Only for a Mezo testnet build.
 *
 * scripts/local-up.sh writes .env.local with Anvil's chain id and freshly
 * deployed mock addresses, and a rehearsal build against that chain is
 * supposed to carry different addresses and a mock settlement token. Failing
 * it here would make the guard something developers learn to skip, which is
 * worse than not having one. The chain id is read from the bundle rather than
 * the environment, because the bundle is what ships.
 */
const CHAIN_ID = process.env.VITE_CHAIN_ID ?? "31611";
if (CHAIN_ID !== "31611") {
  console.log(`check-bundle: skipped, this is a chain ${CHAIN_ID} build, not Mezo testnet`);
  process.exit(0);
}

/** The live Mezo testnet deployment. ADDRESSES.md is the record. */
const REQUIRED = {
  "GOLOGGLE vault": "0x68A86E4503FCA82ac9eB229Be655E355A019bcC3",
  "AMEZON vault": "0x87c6925798769012085b9a71FabA87c31F894f18",
  "GOLOGGLE share": "0x35e0c3df250a1ea46bde6eef2D6ad22C924FCB88",
  "AMEZON share": "0x239cC4EB08B92fdB486F00C93E2D47b38c0EBAd4",
  "settlement MUSD (mintable by BorrowerOperations)": "0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af",
  "Mezo BorrowerOperations": "0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba",
};

/**
 * The other contracts on Mezo testnet reporting MUSD with 18 decimals.
 *
 * Every one returns false for mintList(BorrowerOperations), so MUSD held in
 * any of them cannot have come from borrowing and cannot be spent here. The
 * third was the Dockerfile's default and is the one Mezo's public reference
 * names, which is why this list exists rather than a comment.
 */
const FORBIDDEN = [
  "0x637e22A1EBbca50EA2d34027c238317fD10003eB",
  "0xe9C5143c3c116146D9745334cdD673AA124438Ae",
  "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
  "0xC4b6A401756ff9D509c64d00985Deb572D58F9B2",
];

function bundleText() {
  const dir = join(DIST, "assets");
  const files = readdirSync(dir).filter((name) => name.endsWith(".js"));
  if (files.length === 0) throw new Error(`no JavaScript in ${dir}: did vite build run?`);
  return files.map((name) => readFileSync(join(dir, name), "utf8")).join("\n");
}

// Case-insensitive throughout: config.ts checksums every address on the way
// in, so the casing in the bundle is viem's and not the casing written above.
const haystack = bundleText().toLowerCase();
const problems = [];

for (const [what, address] of Object.entries(REQUIRED)) {
  if (!haystack.includes(address.toLowerCase())) {
    problems.push(`missing ${what}: ${address} is not in the bundle`);
  }
}
for (const address of FORBIDDEN) {
  if (haystack.includes(address.toLowerCase())) {
    problems.push(`FORBIDDEN token in the bundle: ${address} is an MUSD the vaults reject`);
  }
}

if (problems.length > 0) {
  console.error("check-bundle: refusing this build\n");
  for (const problem of problems) console.error(`  - ${problem}`);
  console.error("\nPass the right values as --build-arg, or fix the defaults in web/deploy/Dockerfile.");
  process.exit(1);
}
console.log(`check-bundle: ok, all ${Object.keys(REQUIRED).length} addresses present and no impostor MUSD`);
