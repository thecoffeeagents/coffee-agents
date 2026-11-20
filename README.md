# Coffee Agents (BEANS)

5,555 coffee-bean PFPs on BNB Smart Chain. The first mint is free for Agent ID holders.

Coffee Agents is an ERC-721 collection whose free phase is gated by the official
SPACE ID Agent ID registry (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` on BSC):
`mintFree()` checks Agent ID ownership on-chain — 1 free mint per wallet, for the
first 1,500 mints. After the free quota, a fixed price ladder applies
(0.0005 / 0.001 / 0.002 BNB), max 20 per wallet, inside a 14-day mint window.
Unminted supply can never be created once the window is finalized.

Artwork and metadata live on IPFS and were committed to a provenance hash before
launch. The reveal is permissionless (anyone may call it 48 hours after
finalize), mint proceeds stay locked until the reveal, royalties are 3%
(ERC-2981) to the project treasury, and ownership is renounced as the final step.

## Contract

- `contracts/CoffeeAgents.sol` — the collection contract (Solidity 0.8.24, OpenZeppelin 5).
- `contracts/MockAgentID.sol` — test-only mock of the Agent ID registry, used by the test suite. The deployed contract points at the real registry (above); the mock is never deployed.
- Mainnet: `0xc1fAd916153d1b91d6ba9a2253450A6eB2f48245` (Sourcify exact_match)
- Testnet rehearsal (BSC Testnet, Sourcify exact_match): `0x98cA865c1d7d69209160906aD5b0E4153E08BCAf`

## Build & test

```bash
npm install
npx hardhat test
```

The test suite (9 tests) covers the free-mint Agent ID gate, the price ladder
(including quotes that straddle two tiers), the per-wallet cap, finalize/reveal
timing, the proceeds lock until reveal, and a full lifecycle run.

## License

MIT — see `LICENSE`.
