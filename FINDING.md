# CooldownVault: accClaimedAmount Inflated by request.assets Instead of assetsOut

**Contract:** `CooldownVault.sol`
**Function:** `_claim()`
**Severity:** High
**Scope match:** "FIFO claim-reservation bypass in CooldownVault / OriginVault redemption queues"
**Deployed proxy:** `0x4E4654cE4Ca7ff0ba66a0A4a588A4bd55A6f9A33` (Kaia mainnet)
**Block confirmed:** 217860010

---

## The bug

`_claim()` in `CooldownVault.sol` contains this effects block:

```solidity
// src/superearn/core/CooldownVault.sol

request.claimed = true;
totalLockedAssets -= request.assets;
accClaimedAmount += request.assets;   // <-- wrong
totalClaimLoss += request.assets - assetsOut;
```

`accClaimedAmount` is supposed to track how much has actually been paid out to claimants so that the FIFO reservation logic can compute how much liquidity is still reserved for earlier-queue requests. The reservation check runs as follows:

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

`reservedForPriorRequests` is the amount the vault must keep back for every request ahead of the current one in the queue. The only way this number stays correct is if `accClaimedAmount` equals the sum of what was actually transferred out, not what was requested.

When a receiver calls `claim()` with `maxLossBps > maxLossThresholdBps` (which is permitted for the receiver themselves per the guard below), the vault can pay out less than the full requested amount:

```solidity
if (maxLossBps > maxLossThresholdBps && _msgSender() != request.receiver) revert ...
```

In that case `assetsOut < request.assets`. The line `accClaimedAmount += request.assets` inflates the counter by `request.assets - assetsOut`. That inflation is phantom: no real funds moved to cover it. From that point forward, `reservedForPriorRequests` is understated for every subsequent claim in the queue, because the subtraction `_accRedeemRequestedAmount - accClaimedAmount` uses an inflated denominator.

---

## Impact

**1. Later-queue requests drain liquidity that belongs to earlier-queue requests.**

Because `reservedForPriorRequests` is understated, a request at position N can see more `availableLiquidity` than actually exists after honoring positions 1 through N-1. Depending on claim order and amounts, this lets a later request pull funds that should be unreachable until earlier requests settle.

**2. `totalClaimLoss` accumulates phantom debt.**

`totalClaimLoss` records the gap between `request.assets` and `assetsOut`. Governance can call `recoverClaimLoss()` to mint vault shares equal to `totalClaimLoss`:

```solidity
function recoverClaimLoss() external override nonReentrant onlyGovernance returns (uint256 assets) {
    assets = totalClaimLoss;
    _mint(_msgSender(), assets);
    totalClaimLoss = 0;
}
```

After a lossy claim, `totalClaimLoss` contains a real gap that was never funded. Minting shares against it dilutes legitimate depositors and leaves later-queue claimants with less backing per share.

**3. `totalLockedAssets` becomes irreconcilable.**

Requests whose `claimed` flag was never set to `true` still hold their `assets` value in `totalLockedAssets`. Once the vault drains, those entries can never be cleared through the normal claim path because `availableLiquidity` is zero. The accounting is permanently broken without direct governance intervention.

An attacker controlling two receiver addresses can submit one small request at queue position N and one large request at position N+M. 
By lossy-claiming position N+M first with maxLossBps=10000, accClaimedAmount is inflated by the loss delta. This deflates reservedForPriorRequests for the N+M position, making vault liquidity accessible that would otherwise be blocked. If third-party requests occupy positions between N and N+M, those victims absorb the shortage. The attacker's net loss equals the accepted loss on the large claim; the net gain is early access to liquidity that should be reserved for others. Whether this is net-positive depends on queue depth and timing, but the structural ability to drain victim-reserved liquidity is unconditional given authorized access to redeem().

---

## Concrete numbers from the PoC

State going in:
- `_managedAssets` = 65 USDT
- Three requests: alice=50, bob=20, charlie=10
- `accClaimedAmount` = 0

Bob claims req2 (receiver, `maxLossBps=10000`):
- `reservedForPrior` = 50, `availableLiquidity` = 15, `assetsOut` = 15
- `accClaimedAmount += 20` (should be `+= 15`)
- Inflation = 5 USDT phantom

Alice claims req1: gets full 50. Vault drains to 0.

Charlie claims req3: gets 0. Vault is empty.

`totalClaimLoss` = 15 USDT. `recoverClaimLoss()` would mint 15 governance shares backed by nothing.

Charlie's 10 USDT request is permanently unfulfillable with no protocol-level path to resolution.

---

## Precondition

The attacker must be the `receiver` of a redemption request and must be willing to accept a partial payout (loss). This is not a hypothetical: the code explicitly permits receivers to pass any `maxLossBps` up to 10000. The loss is self-inflicted by the attacker but the side-effect poisons shared state for all other claimants in the queue.

---

## Fix

One character change. In `_claim()`, replace:

```solidity
accClaimedAmount += request.assets;
```

with:

```solidity
accClaimedAmount += assetsOut;
```

See [docs/fix.md](./docs/fix.md) for the full reasoning.
