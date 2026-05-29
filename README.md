# SuperFuckUp

CooldownVault `_claim()` accounting bug. `accClaimedAmount` is incremented by `request.assets` instead of `assetsOut`, inflating the FIFO reservation counter whenever a lossy claim occurs.

Confirmed on Kaia mainnet at block 217860010 against the deployed proxy `0x4E4654cE4Ca7ff0ba66a0A4a588A4bd55A6f9A33`.

- [FINDING.md](./FINDING.md) - root cause, impact, affected code
- [PROOF.md](./PROOF.md) - full reproduction walkthrough
- [docs/accounting_breakdown.md](./docs/accounting_breakdown.md) - state trace and math
- [docs/fix.md](./docs/fix.md) - the fix
- [test/PoC_accClaimedAmount.t.sol](./test/PoC_accClaimedAmount.t.sol) - runnable Foundry test

## Quick run

```
git clone https://github.com/Klaurx/SuperFuckUp
cd SuperFuckUp
forge install foundry-rs/forge-std
export KAIA_RPC_URL=https://public-en.node.kaia.io
forge test --match-test test_accClaimedAmount_inflation \
  --fork-url $KAIA_RPC_URL \
  --fork-block-number 217860010 \
  -vvvv
```

Expected: `[PASS]` with the bug output printed.
