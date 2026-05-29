# Accounting Breakdown

This document traces exactly how `accClaimedAmount` is supposed to work, why the inflation breaks it, and what the correct invariant is.

## What accClaimedAmount is for

The FIFO reservation check in `_claim()` is:

```solidity
uint256 _accRedeemRequestedAmount = accRedeemRequestedAmount[requestId - 1];

uint256 reservedForPriorRequests =
    _accRedeemRequestedAmount > accClaimedAmount
        ? _accRedeemRequestedAmount - accClaimedAmount
        : 0;

uint256 availableLiquidity =
    _managedAssets > reservedForPriorRequests
        ? _managedAssets - reservedForPriorRequests
        : 0;
```

`accRedeemRequestedAmount[N]` is a running total: the sum of `request.assets` for all requests with ID 1 through N. It is set in `_initiateRedemption`:

```solidity
accRedeemRequestedAmount[requestId] = accRedeemRequestedAmount[requestId - 1] + assets;
```

So `accRedeemRequestedAmount[requestId - 1]` = total assets requested by everyone ahead of the current request in the queue.

`accClaimedAmount` is supposed to be the running total of assets that have actually left the vault to satisfy prior claims. The difference `accRedeemRequestedAmount[requestId-1] - accClaimedAmount` is therefore the amount still owed to prior requests that has not been paid yet.

For the FIFO guarantee to hold, the vault must keep that difference in reserve before paying out the current request.

## The invariant

At any point, the correct invariant is:

```
accClaimedAmount == sum of assetsOut for all completed claims
```

If this holds, then `reservedForPriorRequests` correctly reflects the true outstanding debt to earlier claimants.

## How the bug breaks it

The effects block in `_claim()`:

```solidity
accClaimedAmount += request.assets;
totalClaimLoss += request.assets - assetsOut;
```

`totalClaimLoss` correctly tracks the gap. `accClaimedAmount` does not. After a lossy claim:

```
accClaimedAmount = sum(request.assets for completed claims)
                != sum(assetsOut for completed claims)
```

The difference is exactly `totalClaimLoss`. So:

```
accClaimedAmount = trueClaimedAmount + totalClaimLoss
```

This means `reservedForPriorRequests` is understated by `totalClaimLoss` for every subsequent claim. The vault thinks it has already paid `totalClaimLoss` more than it actually has.

## State trace for the PoC scenario

Initial state:
```
_managedAssets       = 65e6
accClaimedAmount     = 0
totalLockedAssets    = 0
totalClaimLoss       = 0
accRedeemRequestedAmount[0] = 0
```

After three redeem requests (alice=50, bob=20, charlie=10):
```
totalLockedAssets               = 80e6
accRedeemRequestedAmount[1]     = 50e6
accRedeemRequestedAmount[2]     = 70e6
accRedeemRequestedAmount[3]     = 80e6
```

Bob claims req2 (assetsOut=15, request.assets=20):
```
_accRedeemRequestedAmount       = accRedeemRequestedAmount[1] = 50e6
reservedForPriorRequests        = 50e6 - 0 = 50e6
availableLiquidity              = 65e6 - 50e6 = 15e6
assetsOut                       = min(20e6, 15e6) = 15e6

-- effects --
totalLockedAssets    = 80e6 - 20e6 = 60e6
accClaimedAmount     = 0   + 20e6  = 20e6   <-- should be 15e6
totalClaimLoss       = 0   + 5e6   = 5e6
_managedAssets       = 65e6 - 15e6 = 50e6
```

Alice claims req1 (assetsOut=50, request.assets=50):
```
_accRedeemRequestedAmount       = accRedeemRequestedAmount[0] = 0
reservedForPriorRequests        = max(0 - 20e6, 0) = 0
availableLiquidity              = 50e6 - 0 = 50e6
assetsOut                       = min(50e6, 50e6) = 50e6

-- effects --
totalLockedAssets    = 60e6 - 50e6 = 10e6
accClaimedAmount     = 20e6 + 50e6 = 70e6
totalClaimLoss       = 5e6  + 0    = 5e6
_managedAssets       = 50e6 - 50e6 = 0
```

Charlie claims req3 (assetsOut=0, request.assets=10):
```
_accRedeemRequestedAmount       = accRedeemRequestedAmount[2] = 70e6
reservedForPriorRequests        = max(70e6 - 70e6, 0) = 0
availableLiquidity              = max(0 - 0, 0) = 0
assetsOut                       = 0

-- effects --
totalLockedAssets    = 10e6 - 10e6 = 0
accClaimedAmount     = 70e6 + 10e6 = 80e6
totalClaimLoss       = 5e6  + 10e6 = 15e6
_managedAssets       = 0
```

Final state:
```
_managedAssets    = 0
accClaimedAmount  = 80e6
totalClaimLoss    = 15e6
totalLockedAssets = 0
```

Total paid out: 15 (bob) + 50 (alice) + 0 (charlie) = 65 USDT.
Total requested: 80 USDT.
Gap: 15 USDT, which `recoverClaimLoss()` can mint as governance shares backed by zero assets.

## What would have happened with the fix

If `accClaimedAmount += assetsOut` was used:

After Bob's claim: `accClaimedAmount` = 15e6 (not 20e6).

When Alice claims req1:
```
reservedForPriorRequests = max(0 - 15e6, 0) = 0
```
Same result for alice -- she still gets 50.

When Charlie claims req3:
```
_accRedeemRequestedAmount = 70e6
reservedForPriorRequests  = max(70e6 - 65e6, 0) = 5e6
availableLiquidity        = max(0 - 5e6, 0) = 0
assetsOut                 = 0
```
Charlie still gets 0 because the vault is empty. But `totalClaimLoss` would only be 5e6 (bob's real shortfall) not 15e6, and no phantom minting occurs.

The fix does not change who gets paid in this scenario -- the vault was genuinely empty. What it fixes is the accounting integrity: `totalClaimLoss` reflects only real shortfalls, not phantom ones created by the counter mismatch.
