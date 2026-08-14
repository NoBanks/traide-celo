# TRAIDE on Celo

The TRAIDE DEX fleet (11 contracts) deployed to Celo with deterministic CREATE2 addresses
and verified source on Blockscout. Part of the TRAIDE multi-chain deployment: the same 10
chain-invariant addresses exist on every chain the fleet ships to, because every address
depends only on (canonical CREATE2 proxy, versioned salt, initCode) and never on nonces.

## Verified contracts, Celo Sepolia (chainId 11142220)

All 11 verified on [Blockscout](https://celo-sepolia.blockscout.com) on 2026-08-14.

| Contract | Address |
|---|---|
| TRAIDEToken | `0x341936d89E1182c52440351B7AA1070001CEeb99` |
| TRAIDEAMM | `0x4b6781AfC7e91D65acdD37a424D7A43f170f9120` |
| TRAIDEStaking | `0x61ebb11021aF722e5B88412e89C8943cC774A7Dd` |
| TRAIDEFactory | `0xC1b443bDD37128ceB15e9b6F2c4DD3284e92259f` |
| TRAIDERouter (chain-dependent) | `0xc5628f0B3aDcD0F08158B7798600e974E9E8C506` |
| TRAIDEGovernance | `0x0bA8977C22EB07d8CdFbC87D7bB5c988578e0D7F` |
| TimelockController | `0x675eb11A7C49fE2d03a9B6eEE7aCeb6b50a03611` |
| TRAIDEOracle | `0xDe730c24018C0bdb7d821B331Cdc6C444041199f` |
| TRAIDEFeeDistribution | `0xCCE43DEf5912e53ab17dA22C7805fe5698216dc3` |
| TRAIDEMulticall | `0x1B210947E967E69bB480053F0cD2b7E1bb2A4024` |
| TRAIDEBridge | `0xe6F21B958592E3C4F35a1c5a654a4f626c13e3f7` |

10 of 11 addresses are byte-identical to the TRAIDE fleets on 0G Galileo (16602) and GOAT
Testnet3 (48816). TRAIDERouter is chain-dependent by design: its constructor takes the
chain's wrapped-native token, which on Celo is the native-as-ERC20 GoldToken
`0x471EcE3750Da237f93B8E339c536989b8978a438` (no separate wrapper needed, a Celo feature).

## Quickstart

```bash
npm install
npx hardhat compile
cp .env.example .env   # add your deployer PRIVATE_KEY
npm run deploy:sepolia # idempotent: re-running skips anything already deployed
npm run verify:sepolia # verifies all 11 on Blockscout via the v2 standard-input API
```

The deploy is fully idempotent. Running it against a chain where the fleet already exists
prints `already at <address> (idempotent)` for every contract and sends zero transactions.
This doubles as a bytecode-reproducibility check: a fresh clone of this repo recomputes the
same initCode and therefore the same addresses.

## Celo Mainnet

Same commands, mainnet network:

```bash
npm run deploy:mainnet   # chainId 42220
npm run verify:mainnet
```

Preflight already confirmed on mainnet (2026-08-14, via forno.celo.org):
- The canonical CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` is deployed.
- GoldToken `0x471EcE3750Da237f93B8E339c536989b8978a438` responds `symbol() = CELO`.

## How the determinism works

- `create2-salts-manifest.json` holds the versioned salt strings (V1) and the canonical
  proxy address. Salts are hashed with `keccak256(saltString)`.
- Each address = `CREATE2(proxy, keccak256(salt), keccak256(initCode))`.
- Compiler is pinned (solc 0.8.25, optimizer runs 200, viaIR) and dependencies are pinned
  exactly (OpenZeppelin 5.4.0, Chainlink 1.4.0) because initCode, and therefore every
  address, depends on the exact bytecode.
- Deployment records land in `create2-fleet-<chainId>.json`.

## License

MIT
