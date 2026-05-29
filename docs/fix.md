# Fix this stupid shit

## Location

`src/superearn/core/CooldownVault.sol`, function `_claim()`, effects block.

## Current code

```solidity
// Effects
request.claimed = true;
totalLockedAssets -= request.assets;
accClaimedAmount += request.assets;       // wrong
totalClaimLoss += request.assets - assetsOut;
```

## Fixed code

```solidity
// Effects
request.claimed = true;
totalLockedAssets -= request.assets;
accClaimedAmount += assetsOut;            // correct
totalClaimLoss += request.assets - assetsOut;
```

## Why this is the right fix

`accClaimedAmount` is used in exactly one place: the FIFO reservation check at the top of `_claim()`.

```solidity
uint256 reservedForPriorRequests =
    _accRedeemRequestedAmount > accClaimedAmount
        ? _accRedeemRequestedAmount - accClaimedAmount
        : 0;
```

The purpose of this subtraction is to remove from `_accRedeemRequestedAmount` the portion of prior requests that have already been settled. A request is settled when its funds have actually left the vault. The amount that left the vault is `assetsOut`, not `request.assets`.

`totalLockedAssets` is correctly decremented by `request.assets` because it tracks the total shares locked across all pending requests regardless of whether they were fully or partially paid. That is a different counter serving a different purpose.

`totalClaimLoss` correctly tracks the gap `request.assets - assetsOut`. The fix does not touch it.

After the fix, the invariant holds:

```
accClaimedAmount == sum(assetsOut) for all completed claims
```

And the FIFO reservation correctly reflects the true outstanding debt to earlier claimants.

## What the fix does NOT change

- Full claims (where `assetsOut == request.assets`) are unaffected: `+= assetsOut` and `+= request.assets` produce the same result.
- `totalClaimLoss` is untouched.
- `totalLockedAssets` is untouched.
- The zero-cooldown auto-claim path in `_initiateRedemption` calls `_claim()` internally -- it is fixed by the same change.
