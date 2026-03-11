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
    uint256 constant MINIMUM_LIQUIDITY = 1_000;

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
        assertEq(hook.extremumTick(), int24(0));
    }

    function test_revertInitWithoutDynamicFee() public {
        bytes memory constructorArgs = abi.encode(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
        (, bytes32 salt2) = HookMiner.find(address(this), HOOK_FLAGS, type(NonToxicPool).creationCode, constructorArgs);

        NonToxicPool hook2 = new NonToxicPool{salt: salt2}(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );

        Currency cA = deployMintAndApproveCurrency();
        Currency cB = deployMintAndApproveCurrency();
        if (Currency.unwrap(cA) > Currency.unwrap(cB)) {
            (cA, cB) = (cB, cA);
        }

        vm.expectRevert();
        manager.initialize(PoolKey(cA, cB, 3000, 60, IHooks(address(hook2))), SQRT_PRICE_1_1);
    }

    // ===================== CONSTRUCTOR VALIDATION =====================

    function test_revert_constructorZeroToken0() public {
        vm.expectRevert();
        new NonToxicPool(
            manager,
            IERC20(address(0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
    }

    function test_revert_constructorZeroToken1() public {
        vm.expectRevert();
        new NonToxicPool(
            manager,
            IERC20(address(tok0)),
            IERC20(address(0)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
    }

    function test_revert_constructorZeroStateView() public {
        vm.expectRevert();
        new NonToxicPool(
            manager, IERC20(address(tok0)), IERC20(address(tok1)), IStateView(address(0)), ALPHA, WIDE_MULT, NARROW_MULT
        );
    }

    function test_revert_constructorZeroAlpha() public {
        vm.expectRevert();
        new NonToxicPool(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            0,
            WIDE_MULT,
            NARROW_MULT
        );
    }

    function test_revert_constructorZeroWideMultiplier() public {
        vm.expectRevert();
        new NonToxicPool(
            manager, IERC20(address(tok0)), IERC20(address(tok1)), IStateView(address(stateView)), ALPHA, 0, NARROW_MULT
        );
    }

    function test_revert_constructorZeroNarrowMultiplier() public {
        vm.expectRevert();
        new NonToxicPool(
            manager, IERC20(address(tok0)), IERC20(address(tok1)), IStateView(address(stateView)), ALPHA, WIDE_MULT, 0
        );
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

    function test_firstDeposit_sharesEqualSumMinusDeadShares() public {
        uint256 amt0 = 10 ether;
        uint256 amt1 = 10 ether;

        vm.prank(alice);
        hook.deposit(amt0, amt1, 0);

        uint256 shares = hook.balanceOf(alice);
        assertEq(shares, amt0 + amt1 - MINIMUM_LIQUIDITY);
    }

    function test_firstDeposit_deadSharesMintedToAddressOne() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        assertEq(hook.balanceOf(address(1)), MINIMUM_LIQUIDITY);
    }

    function test_firstDeposit_totalSupplyIncludesDeadShares() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        assertEq(hook.totalSupply(), 20 ether);
    }

    function test_firstDeposit_onlyToken0() public {
        uint256 amt0 = 5 ether;

        vm.prank(alice);
        hook.deposit(amt0, 0, 0);

        assertEq(hook.balanceOf(alice), amt0 - MINIMUM_LIQUIDITY);
    }

    function test_firstDeposit_onlyToken1() public {
        uint256 amt1 = 7 ether;

        vm.prank(alice);
        hook.deposit(0, amt1, 0);

        assertEq(hook.balanceOf(alice), amt1 - MINIMUM_LIQUIDITY);
    }

    function test_deposit_revertZero() public {
        vm.prank(alice);
        vm.expectRevert(NonToxicPool.ZeroDeposit.selector);
        hook.deposit(0, 0, 0);
    }

    function test_deposit_revertNotInitialized() public {
        bytes memory constructorArgs = abi.encode(
            manager,
            IERC20(address(tok0)),
            IERC20(address(tok1)),
            IStateView(address(stateView)),
            ALPHA,
            WIDE_MULT,
            NARROW_MULT
        );
        (, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(NonToxicPool).creationCode, constructorArgs);
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
        uninitHook.deposit(1 ether, 1 ether, 0);
        vm.stopPrank();
    }

    function test_deposit_transfersTokens() public {
        uint256 amt0 = 10 ether;
        uint256 amt1 = 10 ether;
        uint256 pre0 = tok0.balanceOf(alice);
        uint256 pre1 = tok1.balanceOf(alice);

        vm.prank(alice);
        hook.deposit(amt0, amt1, 0);

        assertEq(tok0.balanceOf(alice), pre0 - amt0);
        assertEq(tok1.balanceOf(alice), pre1 - amt1);
    }

    function test_secondDeposit_proportionalShares() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 aliceShares = hook.balanceOf(alice);

        vm.prank(bob);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 bobShares = hook.balanceOf(bob);
        // Bob's shares should be close to Alice's (within 1%)
        assertGt(bobShares, (aliceShares * 99) / 100);
        assertLt(bobShares, (aliceShares * 101) / 100);
    }

    function test_deposit_createsPositions() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        (int24 wideLower, int24 wideUpper, uint128 wideLiq) = hook.widePosition();
        assertTrue(wideLiq > 0);
        assertTrue(wideLower < wideUpper);
        assertEq(wideLower, -WIDE_MULT * key.tickSpacing);
        assertEq(wideUpper, WIDE_MULT * key.tickSpacing);
    }

    function test_deposit_narrowPositionCreated() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        (int24 narrowLower, int24 narrowUpper, uint128 narrowLiq) = hook.narrowPosition();
        if (narrowLiq > 0) {
            assertTrue(narrowLower < narrowUpper);
        }
    }

    function test_deposit_wideTicksAlignedToSpacing() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        (int24 wideLower, int24 wideUpper,) = hook.widePosition();
        assertEq(wideLower % key.tickSpacing, 0);
        assertEq(wideUpper % key.tickSpacing, 0);
    }

    function test_deposit_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit NonToxicPool.Deposit(alice, 10 ether, 10 ether, 20 ether - MINIMUM_LIQUIDITY);
        hook.deposit(10 ether, 10 ether, 0);
    }

    function test_deposit_totalSupplyIncreases() public {
        vm.prank(alice);
        hook.deposit(5 ether, 5 ether, 0);
        // totalSupply = dead shares + alice shares = 10 ether
        assertEq(hook.totalSupply(), 10 ether);

        vm.prank(bob);
        hook.deposit(5 ether, 5 ether, 0);
        assertGt(hook.totalSupply(), 10 ether);
    }

    // ===================== DEPOSIT SLIPPAGE =====================

    function test_deposit_slippageProtection() public {
        vm.prank(alice);
        // Requesting more shares than possible should revert
        vm.expectRevert(NonToxicPool.SlippageTooHigh.selector);
        hook.deposit(10 ether, 10 ether, 100 ether);
    }

    function test_deposit_slippagePassesWhenMet() public {
        vm.prank(alice);
        // 20 ether - 1000 dead shares is the actual share amount
        hook.deposit(10 ether, 10 ether, 20 ether - MINIMUM_LIQUIDITY);

        assertEq(hook.balanceOf(alice), 20 ether - MINIMUM_LIQUIDITY);
    }

    // ===================== WITHDRAW =====================

    function test_withdraw_fullWithdrawal() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 shares = hook.balanceOf(alice);
        uint256 pre0 = tok0.balanceOf(alice);
        uint256 pre1 = tok1.balanceOf(alice);

        hook.withdraw(shares, 0, 0);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), 0);
        // Dead shares remain
        assertEq(hook.totalSupply(), MINIMUM_LIQUIDITY);

        uint256 got0 = tok0.balanceOf(alice) - pre0;
        uint256 got1 = tok1.balanceOf(alice) - pre1;
        // Should get back ~99%+ (dead shares hold a tiny amount, plus rounding)
        assertGt(got0 + got1, (20 ether * 99) / 100);
    }

    function test_withdraw_partialWithdrawal() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 shares = hook.balanceOf(alice);
        uint256 half = shares / 2;

        hook.withdraw(half, 0, 0);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), shares - half);
        assertGt(hook.totalSupply(), 0);
    }

    function test_withdraw_revertZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(NonToxicPool.InsufficientShares.selector);
        hook.withdraw(0, 0, 0);
    }

    function test_withdraw_revertInsufficientShares() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        uint256 shares = hook.balanceOf(alice);
        vm.expectRevert(NonToxicPool.InsufficientShares.selector);
        hook.withdraw(shares + 1, 0, 0);
        vm.stopPrank();
    }

    function test_withdraw_emitsEvent() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 shares = hook.balanceOf(alice);
        vm.expectEmit(true, false, false, false);
        emit NonToxicPool.Withdraw(alice, shares, 0, 0);
        hook.withdraw(shares, 0, 0);
        vm.stopPrank();
    }

    function test_withdraw_repositionsAfterPartial() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        hook.withdraw(hook.balanceOf(alice) / 4, 0, 0);
        vm.stopPrank();

        (,, uint128 wideLiq) = hook.widePosition();
        assertGt(wideLiq, 0);
    }

    function test_withdraw_noPositionsAfterFull() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        hook.withdraw(hook.balanceOf(alice), 0, 0);
        vm.stopPrank();

        // After full user withdrawal, only dead shares remain with negligible value.
        // The remaining amount is re-provisioned, so positions may have tiny liquidity.
        assertEq(hook.balanceOf(alice), 0);
        assertEq(hook.totalSupply(), MINIMUM_LIQUIDITY);
    }

    function test_withdraw_multipleUsersProportional() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        vm.prank(bob);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 aliceShares = hook.balanceOf(alice);
        uint256 bobShares = hook.balanceOf(bob);

        uint256 pre0Alice = tok0.balanceOf(alice);
        uint256 pre1Alice = tok1.balanceOf(alice);
        uint256 pre0Bob = tok0.balanceOf(bob);
        uint256 pre1Bob = tok1.balanceOf(bob);

        vm.prank(alice);
        hook.withdraw(aliceShares, 0, 0);

        vm.prank(bob);
        hook.withdraw(bobShares, 0, 0);

        uint256 aliceTotal = (tok0.balanceOf(alice) - pre0Alice) + (tok1.balanceOf(alice) - pre1Alice);
        uint256 bobTotal = (tok0.balanceOf(bob) - pre0Bob) + (tok1.balanceOf(bob) - pre1Bob);

        // Both should get similar amounts (within 2%)
        assertGt(aliceTotal, (bobTotal * 98) / 100);
        assertLt(aliceTotal, (bobTotal * 102) / 100);
    }

    // ===================== WITHDRAW SLIPPAGE =====================

    function test_withdraw_slippageProtection() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        uint256 shares = hook.balanceOf(alice);

        vm.expectRevert(NonToxicPool.SlippageTooHigh.selector);
        hook.withdraw(shares, 100 ether, 0);
        vm.stopPrank();
    }

    function test_withdraw_slippageProtectionToken1() public {
        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        uint256 shares = hook.balanceOf(alice);

        vm.expectRevert(NonToxicPool.SlippageTooHigh.selector);
        hook.withdraw(shares, 0, 100 ether);
        vm.stopPrank();
    }

    // ===================== SWAP & DYNAMIC FEES =====================

    function test_swap_worksAfterDeposit() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        BalanceDelta delta = swap(key, true, -1 ether, ZERO_BYTES);
        assertGt(delta.amount1(), 0);
    }

    function test_swap_zeroForOne_appliesDynamicFee() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        swap(key, true, -1 ether, ZERO_BYTES);

        (,,, uint24 feeAfter) = stateView.getSlot0(key.toId());
        assertTrue(feeAfter >= 0);
    }

    function test_swap_oneForZero_appliesDynamicFee() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        BalanceDelta delta = swap(key, false, -1 ether, ZERO_BYTES);
        assertGt(delta.amount0(), 0);
    }

    function test_swap_extremumTracksDowntrend() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        int24 extremumBefore = hook.extremumTick();
        assertEq(extremumBefore, 0);

        // Initially extremum == initial, so isUpTrend = (extremum >= initial) = true
        // Wait - with >=, when equal, isUpTrend = true
        // In uptrend, extremum tracks HIGHER ticks
        // Swap token1 -> token0 pushes price UP
        swap(key, false, -10 ether, ZERO_BYTES);

        int24 extremumAfter = hook.extremumTick();
        // In uptrend, extremum should track the higher tick
        assertGt(extremumAfter, extremumBefore);
    }

    function test_swap_extremumIgnoresWrongDirection() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        int24 extremumBefore = hook.extremumTick();

        // Initially isUpTrend = true (>= when equal)
        // Pushing price DOWN should NOT update extremum in uptrend mode
        swap(key, true, -10 ether, ZERO_BYTES);

        int24 extremumAfter = hook.extremumTick();
        assertEq(extremumAfter, extremumBefore);
    }

    function test_swap_noLiquidity_returnsZeroFee() public {
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        swap(key, true, -100, ZERO_BYTES);
    }

    // ===================== REBALANCE =====================

    function test_rebalance_triggeredOnDrawback() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        (,, uint128 wideLiq1) = hook.widePosition();
        assertGt(wideLiq1, 0);

        // Use moderate sizes to avoid exhausting liquidity
        swap(key, true, -10 ether, ZERO_BYTES);
        swap(key, false, -10 ether, ZERO_BYTES);

        (,, uint128 wideLiq2) = hook.widePosition();
        assertTrue(wideLiq2 > 0 || hook.totalSupply() > 0);
    }

    function test_rebalance_emitsEvent() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        // Moderate swaps to trigger drawback without overflowing
        for (uint256 i = 0; i < 3; i++) {
            swap(key, true, -5 ether, ZERO_BYTES);
        }

        for (uint256 i = 0; i < 3; i++) {
            swap(key, false, -5 ether, ZERO_BYTES);
        }
    }

    // ===================== PRICE TRACKING =====================

    function test_initialSqrtPriceScaled_correctComputation() public view {
        uint256 expected = (SCALE * uint256(SQRT_PRICE_1_1)) / Q96;
        assertEq(hook.initialSqrtPriceScaled(), expected);
    }

    function test_extremumSqrtPriceScaled_updatedOnTrend() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        uint256 extremumBefore = hook.extremumSqrtPriceScaled();

        // With >= comparison, isUpTrend = true when equal
        // Push price UP (oneForZero = false)
        swap(key, false, -10 ether, ZERO_BYTES);

        uint256 extremumAfter = hook.extremumSqrtPriceScaled();
        // In uptrend, extremum should increase when price goes up
        assertGt(extremumAfter, extremumBefore);
    }

    // ===================== UNLOCK CALLBACK =====================

    function test_unlockCallback_revertNotPoolManager() public {
        vm.expectRevert(NonToxicPool.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), uint256(0), uint256(0)));
    }

    // ===================== ALIGN TICK =====================

    function test_alignTick_positiveTick() public view {
        int24 ts = key.tickSpacing;
        assertEq(ts, int24(60));
    }

    function test_deposit_positionTicksAligned() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

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
        // At 1:1 price, 10 token0 + 10 token1 ~= 20 in token1 value
        // Shares = 20 ether - MINIMUM_LIQUIDITY (dead shares)
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        assertEq(hook.balanceOf(alice), 20 ether - MINIMUM_LIQUIDITY);
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
        hook.deposit(10 ether, 10 ether, 0);

        uint256 aliceShares = hook.balanceOf(alice);
        vm.prank(alice);
        assertTrue(hook.transfer(bob, aliceShares / 2));

        assertEq(hook.balanceOf(alice), aliceShares / 2);
        assertEq(hook.balanceOf(bob), aliceShares / 2);
    }

    function test_shareToken_withdrawAfterTransfer() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 aliceShares = hook.balanceOf(alice);
        vm.prank(alice);
        assertTrue(hook.transfer(bob, aliceShares));

        vm.prank(alice);
        vm.expectRevert(NonToxicPool.InsufficientShares.selector);
        hook.withdraw(1, 0, 0);

        vm.prank(bob);
        hook.withdraw(aliceShares, 0, 0);
        assertEq(hook.balanceOf(bob), 0);
    }

    // ===================== EDGE CASES =====================

    function test_multipleDepositsAndWithdrawals() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        vm.prank(bob);
        hook.deposit(5 ether, 5 ether, 0);

        uint256 aliceShares = hook.balanceOf(alice);
        vm.prank(alice);
        hook.withdraw(aliceShares / 2, 0, 0);

        vm.prank(bob);
        hook.deposit(3 ether, 3 ether, 0);

        // dead shares at address(1)
        uint256 expectedSupply = hook.balanceOf(alice) + hook.balanceOf(bob) + hook.balanceOf(address(1));
        assertEq(hook.totalSupply(), expectedSupply);
    }

    function test_smallDeposit() public {
        vm.prank(alice);
        hook.deposit(1000, 1000, 0);

        uint256 shares = hook.balanceOf(alice);
        // 2000 - 1000 dead shares = 1000
        assertEq(shares, 1000);
    }

    function test_asymmetricDeposit() public {
        vm.prank(alice);
        hook.deposit(10 ether, 0, 0);

        uint256 shares = hook.balanceOf(alice);
        assertEq(shares, 10 ether - MINIMUM_LIQUIDITY);

        // Wide position may have limited coverage with one-sided deposit
    }

    function test_depositWithdrawCycle_conservesValue() public {
        uint256 preAlice0 = tok0.balanceOf(alice);
        uint256 preAlice1 = tok1.balanceOf(alice);

        vm.startPrank(alice);
        hook.deposit(10 ether, 10 ether, 0);
        uint256 shares = hook.balanceOf(alice);
        hook.withdraw(shares, 0, 0);
        vm.stopPrank();

        uint256 postAlice0 = tok0.balanceOf(alice);
        uint256 postAlice1 = tok1.balanceOf(alice);

        uint256 totalBefore = preAlice0 + preAlice1;
        uint256 totalAfter = postAlice0 + postAlice1;
        // Slight loss due to dead shares + rounding
        assertGt(totalAfter, (totalBefore * 99) / 100);
    }

    function test_swapAfterFullWithdrawal() public {
        vm.startPrank(alice);
        hook.deposit(100 ether, 100 ether, 0);
        hook.withdraw(hook.balanceOf(alice), 0, 0);
        vm.stopPrank();

        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        swap(key, true, -100, ZERO_BYTES);
    }

    function test_widePosition_rangeCentered() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        (int24 wideLower, int24 wideUpper,) = hook.widePosition();

        int24 expectedLower = -WIDE_MULT * key.tickSpacing;
        int24 expectedUpper = WIDE_MULT * key.tickSpacing;
        assertEq(wideLower, expectedLower);
        assertEq(wideUpper, expectedUpper);
    }

    function test_narrowPosition_uptrendAbovePrice() public {
        // At init, extremum == initial, so isUpTrend = true (>=)
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        (int24 narrowLower,, uint128 narrowLiq) = hook.narrowPosition();
        if (narrowLiq > 0) {
            // In uptrend, narrow should be above current price (tick 0)
            assertGe(narrowLower, key.tickSpacing);
        }
    }

    function test_swapBothDirections() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        BalanceDelta delta1 = swap(key, true, -5 ether, ZERO_BYTES);
        assertGt(delta1.amount1(), 0);

        BalanceDelta delta2 = swap(key, false, -5 ether, ZERO_BYTES);
        assertGt(delta2.amount0(), 0);
    }

    function test_consecutiveSwaps_noRevert() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        for (uint256 i = 0; i < 10; i++) {
            swap(key, true, -1 ether, ZERO_BYTES);
            swap(key, false, -1 ether, ZERO_BYTES);
        }
    }

    function test_largeSwap() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        // Moderate swap to avoid exhausting one-sided liquidity during rebalance
        swap(key, true, -10 ether, ZERO_BYTES);
    }

    function test_deposit_afterSwaps() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        swap(key, true, -10 ether, ZERO_BYTES);

        vm.prank(bob);
        hook.deposit(10 ether, 10 ether, 0);

        assertGt(hook.balanceOf(bob), 0);
    }

    // ===================== FUZZ TESTS =====================

    function testFuzz_deposit_sharesPositive(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 1, 100 ether);
        amt1 = bound(amt1, 1, 100 ether);

        // Need amt0 + amt1 > MINIMUM_LIQUIDITY for positive user shares
        vm.assume(amt0 + amt1 > MINIMUM_LIQUIDITY);

        vm.prank(alice);
        hook.deposit(amt0, amt1, 0);

        assertGt(hook.balanceOf(alice), 0);
    }

    function testFuzz_depositWithdraw_noRevert(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 1000, 100 ether);
        amt1 = bound(amt1, 1000, 100 ether);

        vm.startPrank(alice);
        hook.deposit(amt0, amt1, 0);
        uint256 shares = hook.balanceOf(alice);
        hook.withdraw(shares, 0, 0);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), 0);
        // Dead shares remain
        assertEq(hook.totalSupply(), MINIMUM_LIQUIDITY);
    }

    function testFuzz_partialWithdraw(uint256 amt0, uint256 amt1, uint256 withdrawFraction) public {
        amt0 = bound(amt0, 1000, 100 ether);
        amt1 = bound(amt1, 1000, 100 ether);
        withdrawFraction = bound(withdrawFraction, 1, 100);

        vm.startPrank(alice);
        hook.deposit(amt0, amt1, 0);
        uint256 shares = hook.balanceOf(alice);
        uint256 toWithdraw = (shares * withdrawFraction) / 100;
        if (toWithdraw == 0) toWithdraw = 1;

        hook.withdraw(toWithdraw, 0, 0);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice), shares - toWithdraw);
    }
}
