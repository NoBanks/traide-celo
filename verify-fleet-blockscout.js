// Verify the CREATE2 fleet on Blockscout via the native v2 standard-input API.
// Method history (2026-08-14 rehearsal): hardhat-verify broke on undici
// ("opts.dispatcher is not supported"); the etherscan-compat verifysourcecode
// wrapper returned blanket "Unable to verify"; the v2 standard-input endpoint
// with THIS repo's lean ~50-source build-info verifies in ~30s per contract.
// The main TRAIDE monorepo's 245-source build-info chokes their compiler queue,
// so always verify FROM THIS REPO after `npx hardhat compile`.
// Run: node verify-fleet-blockscout.js <chainId>   (11142220 Celo Sepolia, 42220 Celo mainnet, 46630 Robinhood testnet)
const fs = require("fs");

const CHAIN = Number(process.argv[2] || "11142220");
const BASE = {
  11142220: "https://celo-sepolia.blockscout.com",
  46630: "https://explorer.testnet.chain.robinhood.com", // Robinhood Chain Testnet (Blockscout), fleet deployed 2026-09-03
  42220: "https://celo.blockscout.com",
}[CHAIN];
if (!BASE) { console.error("no explorer for chain", CHAIN); process.exit(1); }

const biDir = __dirname + "/artifacts/build-info";
const biFile = fs.readdirSync(biDir).map(f => biDir + "/" + f)
  .find(f => fs.readFileSync(f, "utf8").includes("contracts/TRAIDEToken.sol"));
if (!biFile) { console.error("run `npx hardhat compile` first"); process.exit(1); }
const BUILD = JSON.parse(fs.readFileSync(biFile, "utf8"));
const INPUT = JSON.stringify(BUILD.input);
const SOLC = "v" + BUILD.solcLongVersion;

const rec = JSON.parse(fs.readFileSync(`${__dirname}/create2-fleet-${CHAIN}.json`, "utf8"));
const c = rec.contracts;

const JOBS = [
  ["Token", c.token, "contracts/TRAIDEToken.sol:TRAIDEToken"],
  ["AMM", c.amm, "contracts/TRAIDEAMM.sol:TRAIDEAMM"],
  ["Staking", c.staking, "contracts/TRAIDEStaking.sol:TRAIDEStaking"],
  ["Factory", c.factory, "contracts/TRAIDEFactory.sol:TRAIDEFactory"],
  ["Router", c.router, "contracts/TRAIDERouter.sol:TRAIDERouter"],
  ["Governance", c.governance, "contracts/TRAIDEGovernance.sol:TRAIDEGovernance"],
  ["Timelock", c.timelock, "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController"],
  ["Oracle", c.oracle, "contracts/TRAIDEOracle.sol:TRAIDEOracle"],
  ["FeeDistribution", c.feeDistribution, "contracts/TRAIDEFeeDistribution.sol:TRAIDEFeeDistribution"],
  ["Multicall", c.multicall, "contracts/TRAIDEMulticall.sol:TRAIDEMulticall"],
  ["Bridge", c.bridge, "contracts/TRAIDEBridge.sol:TRAIDEBridge"],
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function status(addr) {
  try {
    const j = await (await fetch(`${BASE}/api/v2/smart-contracts/${addr}`)).json();
    return j && j.is_verified ? j.name || "verified" : null;
  } catch { return null; }
}

async function main() {
  let ok = 0, already = 0, failed = [];
  for (const [name, address, fqn] of JOBS) {
    if (await status(address)) { console.log(`ALREADY: ${name} ${address}`); already++; continue; }
    const fd = new FormData();
    fd.append("compiler_version", SOLC);
    fd.append("contract_name", fqn);
    fd.append("autodetect_constructor_args", "true");
    fd.append("files[0]", new Blob([INPUT], { type: "application/json" }), "input.json");
    const r = await fetch(`${BASE}/api/v2/smart-contracts/${address}/verification/via/standard-input`, { method: "POST", body: fd });
    if (r.status !== 200) { console.log(`FAILED-SUBMIT: ${name}: HTTP ${r.status} ${(await r.text()).slice(0, 120)}`); failed.push(name); continue; }
    let verified = null;
    for (let i = 0; i < 24; i++) { await sleep(5000); verified = await status(address); if (verified) break; }
    if (verified) { console.log(`VERIFIED: ${name} ${address} (as ${verified})`); ok++; }
    else { console.log(`FAILED: ${name} ${address}: not verified after 120s`); failed.push(name); }
  }
  console.log(`\nSUMMARY chain ${CHAIN}: verified=${ok} already=${already} failed=${failed.length}${failed.length ? " (" + failed.join(", ") + ")" : ""}`);
}

main();
