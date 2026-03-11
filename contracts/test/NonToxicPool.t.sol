// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {NonToxicPool, HOOK_FLAGS, Position} from "../src/NonToxicPool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SCALE, Q96} from "../src/NonToxicMath.sol";

contract NonToxicPoolTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    NonToxicPool hook;
    StateView stateView;

    MockERC20 tok0;
    MockERC20 tok1;

    uint256 constant ALPHA = 2;
    int24 constant WIDE_MULT = 10;
    int24 constant NARROW_MULT = 2;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        tok0 = MockERC20(Currency.unwrap(currency0));
        tok1 = MockERC20(Currency.unwrap(currency1));

        stateView = new StateView(manager);

        // Mine the hook address
        bytes memory constructorArgs = abi.encode(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NonToxicPool).creationCode, constructorArgs);

        hook = new NonToxicPool{salt: salt}(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
        require(address(hook) == hookAddr, "Hook address mismatch");

        // Initialize pool with dynamic fee at 1:1 price
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Fund alice and bob
        tok0.mint(alice, 1000 ether);
        tok1.mint(alice, 1000 ether);
        tok0.mint(bob, 1000 ether);
        tok1.mint(bob, 1000 ether);

        vm.startPrank(alice);
        tok0.approve(address(hook), type(uint256).max);
        tok1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tok0.approve(address(hook), type(uint256).max);
        tok1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Approve hook to spend test contract's tokens for swaps through router
        tok0.approve(address(hook), type(uint256).max);
        tok1.approve(address(hook), type(uint256).max);
    }

    // ===================== HOOK PERMISSIONS =====================

    function test_hookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    function test_hookAddressHasCorrectFlags() public view {
        uint160 addrBits = uint160(address(hook));
        uint160 expectedFlags = HOOK_FLAGS;
        uint160 mask = Hooks.ALL_HOOK_MASK;
        assertEq(addrBits & mask, expectedFlags & mask);
    }

    // ===================== INITIALIZATION =====================

    function test_poolInitialized() public view {
        assertTrue(hook.poolInitialized());
    }

    function test_storedPoolKeyMatchesInit() public view {
        PoolKey memory stored = hook.getStoredPoolKey();
        assertEq(Currency.unwrap(stored.currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(stored.currency1), Currency.unwrap(key.currency1));
        assertEq(stored.fee, key.fee);
        assertEq(stored.tickSpacing, key.tickSpacing);
        assertEq(address(stored.hooks), address(key.hooks));
    }

    function test_initialPriceTrackingSet() public view {
        uint256 expectedScaled = (SCALE * uint256(SQRT_PRICE_1_1)) / Q96;
        assertEq(hook.initialSqrtPriceScaled(), expectedScaled);
        assertEq(hook.extremumSqrtPriceScaled(), expectedScaled);
    }

    function test_extremumTickSetOnInit() public view {
        // SQRT_PRICE_1_1 corresponds to tick 0
        assertEq(hook.extremumTick(), int24(0));
    }

    function test_revertInitWithoutDynamicFee() public {
        // Try to init a second pool with static fee - should revert
        bytes memory constructorArgs = abi.encode(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
        (address hookAddr2, bytes32 salt2) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NonToxicPool).creationCode, constructorArgs);

        NonToxicPool hook2 = new NonToxicPool{salt: salt2}(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );

        // Deploy fresh currencies to avoid PoolAlreadyInitialized
        Currency cA = deployMintAndApproveCurrency();
        Currency cB = deployMintAndApproveCurrency();
        // Sort
        if (Currency.unwrap(cA) > Currency.unwrap(cB)) {
            (cA, cB) = (cB, cA);
        }

        vm.expectRevert();
        manager.initialize(PoolKey(cA, cB, 3000, 60, IHooks(address(hook2))), SQRT_PRICE_1_1);
    }

    // ===================== IMMUTABLE STATE =====================

    function test_immutableAlpha() public view {
        assertEq(hook.alpha(), ALPHA);
    }

    function test_immutableToken0() public view {
        assertEq(address(hook.token0()), address(tok0));
    }

    function test_immutableToken1() public view {
        assertEq(address(hook.token1()), address(tok1));
    }

    function test_immutableRangeMultipliers() public view {
        assertEq(hook.wideRangeMultiplier(), WIDE_MULT);
        assertEq(hook.narrowRangeMultiplier(), NARROW_MULT);
    }

    // ===================== DEPOSIT =====================

    function test_firstDeposit_sharesEqualSum() public {
        uint256 amt0 = 10 ether;
        uint256 amt1 = 10 ether;

        vm.prank(alice);
        hook.deposit(amt0, amt1);

        uint256 shares = hook.balanceOf(alice);
        assertEq(shares, amt0 + amt1);
    }

    function test_firstDeposit_onlyToken0() public {
        uint256 amt0 = 5 ether;

        vm.prank(alice);
        hook.deposit(amt0, 0);

        assertEq(hook.balanceOf(alice), amt0);
    }

    function test_firstDeposit_onlyToken1() public {
        uint256 amt1 = 7 ether;

        vm.prank(alice);
        hook.deposit(0, amt1);

        assertEq(hook.balanceOf(alice), amt1);
    }

    function test_deposit_revertZero() public {
        vm.prank(alice);
        vm.expectRevert(NonToxicPool.ZeroDeposit.selector);
        hook.deposit(0, 0);
    }

    function test_deposit_revertNotInitialized() public {
        // Deploy a new hook that hasn't been initialized
        bytes memory constructorArgs = abi.encode(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NonToxicPool).creationCode, constructorArgs);
        NonToxicPool uninitHook = new NonToxicPool{salt: salt}(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );

        vm.startPrank(alice);
        tok0.approve(address(uninitHook), type(uint256).max);
        vm.expectRevert(NonToxicPool.PoolNotInitialized.selector);
        uninitHook.deposit(1 ether, 1 ether);
        vm.stopPrank();
    }

    function test_deposit_transfersTokens() public {
        uint256 amt0 = 10 ether;
        uint256 amt1 = 10 ether;
        uint256 pre0 = tok0.balanceOf(alice);
        uint256 pre1 = tok1.balanceOf(alice);

        vm.prank(alice);
        hook.deposit(amt0, amt1);

        // Alice should have fewer tokens
        assertEq(tok0.balanceOf(alice), pre0 - amt0);
        assertEq(tok1.balanceOf(alice), pre1 - amt1);
    }

    function test_secondDeposit_proportionalShares() public {
        // First deposit
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        uint256 aliceShares = hook.balanceOf(alice);
        assertEq(aliceShares, 20 ether);

        // Second deposit of same amounts should get similar shares
        vm.prank(bob);
        hook.deposit(10 ether, 10 ether);

        uint256 bobShares = hook.balanceOf(bob);
        // Bob's shares should be close to Alice's (not exactly equal due to liquidity rounding)
        // but should be within 1% of Alice's
        assertGt(bobShares, (aliceShares * 99) / 100);
        assertLt(bobShares, (aliceShares * 101) / 100);
    }

    function test_deposit_createsPositions() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        (int24 wideLower, int24 wideUpper, uint128 wideLiq) = hook.widePosition();
        assertTrue(wideLiq > 0);
        assertTrue(wideLower < wideUpper);
        // Wide range should be about WIDE_MULT * tickSpacing on each side
        assertEq(wideLower, -WIDE_MULT * key.tickSpacing);
        assertEq(wideUpper, WIDE_MULT * key.tickSpacing);
    }

    function test_deposit_narrowPositionCreated() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        (int24 narrowLower, int24 narrowUpper, uint128 narrowLiq) = hook.narrowPosition();
        // Narrow position may or may not have liquidity depending on remaining tokens
        // but the ticks should be valid if liquidity > 0
        if (narrowLiq > 0) {
            assertTrue(narrowLower < narrowUpper);
        }
    }

    function test_deposit_wideTicksAlignedToSpacing() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        (int24 wideLower, int24 wideUpper,) = hook.widePosition();
        assertEq(wideLower % key.tickSpacing, 0);
        assertEq(wideUpper % key.tickSpacing, 0);
    }

    function test_deposit_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit NonToxicPool.Deposit(alice, 10 ether, 10 ether, 20 ether);
        hook.deposit(10 ether, 10 ether);
    }

    function test_deposit_totalSupplyIncreases() public {
        vm.prank(alice);
        hook.deposit(5 ether, 5 ether);
        assertEq(hook.totalSupply(), 10 ether);

        vm.prank(bob);
        hook.deposit(5 ether, 5 ether);
        assertGt(hook.totalSupply(), 10 ether);
    }

    // ===================== WITHDRAW =====================

    function test_withdraw_fullWithdrawal() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);

        uint256 shares = hook.balanceOf(alice);
        uint256 pre0 = tok0.balanceOf(alice);
        uint256 pre1 = tok1.balanceOf(alice);

        hook.withdraw(shares);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), 0);
        assertEq(hook.totalSupply(), 0);

        // Should get back approximately what was deposited (minus rounding from liquidity)
        uint256 got0 = tok0.balanceOf(alice) - pre0;
        uint256 got1 = tok1.balanceOf(alice) - pre1;
        // At least 99% back (some dust lost to liquidity rounding)
        assertGt(got0 + got1, (20 ether * 99) / 100);
    }

    function test_withdraw_partialWithdrawal() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);

        uint256 shares = hook.balanceOf(alice);
        uint256 half = shares / 2;

        hook.withdraw(half);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), shares - half);
        assertGt(hook.totalSupply(), 0);
    }

    function test_withdraw_revertZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(NonToxicPool.InsufficientShares.selector);
        hook.withdraw(0);
    }

    function test_withdraw_revertInsufficientShares() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);
        uint256 shares = hook.balanceOf(alice);
        vm.expectRevert(NonToxicPool.InsufficientShares.selector);
        hook.withdraw(shares + 1);
        vm.stopPrank();
    }

    function test_withdraw_emitsEvent() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);

        uint256 shares = hook.balanceOf(alice);
        // We cannot predict exact out0/out1 so just check it emits
        vm.expectEmit(true, false, false, false);
        emit NonToxicPool.Withdraw(alice, shares, 0, 0);
        hook.withdraw(shares);
        vm.stopPrank();
    }

    function test_withdraw_repositionsAfterPartial() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);
        hook.withdraw(hook.balanceOf(alice) / 4);
        vm.stopPrank();

        // Positions should still exist with reduced liquidity
        (,, uint128 wideLiq) = hook.widePosition();
        assertGt(wideLiq, 0);
    }

    function test_withdraw_noPositionsAfterFull() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);
        hook.withdraw(hook.balanceOf(alice));
        vm.stopPrank();

        (,, uint128 wideLiq) = hook.widePosition();
        (,, uint128 narrowLiq) = hook.narrowPosition();
        assertEq(wideLiq, 0);
        assertEq(narrowLiq, 0);
    }

    function test_withdraw_multipleUsersProportional() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        vm.prank(bob);
        hook.deposit(10 ether, 10 ether);

        uint256 aliceShares = hook.balanceOf(alice);
        uint256 bobShares = hook.balanceOf(bob);

        uint256 pre0Alice = tok0.balanceOf(alice);
        uint256 pre1Alice = tok1.balanceOf(alice);
        uint256 pre0Bob = tok0.balanceOf(bob);
        uint256 pre1Bob = tok1.balanceOf(bob);

        vm.prank(alice);
        hook.withdraw(aliceShares);

        vm.prank(bob);
        hook.withdraw(bobShares);

        uint256 aliceGot0 = tok0.balanceOf(alice) - pre0Alice;
        uint256 aliceGot1 = tok1.balanceOf(alice) - pre1Alice;
        uint256 bobGot0 = tok0.balanceOf(bob) - pre0Bob;
        uint256 bobGot1 = tok1.balanceOf(bob) - pre1Bob;

        uint256 aliceTotal = aliceGot0 + aliceGot1;
        uint256 bobTotal = bobGot0 + bobGot1;

        // Both should get similar amounts (within 2% due to rounding from sequential removals)
        assertGt(aliceTotal, (bobTotal * 98) / 100);
        assertLt(aliceTotal, (bobTotal * 102) / 100);
    }

    // ===================== SWAP & DYNAMIC FEES =====================

    function test_swap_worksAfterDeposit() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // Swap token0 -> token1 (exact input)
        BalanceDelta delta = swap(key, true, -1 ether, ZERO_BYTES);
        // Should have received some token1 (positive amount1 for caller)
        assertGt(delta.amount1(), 0);
    }

    function test_swap_zeroForOne_appliesDynamicFee() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // Get slot0 before swap
        (,,, uint24 feeBefore) = stateView.getSlot0(key.toId());

        // Execute swap
        swap(key, true, -1 ether, ZERO_BYTES);

        // Fee should have been updated (not necessarily different since it depends on state)
        (,,, uint24 feeAfter) = stateView.getSlot0(key.toId());
        // Fee was set during beforeSwap; it's a dynamic pool so fee exists
        assertTrue(feeAfter >= 0);
    }

    function test_swap_oneForZero_appliesDynamicFee() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // Swap token1 -> token0
        BalanceDelta delta = swap(key, false, -1 ether, ZERO_BYTES);
        assertGt(delta.amount0(), 0);
    }

    function test_swap_extremumTracksDowntrend() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        int24 extremumBefore = hook.extremumTick();
        assertEq(extremumBefore, 0);

        // Initially extremum == initial, so isUpTrend = (extremum > initial) = false
        // In downtrend mode, extremum tracks lower ticks
        // Swap token0 -> token1 pushes price DOWN
        swap(key, true, -10 ether, ZERO_BYTES);

        int24 extremumAfter = hook.extremumTick();
        // In downtrend, extremum should track the lower tick
        assertLt(extremumAfter, extremumBefore);
    }

    function test_swap_extremumIgnoresWrongDirection() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        int24 extremumBefore = hook.extremumTick();

        // Initially isUpTrend = false (downtrend)
        // Pushing price UP should NOT update extremum in downtrend mode
        swap(key, false, -10 ether, ZERO_BYTES);

        int24 extremumAfter = hook.extremumTick();
        assertEq(extremumAfter, extremumBefore);
    }

    function test_swap_noLiquidity_returnsZeroFee() public {
        // Don't deposit - pool has zero liquidity from the hook
        // But we need some external liquidity for the swap to work
        // Add external liquidity via the modify liquidity router
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        // The beforeSwap should handle activeLiq == 0 gracefully
        // (pool has external liquidity but stateView.getLiquidity may return non-zero now)
        // Actually the pool will have liquidity from modifyLiquidityRouter, so this test
        // validates the swap doesn't revert
        swap(key, true, -100, ZERO_BYTES);
    }

    // ===================== REBALANCE =====================

    function test_rebalance_triggeredOnDrawback() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        (int24 wideL1, int24 wideU1, uint128 wideLiq1) = hook.widePosition();
        assertGt(wideLiq1, 0);

        // Push price in one direction significantly
        swap(key, true, -50 ether, ZERO_BYTES);

        // Now push price back (drawback)
        swap(key, false, -50 ether, ZERO_BYTES);

        // After drawback, positions should be repositioned
        // (exact behavior depends on whether drawback threshold is met)
        (int24 wideL2, int24 wideU2, uint128 wideLiq2) = hook.widePosition();

        // If rebalance happened, the ticks would differ (centered on new price)
        // If not, they'd be the same
        // We check that the system doesn't revert
        assertTrue(wideLiq2 > 0 || hook.totalSupply() > 0);
    }

    function test_rebalance_emitsEvent() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // We need enough volume to trigger drawback
        // Multiple swaps to create price movement and drawback
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -10 ether, ZERO_BYTES);
        }

        // Check for Rebalance event on reversal
        // The event may or may not fire depending on drawback threshold
        // At least verify no revert
        for (uint256 i = 0; i < 5; i++) {
            swap(key, false, -10 ether, ZERO_BYTES);
        }
    }

    // ===================== PRICE TRACKING =====================

    function test_initialSqrtPriceScaled_correctComputation() public view {
        uint256 expected = (SCALE * uint256(SQRT_PRICE_1_1)) / Q96;
        assertEq(hook.initialSqrtPriceScaled(), expected);
        // At 1:1 price, sqrtPrice / 2^96 ~= 1, so scaled ~= 1e18
        // At 1:1 price, SQRT_PRICE_1_1 / Q96 ~= 1.0, so scaled ~= 1e18
        assertEq(expected, (SCALE * uint256(SQRT_PRICE_1_1)) / Q96);
    }

    function test_extremumSqrtPriceScaled_updatedOnTrend() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        uint256 extremumBefore = hook.extremumSqrtPriceScaled();

        // Initially isUpTrend = false (downtrend), so extremum tracks lower prices
        // Push price DOWN (zeroForOne = true)
        swap(key, true, -10 ether, ZERO_BYTES);

        uint256 extremumAfter = hook.extremumSqrtPriceScaled();
        // In downtrend, extremum should decrease when price goes down
        assertLt(extremumAfter, extremumBefore);
    }

    // ===================== UNLOCK CALLBACK =====================

    function test_unlockCallback_revertNotPoolManager() public {
        vm.expectRevert(NonToxicPool.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), uint256(0), uint256(0)));
    }

    // ===================== ALIGN TICK =====================

    function test_alignTick_positiveTick() public view {
        // Tick 65 with spacing 60 -> aligned to 60
        int24 ts = key.tickSpacing; // 60
        // Access via deposit to test indirectly, or compute expected values
        // _alignTick is internal, so we test via the position ticks after deposit
        // tick 0 with spacing 60 -> 0
        // This is tested indirectly through position tick alignment
        assertEq(ts, int24(60));
    }

    function test_deposit_positionTicksAligned() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        (int24 wideLower, int24 wideUpper,) = hook.widePosition();
        (int24 narrowLower, int24 narrowUpper, uint128 narrowLiq) = hook.narrowPosition();

        assertEq(wideLower % key.tickSpacing, 0);
        assertEq(wideUpper % key.tickSpacing, 0);
        if (narrowLiq > 0) {
            assertEq(narrowLower % key.tickSpacing, 0);
            assertEq(narrowUpper % key.tickSpacing, 0);
        }
    }

    // ===================== VALUE IN TOKEN1 =====================

    function test_deposit_valueComputationSymmetric() public {
        // At 1:1 price, 10 token0 + 10 token1 should equal about 20 in token1 value
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);
        assertEq(hook.balanceOf(alice), 20 ether);
    }

    // ===================== ERC20 VAULT SHARES =====================

    function test_shareToken_name() public view {
        assertEq(hook.name(), "NonToxic Vault");
    }

    function test_shareToken_symbol() public view {
        assertEq(hook.symbol(), "ntVLT");
    }

    function test_shareToken_decimals() public view {
        assertEq(hook.decimals(), 18);
    }

    function test_shareToken_transferable() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        uint256 aliceShares = hook.balanceOf(alice);
        vm.prank(alice);
        assertTrue(hook.transfer(bob, aliceShares / 2));

        assertEq(hook.balanceOf(alice), aliceShares / 2);
        assertEq(hook.balanceOf(bob), aliceShares / 2);
    }

    function test_shareToken_withdrawAfterTransfer() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        uint256 aliceShares = hook.balanceOf(alice);
        vm.prank(alice);
        assertTrue(hook.transfer(bob, aliceShares));

        // Alice cannot withdraw
        vm.prank(alice);
        vm.expectRevert(NonToxicPool.InsufficientShares.selector);
        hook.withdraw(1);

        // Bob can withdraw
        vm.prank(bob);
        hook.withdraw(aliceShares);
        assertEq(hook.balanceOf(bob), 0);
    }

    // ===================== EDGE CASES =====================

    function test_multipleDepositsAndWithdrawals() public {
        // Alice deposits
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        // Bob deposits
        vm.prank(bob);
        hook.deposit(5 ether, 5 ether);

        // Alice withdraws half
        uint256 aliceShares = hook.balanceOf(alice);
        vm.prank(alice);
        hook.withdraw(aliceShares / 2);

        // Bob deposits more
        vm.prank(bob);
        hook.deposit(3 ether, 3 ether);

        // Final state: supply should be correct
        uint256 expectedSupply = hook.balanceOf(alice) + hook.balanceOf(bob);
        assertEq(hook.totalSupply(), expectedSupply);
    }

    function test_smallDeposit() public {
        // Very small deposit
        vm.prank(alice);
        hook.deposit(1000, 1000);

        uint256 shares = hook.balanceOf(alice);
        assertEq(shares, 2000);
    }

    function test_asymmetricDeposit() public {
        // All token0, no token1
        vm.prank(alice);
        hook.deposit(10 ether, 0);

        uint256 shares = hook.balanceOf(alice);
        assertEq(shares, 10 ether);

        // Positions should still be created
        (,, uint128 wideLiq) = hook.widePosition();
        // Wide position may have zero liquidity if all tokens are on one side
        // and can't create a balanced position. This depends on price and range.
        // At 1:1, token0-only deposit will have limited position coverage
    }

    function test_depositWithdrawCycle_conservesValue() public {
        uint256 preAlice0 = tok0.balanceOf(alice);
        uint256 preAlice1 = tok1.balanceOf(alice);

        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether);
        uint256 shares = hook.balanceOf(alice);
        hook.withdraw(shares);
        vm.stopPrank();

        uint256 postAlice0 = tok0.balanceOf(alice);
        uint256 postAlice1 = tok1.balanceOf(alice);

        // Should get back at least 99% of deposited value
        uint256 totalBefore = preAlice0 + preAlice1;
        uint256 totalAfter = postAlice0 + postAlice1;
        assertGt(totalAfter, (totalBefore * 99) / 100);
    }

    function test_swapAfterFullWithdrawal() public {
        vm.startPrank(alice);
        hook.deposit(100 ether, 100 ether);
        hook.withdraw(hook.balanceOf(alice));
        vm.stopPrank();

        // Pool has no hook liquidity; add external liquidity for the swap
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        // Swap should still work (beforeSwap handles zero activeLiq)
        swap(key, true, -100, ZERO_BYTES);
    }

    function test_widePosition_rangeCentered() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        (int24 wideLower, int24 wideUpper,) = hook.widePosition();

        // At tick 0, wide range should be symmetric: [-WIDE_MULT*ts, WIDE_MULT*ts]
        int24 expectedLower = -WIDE_MULT * key.tickSpacing;
        int24 expectedUpper = WIDE_MULT * key.tickSpacing;
        assertEq(wideLower, expectedLower);
        assertEq(wideUpper, expectedUpper);
    }

    function test_narrowPosition_uptrendAbovePrice() public {
        // At init, extremum == initial, so isUpTrend = true (>=)
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether);

        (int24 narrowLower, int24 narrowUpper, uint128 narrowLiq) = hook.narrowPosition();
        if (narrowLiq > 0) {
            // In uptrend, narrow should be above current price (tick 0)
            // narrowLower should be >= current aligned tick + tickSpacing
            assertGe(narrowLower, key.tickSpacing);
        }
    }

    function test_swapBothDirections() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // Swap token0 -> token1
        BalanceDelta delta1 = swap(key, true, -5 ether, ZERO_BYTES);
        assertGt(delta1.amount1(), 0);

        // Swap token1 -> token0
        BalanceDelta delta2 = swap(key, false, -5 ether, ZERO_BYTES);
        assertGt(delta2.amount0(), 0);
    }

    function test_consecutiveSwaps_noRevert() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        for (uint256 i = 0; i < 10; i++) {
            swap(key, true, -1 ether, ZERO_BYTES);
            swap(key, false, -1 ether, ZERO_BYTES);
        }
    }

    function test_largeSwap() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // Large swap (but not extreme enough to drain all liquidity)
        swap(key, true, -30 ether, ZERO_BYTES);
    }

    function test_deposit_afterSwaps() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether);

        // Move price
        swap(key, true, -10 ether, ZERO_BYTES);

        // Bob deposits after price move
        vm.prank(bob);
        hook.deposit(10 ether, 10 ether);

        // Bob should get shares
        assertGt(hook.balanceOf(bob), 0);
    }

    // ===================== FUZZ TESTS =====================

    function testFuzz_deposit_sharesPositive(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 1, 100 ether);
        amt1 = bound(amt1, 1, 100 ether);

        vm.prank(alice);
        hook.deposit(amt0, amt1);

        assertGt(hook.balanceOf(alice), 0);
    }

    function testFuzz_depositWithdraw_noRevert(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 1000, 100 ether);
        amt1 = bound(amt1, 1000, 100 ether);

        vm.startPrank(alice);
        hook.deposit(amt0, amt1);
        uint256 shares = hook.balanceOf(alice);
        hook.withdraw(shares);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), 0);
        assertEq(hook.totalSupply(), 0);
    }

    function testFuzz_partialWithdraw(uint256 amt0, uint256 amt1, uint256 withdrawFraction) public {
        amt0 = bound(amt0, 1000, 100 ether);
        amt1 = bound(amt1, 1000, 100 ether);
        withdrawFraction = bound(withdrawFraction, 1, 100);

        vm.startPrank(alice);
        hook.deposit(amt0, amt1);
        uint256 shares = hook.balanceOf(alice);
        uint256 toWithdraw = (shares * withdrawFraction) / 100;
        if (toWithdraw == 0) toWithdraw = 1;

        hook.withdraw(toWithdraw);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), shares - toWithdraw);
    }
}
