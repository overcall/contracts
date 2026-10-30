# Overcall contracts

Smart contracts of the Overcall protocol on Robinhood Chain. The first product is **Channel**:
a player draws a price corridor (center, height, slope, duration) on an asset and takes a side.
**Survive** wins if the price stays inside the corridor until it ends; **Breach** wins if the
price touches a wall first. Prices come from Chainlink Data Streams reports, verified on-chain.

The sources in this repository are the ones deployed on Robinhood Chain mainnet and verified on
[robin.etherscan.io](https://robin.etherscan.io).

## Contracts

| Contract | Role |
|---|---|
| `game/ChannelGame.sol` | Channels (ERC-721) and positions: requests, binds, early closes, settlement, royalties. Upgradeable (UUPS). |
| `game/GameEntry.sol`, `GameLogic.sol`, `ClaimLogic.sol`, `GameAdmin.sol` | External libraries of `ChannelGame`: entry checks, settlement math, claims, admin setters. |
| `game/GameState.sol` | `ChannelGame` storage layout (ERC-7201). |
| `vault/Vault.sol` | Custody and accounting of one game currency (OVER, USDG): capital, reserves, payouts. Upgradeable. |
| `assets/AssetRegistry.sol` | Supported assets (Data Streams feeds), their geometry rails, fees, caps and per-currency terms, and the registered pricing model hashes. Upgradeable. |
| `access/AccessRegistry.sol` | Protocol roles (admin, operator, guardian). Upgradeable. |
| `access/Timelock.sol` | Holds the upgrade right of every proxy: an upgrade is announced and executed after the delay. |
| `libs/DataStreamsReports.sol` | Decoding of Chainlink Data Streams reports. |
| `staking/TestersStaking.sol` | OVER staking of the testers' campaign. |
| `airdrop/AirdropVesting.sol` | Genesis airdrop: allocations vested daily over 15 days. |

Comments refer to the protocol's internal design records (`ADR-NNNN`); they are not part of this repository.

## Deployments

Addresses are in [`deployments/`](deployments):

- [`robinhood-mainnet.json`](deployments/robinhood-mainnet.json) — Robinhood Chain (chain id 4663)
- [`robinhood-testnet.json`](deployments/robinhood-testnet.json) — Robinhood Chain Testnet (chain id 46630)

Mainnet entry points:

| | Address |
|---|---|
| ChannelGame | [`0x1C7dDdc2fA9BEc0549FcdeabcfeBD37452d2CDCb`](https://robin.etherscan.io/address/0x1C7dDdc2fA9BEc0549FcdeabcfeBD37452d2CDCb) |
| OVER vault | [`0xFB4C6062c24313E2E8Cf01D1CCBa0B940e7b29f6`](https://robin.etherscan.io/address/0xFB4C6062c24313E2E8Cf01D1CCBa0B940e7b29f6) |
| USDG vault | [`0x526b07940694f599aA2e9DbDE30540BE004aC80e`](https://robin.etherscan.io/address/0x526b07940694f599aA2e9DbDE30540BE004aC80e) |
| AssetRegistry | [`0x91Ed7b91D670433194C9188c15E9ecaecD7Aa984`](https://robin.etherscan.io/address/0x91Ed7b91D670433194C9188c15E9ecaecD7Aa984) |
| AccessRegistry | [`0x420C5C8496E8BcB8c22c0330D92BE5241FB01337`](https://robin.etherscan.io/address/0x420C5C8496E8BcB8c22c0330D92BE5241FB01337) |
| Timelock | [`0x0bCE465A55c8f5c670016B910A50e522e15F6051`](https://robin.etherscan.io/address/0x0bCE465A55c8f5c670016B910A50e522e15F6051) |
| OVER token | [`0x6245Db7f52379bD9757c9DdcE6519768FfaB3a4F`](https://robin.etherscan.io/address/0x6245Db7f52379bD9757c9DdcE6519768FfaB3a4F) |

## Build and test

Requires Node.js 22.18 or newer.

```bash
npm install
npm run build   # solc 0.8.28, via-IR, optimizer 50 runs
npm test        # Solidity tests (*.t.sol)
```

## License

All rights reserved (`SPDX-License-Identifier: UNLICENSED`). The code is published for review and
verification; it may not be used, copied or deployed without permission.
