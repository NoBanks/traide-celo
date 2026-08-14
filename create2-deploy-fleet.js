// THE FULL FIX: all-11 TRAIDE fleet deploy via TRUE CREATE2 (canonical proxy + versioned salts).
// Addresses depend ONLY on (proxy, salt, initCode) - nonces are irrelevant forever.
// 10 of 11 contracts are CHAIN-INVARIANT; TRAIDERouter is chain-dependent by design (native wrapped token arg).
// Salts: create2-salts-manifest.json (V1). Idempotent: re-running skips anything already deployed.
// Run: npx hardhat run create2-deploy-fleet.js --network goatTestnet3
//   (per-chain wrapped-native must be set in WRAPPED_NATIVE below before running a new chain)
const { ethers } = require("hardhat");
const fs = require("fs");

const MANIFEST = JSON.parse(fs.readFileSync(__dirname + "/create2-salts-manifest.json", "utf8"));
const PROXY = MANIFEST.proxy;
const FLEET_DEPLOYER = "0xcEDdA90b60748e04Ff9C4123c5f49544611748e5"; // constructor-arg constant (manifest note)

const WRAPPED_NATIVE = {
  48816: "0xbC10000000000000000000000000000000000000", // GOAT Testnet3 WGBTC (docs.goat.network, verified)
  114: null, // Flare Coston2 WC2FLR - fill from berachain/flare scripts before running there
  16602: "0x1Cd0690fF9a693f5EF2dD976660a8dAFc81A109c", // 0G Galileo W0G - ON-CHAIN VERIFIED 2026-08-14: symbol=W0G, name="Wrapped 0G", 18 dec, deposit()/withdraw() present (WETH9-style)
  11142220: "0x471EcE3750Da237f93B8E339c536989b8978a438", // Celo Sepolia GoldToken - ON-CHAIN VERIFIED 2026-08-14: symbol=CELO, "Celo native asset", 18 dec (Celo's native is ERC20-accessible; no separate wrapper)
  42220: "0x471EcE3750Da237f93B8E339c536989b8978a438", // Celo MAINNET GoldToken - ON-CHAIN VERIFIED 2026-08-14 via forno.celo.org eth_call: symbol=CELO (same canonical address as Sepolia). CREATE2 proxy also confirmed present on mainnet same day.
};

const abiCoder = ethers.AbiCoder.defaultAbiCoder();
function initCodeWithArgs(bytecode, types, values) {
  return types.length ? ethers.concat([bytecode, abiCoder.encode(types, values)]) : bytecode;
}
function predict(saltStr, initCode) {
  return ethers.getCreate2Address(PROXY, ethers.id(saltStr), ethers.keccak256(initCode));
}
async function deploy(signer, name, saltStr, initCode) {
  const addr = predict(saltStr, initCode);
  if ((await ethers.provider.getCode(addr)) !== "0x") { console.log(`= ${name}: already at ${addr} (idempotent)`); return addr; }
  const tx = await signer.sendTransaction({ to: PROXY, data: ethers.concat([ethers.id(saltStr), initCode]) });
  await tx.wait();
  // Load-balanced RPCs (Celo Sepolia forno) can route the post-wait getCode to a replica
  // that hasn't synced the just-mined block, throwing a FALSE "no code at predicted".
  // Bit twice on 2026-08-14 (Staking, then FeeDistribution - code WAS on-chain both times).
  // Retry the read up to 6x with 5s spacing before declaring failure. DO NOT REMOVE.
  for (let i = 0; i < 6; i++) {
    if ((await ethers.provider.getCode(addr)) !== "0x") { console.log(`✅ ${name}: ${addr}`); return addr; }
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error(`${name}: no code at predicted ${addr}`);
}

async function main() {
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const [signer] = await ethers.getSigners();
  if (signer.address.toLowerCase() !== FLEET_DEPLOYER.toLowerCase())
    throw new Error("Signer is not the fleet deployer wallet - constructor-arg invariance would break. Abort.");
  const weth = WRAPPED_NATIVE[chainId];
  if (!weth) throw new Error(`No wrapped-native configured for chainId ${chainId} - add it to WRAPPED_NATIVE first (verify from chain docs, never guess).`);
  if ((await ethers.provider.getCode(PROXY)) === "0x") throw new Error("Canonical CREATE2 proxy absent on this chain - install via its presigned tx first.");
  console.log(`⚙️  CREATE2 fleet deploy (salts ${MANIFEST.version}) on chainId ${chainId}`);
  console.log("balance:", ethers.formatEther(await ethers.provider.getBalance(signer.address)));

  const S = MANIFEST.salts;
  const art = async (n) => (await ethers.getContractFactory(n)).bytecode;
  const out = { chainId, method: "CREATE2 via canonical proxy", saltsVersion: MANIFEST.version, timestamp: new Date().toISOString(), deployer: signer.address, contracts: {} };

  // order mirrors the canonical fleet sequence; addresses do not depend on order (CREATE2), only deps do
  out.contracts.token = await deploy(signer, "Token", S.token, initCodeWithArgs(await art("TRAIDEToken"), ["uint256"], [ethers.parseEther("1000000000")]));
  out.contracts.amm = await deploy(signer, "AMM", S.amm, initCodeWithArgs(await art("TRAIDEAMM"), ["address","address"], [out.contracts.token, FLEET_DEPLOYER]));
  out.contracts.staking = await deploy(signer, "Staking", S.staking, initCodeWithArgs(await art("TRAIDEStaking"), ["address"], [out.contracts.token]));
  out.contracts.factory = await deploy(signer, "Factory", S.factory, initCodeWithArgs(await art("TRAIDEFactory"), ["address","address","address"], [FLEET_DEPLOYER, out.contracts.token, out.contracts.amm]));
  out.contracts.router = await deploy(signer, "Router(chain-dep)", S.router, initCodeWithArgs(await art("TRAIDERouter"), ["address","address"], [out.contracts.factory, weth]));
  out.contracts.governance = await deploy(signer, "Governance", S.governance, initCodeWithArgs(await art("TRAIDEGovernance"), ["address","address"], [out.contracts.token, ethers.ZeroAddress]));
  out.contracts.timelock = await deploy(signer, "Timelock", S.timelock, initCodeWithArgs(await art("TimelockController"), ["uint256","address[]","address[]","address"], [172800, [out.contracts.governance], [out.contracts.governance], FLEET_DEPLOYER]));
  out.contracts.oracle = await deploy(signer, "Oracle", S.oracle, await art("TRAIDEOracle"));
  out.contracts.feeDistribution = await deploy(signer, "FeeDistribution", S.feeDistribution, initCodeWithArgs(await art("TRAIDEFeeDistribution"), ["address","address"], [FLEET_DEPLOYER, out.contracts.staking]));
  out.contracts.multicall = await deploy(signer, "Multicall", S.multicall, await art("TRAIDEMulticall"));
  out.contracts.bridge = await deploy(signer, "Bridge", S.bridge, await art("TRAIDEBridge"));

  const file = `create2-fleet-${chainId}.json`;
  fs.writeFileSync(__dirname + "/" + file, JSON.stringify(out, null, 1));
  console.log(`\n🎉 CREATE2 fleet complete. Record: ${file}`);
  console.log("These 10 chain-invariant addresses are now THE canonical V1 set for every future chain + mainnet.");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
