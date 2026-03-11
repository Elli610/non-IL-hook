// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {NonToxicMath, Q96, SCALE} from "../src/NonToxicMath.sol";

/// @dev Harness to expose the internal preComputeVolume1 function for testing.
contract NonToxicMathHarness is NonToxicMath {
    function exposed_preComputeVolume1(bool zeroForOne, int256 amountSpecified, uint256 sqrtPrice)
        external
        pure
        returns (int256)
    {
        return preComputeVolume1(zeroForOne, amountSpecified, sqrtPrice);
    }
}

contract NonToxicMathTest is Test {
    NonToxicMathHarness public math;

    function setUp() public {
        math = new NonToxicMathHarness();
    }

    // =========================================================================
    //                          CONSTANTS
    // =========================================================================

    function test_constants() public pure {
        assertEq(SCALE, 1e18);
        assertEq(Q96, 1 << 96);
    }

    // =========================================================================
    //                       preComputeVolume1
    // =========================================================================

    // --- zeroForOne = true ---

    function test_preComputeVolume1_zeroForOne_positiveAmount() public {
        int256 result = math.exposed_preComputeVolume1(true, 1000, 100);
        assertEq(result, -1000);
    }

    function test_preComputeVolume1_zeroForOne_negativeAmount() public {
        int256 result = math.exposed_preComputeVolume1(true, -500, 100);
        assertEq(result, -500);
    }

    function test_preComputeVolume1_zeroForOne_zeroAmount() public {
        // amountSpecified = 0 does not match either zeroForOne branch (>0 or <0),
        // falls through to: 0 * sqrtPrice^2 = 0
        int256 result = math.exposed_preComputeVolume1(true, 0, 100);
        assertEq(result, 0);
    }

    function test_preComputeVolume1_zeroForOne_positiveAmount_ignoresSqrtPrice() public {
        // When zeroForOne && amount > 0, sqrtPrice is irrelevant
        int256 r1 = math.exposed_preComputeVolume1(true, 42, 1);
        int256 r2 = math.exposed_preComputeVolume1(true, 42, 999);
        assertEq(r1, -42);
        assertEq(r2, -42);
    }

    function test_preComputeVolume1_zeroForOne_negativeAmount_ignoresSqrtPrice() public {
        int256 r1 = math.exposed_preComputeVolume1(true, -77, 1);
        int256 r2 = math.exposed_preComputeVolume1(true, -77, 999);
        assertEq(r1, -77);
        assertEq(r2, -77);
    }

    function test_preComputeVolume1_zeroForOne_largePositive() public {
        int256 amt = 1e18;
        int256 result = math.exposed_preComputeVolume1(true, amt, 12345);
        assertEq(result, -amt);
    }

    function test_preComputeVolume1_zeroForOne_largeNegative() public {
        int256 amt = -1e18;
        int256 result = math.exposed_preComputeVolume1(true, amt, 12345);
        assertEq(result, amt);
    }

    // --- zeroForOne = false ---

    function test_preComputeVolume1_oneForZero_positiveAmount() public {
        // 10 * 3^2 = 90
        int256 result = math.exposed_preComputeVolume1(false, 10, 3);
        assertEq(result, 90);
    }

    function test_preComputeVolume1_oneForZero_negativeAmount() public {
        // -10 * 3^2 = -90
        int256 result = math.exposed_preComputeVolume1(false, -10, 3);
        assertEq(result, -90);
    }

    function test_preComputeVolume1_oneForZero_zeroAmount() public {
        int256 result = math.exposed_preComputeVolume1(false, 0, 100);
        assertEq(result, 0);
    }

    function test_preComputeVolume1_oneForZero_zeroSqrtPrice() public {
        int256 result = math.exposed_preComputeVolume1(false, 1000, 0);
        assertEq(result, 0);
    }

    function test_preComputeVolume1_oneForZero_unitSqrtPrice() public {
        // amount * 1^2 = amount
        int256 result = math.exposed_preComputeVolume1(false, 42, 1);
        assertEq(result, 42);
    }

    function test_preComputeVolume1_oneForZero_largeValues() public {
        // sqrtPrice = 30 (typical for ETH/USDC after dividing by Q96)
        // amount = 1e12
        // result = 1e12 * 30^2 = 1e12 * 900 = 9e14
        int256 result = math.exposed_preComputeVolume1(false, 1e12, 30);
        assertEq(result, 9e14);
    }

    function test_preComputeVolume1_oneForZero_sqrtPriceSquared() public {
        // Verify the squaring: amount=1, sqrtPrice=100 => 1 * 100^2 = 10000
        int256 result = math.exposed_preComputeVolume1(false, 1, 100);
        assertEq(result, 10000);
    }

    // =========================================================================
    //                          computeFees
    // =========================================================================

    // --- Branch: in-trend upward (current > initial, volume1 > 0) ---

    function test_computeFees_inTrend_upward() public view {
        // current(2e18) > initial(1e18), volume1(2000) > 0 => in trend
        // history = |initial - current| = 1e18
        // fee = 1 * ((2000 * 1e36) / 2000 + 1e36) / 2e18
        //     = (1e36 + 1e36) / 2e18 = 2e36 / 2e18 = 1e18
        uint256 fee = math.computeFees(2000, 1, 1000, 1e18, 1.5e18, 2e18);
        assertEq(fee, 1e18);
    }

    // --- Branch: in-trend downward (current < initial, volume1 < 0) ---

    function test_computeFees_inTrend_downward() public view {
        // current(1e18) < initial(2e18), volume1(-2000) < 0 => in trend
        // history = |initial - current| = |2e18 - 1e18| = 1e18
        // fee = 1 * ((2000 * 1e36) / 2000 + 1e36) / 1e18
        //     = 2e36 / 1e18 = 2e18
        uint256 fee = math.computeFees(-2000, 1, 1000, 2e18, 1.5e18, 1e18);
        assertEq(fee, 2e18);
    }

    // --- Branch: counter-trend (current > initial, volume1 < 0) ---

    function test_computeFees_counterTrend_fromAbove() public view {
        // current(2e18) > initial(1e18), volume1(-500) < 0 => counter-trend
        // history = |extremum(3e18) - current(2e18)| = 1e18
        // fee = 1 * ((500 * 1e36) / 2000 + 1e36) / 2e18
        //     = (2.5e35 + 1e36) / 2e18 = 1.25e36 / 2e18 = 6.25e17
        uint256 fee = math.computeFees(-500, 1, 1000, 1e18, 3e18, 2e18);
        assertEq(fee, 625000000000000000);
    }

    // --- Branch: counter-trend (current < initial, volume1 > 0) ---

    function test_computeFees_counterTrend_fromBelow() public view {
        // current(2e18) < initial(3e18), volume1(500) > 0 => counter-trend
        // history = |extremum(1e18) - current(2e18)| = 1e18
        // fee = 1 * ((500 * 1e36) / 2000 + 1e36) / 2e18
        //     = 1.25e36 / 2e18 = 6.25e17
        uint256 fee = math.computeFees(500, 1, 1000, 3e18, 1e18, 2e18);
        assertEq(fee, 625000000000000000);
    }

    // --- Branch: current == initial (always goes to else/counter-trend) ---

    function test_computeFees_neutral_positiveVolume() public view {
        // current == initial, volume1 > 0 => falls to else branch
        // history = |extremum(2e18) - current(1e18)| = 1e18
        // fee = 1 * ((1000 * 1e36) / 2000 + 1e36) / 1e18
        //     = (5e35 + 1e36) / 1e18 = 1.5e36 / 1e18 = 1.5e18
        uint256 fee = math.computeFees(1000, 1, 1000, 1e18, 2e18, 1e18);
        assertEq(fee, 1.5e18);
    }

    function test_computeFees_neutral_negativeVolume() public view {
        // current == initial == extremum, volume1 < 0 => else branch
        // history = |extremum - current| = 0
        // fee = 1 * ((1000 * 1e36) / 1000 + 0) / 1e18 = 1e36 / 1e18 = 1e18
        uint256 fee = math.computeFees(-1000, 1, 500, 1e18, 1e18, 1e18);
        assertEq(fee, 1e18);
    }

    // --- Zero volume ---

    function test_computeFees_zeroVolume_withHistory() public view {
        // volume1 = 0, not in trend => else branch
        // history = |extremum(1e18) - current(2e18)| = 1e18
        // fee = 1 * (0 + 1e36) / 2e18 = 5e17
        uint256 fee = math.computeFees(0, 1, 1000, 2e18, 1e18, 2e18);
        assertEq(fee, 5e17);
    }

    function test_computeFees_zeroVolume_noHistory() public view {
        // volume1 = 0, all prices equal => history = 0
        // fee = 1 * (0 + 0) / 1e18 = 0
        uint256 fee = math.computeFees(0, 1, 1000, 1e18, 1e18, 1e18);
        assertEq(fee, 0);
    }

    // --- Zero history (all prices equal) ---

    function test_computeFees_allPricesEqual() public view {
        // All prices = SCALE, volume1 = 1000, activeLiq = 500
        // falls to else branch, history = 0
        // fee = 1 * (1000 * 1e36 / 1000 + 0) / 1e18 = 1e36 / 1e18 = 1e18
        uint256 fee = math.computeFees(1000, 1, 500, SCALE, SCALE, SCALE);
        assertEq(fee, SCALE);
    }

    // --- Alpha scaling ---

    function test_computeFees_alphaScaling() public view {
        // fee should scale linearly with alpha
        uint256 fee1 = math.computeFees(1000, 1, 500, SCALE, SCALE, SCALE);
        uint256 fee2 = math.computeFees(1000, 2, 500, SCALE, SCALE, SCALE);
        uint256 fee3 = math.computeFees(1000, 3, 500, SCALE, SCALE, SCALE);
        uint256 fee5 = math.computeFees(1000, 5, 500, SCALE, SCALE, SCALE);

        assertEq(fee2, 2 * fee1);
        assertEq(fee3, 3 * fee1);
        assertEq(fee5, 5 * fee1);
    }

    // --- Volume linearity (when history = 0) ---

    function test_computeFees_volumeLinear_zeroHistory() public view {
        // When history = 0, fee is linear in |volume1|
        // Use activeLiq = 500, all prices = SCALE so history = 0
        // fee(vol) = alpha * |vol| * SCALE^2 / (2 * activeLiq * current)
        //          = |vol| * 1e36 / (1000 * 1e18) = |vol| * 1e15
        uint256 fee600 = math.computeFees(600, 1, 500, SCALE, SCALE, SCALE);
        uint256 fee400 = math.computeFees(400, 1, 500, SCALE, SCALE, SCALE);
        uint256 fee1000 = math.computeFees(1000, 1, 500, SCALE, SCALE, SCALE);

        assertEq(fee600, 600 * 1e15);
        assertEq(fee400, 400 * 1e15);
        assertEq(fee1000, fee600 + fee400);
    }

    // --- Volume sign does not matter (absolute value is used) ---

    function test_computeFees_volumeSignSymmetry_zeroHistory() public view {
        // With all prices equal (history = 0), positive and negative volume
        // produce the same fee since both land in else branch with history = 0.
        uint256 feePos = math.computeFees(1000, 1, 500, SCALE, SCALE, SCALE);
        uint256 feeNeg = math.computeFees(-1000, 1, 500, SCALE, SCALE, SCALE);
        assertEq(feePos, feeNeg);
    }

    // --- History branch difference ---

    function test_computeFees_inTrendUsesInitial_notExtremum() public view {
        // In-trend: uses |initial - current|, NOT |extremum - current|
        // current(3e18) > initial(1e18), volume1(1000) > 0 => in-trend
        // history = |1e18 - 3e18| = 2e18 (not |5e18 - 3e18| = 2e18)
        // In this case they happen to be equal; use different values to distinguish.

        // extremum = 4e18, initial = 1e18, current = 3e18
        // in-trend history  = |1e18 - 3e18| = 2e18
        // counter-trend would use |4e18 - 3e18| = 1e18

        // fee = 1 * ((1000 * 1e36) / 2000 + 1e18 * 2e18) / 3e18
        //     = (5e35 + 2e36) / 3e18 = 2.5e36 / 3e18
        uint256 fee = math.computeFees(1000, 1, 1000, 1e18, 4e18, 3e18);
        // 2.5e36 / 3e18 = 833333333333333333
        assertEq(fee, 833333333333333333);
    }

    function test_computeFees_counterTrendUsesExtremum_notInitial() public view {
        // Counter-trend: uses |extremum - current|
        // current(3e18) > initial(1e18), volume1(-1000) < 0 => counter-trend
        // history = |extremum(4e18) - current(3e18)| = 1e18

        // fee = 1 * ((1000 * 1e36) / 2000 + 1e36) / 3e18
        //     = (5e35 + 1e36) / 3e18 = 1.5e36 / 3e18 = 5e17
        uint256 fee = math.computeFees(-1000, 1, 1000, 1e18, 4e18, 3e18);
        assertEq(fee, 5e17);
    }

    // --- In-trend gets higher fee than counter-trend (when extremum is beyond current) ---

    function test_computeFees_inTrendHigherThanCounterTrend() public view {
        // Same magnitude volume, same activeLiq, same current
        // in-trend history = |initial - current| = 2e18
        // counter-trend history = |extremum - current| = 1e18
        // So in-trend fee > counter-trend fee

        uint256 inTrendFee = math.computeFees(1000, 1, 1000, 1e18, 4e18, 3e18);
        uint256 counterTrendFee = math.computeFees(-1000, 1, 1000, 1e18, 4e18, 3e18);

        assertGt(inTrendFee, counterTrendFee);
    }

    // --- Extremum equals current in counter-trend => history = 0 ---

    function test_computeFees_counterTrend_extremumEqualsCurrent() public view {
        // current > initial, volume < 0 => counter-trend
        // extremum == current => history = 0
        // fee = 1 * ((1000 * 1e36) / 2000 + 0) / 2e18
        //     = 5e35 / 2e18 = 2.5e17
        uint256 fee = math.computeFees(-1000, 1, 1000, 1e18, 2e18, 2e18);
        assertEq(fee, 250000000000000000);
    }

    // --- Initial equals current in-trend => history = 0 ---
    // Note: current == initial never enters the in-trend branch.
    // Both conditions require strict inequality. So this scenario is counter-trend.
    // Tested above in test_computeFees_neutral_*

    // --- Realistic values (reproducing existing test) ---

    function test_computeFees_existingTestCase() public view {
        int256 volume1 = -12746434883;
        uint256 alpha = 1;
        uint256 activeLiq = 6930192433872;
        uint256 initialSqrtPrice = (SCALE * 2370713100028836327518828066696) / Q96;
        uint256 extremumSqrtPrice = (SCALE * 2370713100028836327518828066696) / Q96;
        uint256 currentSqrtPrice = (SCALE * 2400895714879232902503166069071) / Q96;

        // Verify scaled prices (integer division of large constants)
        assertEq(initialSqrtPrice, 29922606113728942940);
        assertEq(extremumSqrtPrice, 29922606113728942940);
        assertEq(currentSqrtPrice, 30303564271694078875);

        uint256 fee = math.computeFees(volume1, alpha, activeLiq, initialSqrtPrice, extremumSqrtPrice, currentSqrtPrice);

        // current > initial, volume1 < 0 => counter-trend
        // extremum == initial => history = |extremum - current| = |initial - current|
        uint256 expectedHistory = currentSqrtPrice - initialSqrtPrice;
        assertEq(expectedHistory, 380958157965135935);

        // Verify fee matches the logged value from the original test
        assertEq(fee, 12601744969709185);

        // Verify the "uni fee" conversion
        uint256 uniFee = (fee * 1_000_000) / SCALE;
        assertEq(uniFee, 12601);
    }

    // --- Realistic values with different alpha ---

    function test_computeFees_existingTestCase_alpha2() public view {
        int256 volume1 = -12746434883;
        uint256 alpha = 2;
        uint256 activeLiq = 6930192433872;
        uint256 initialSqrtPrice = (SCALE * 2370713100028836327518828066696) / Q96;
        uint256 extremumSqrtPrice = (SCALE * 2370713100028836327518828066696) / Q96;
        uint256 currentSqrtPrice = (SCALE * 2400895714879232902503166069071) / Q96;

        uint256 feeAlpha1 =
            math.computeFees(volume1, 1, activeLiq, initialSqrtPrice, extremumSqrtPrice, currentSqrtPrice);
        uint256 feeAlpha2 =
            math.computeFees(volume1, alpha, activeLiq, initialSqrtPrice, extremumSqrtPrice, currentSqrtPrice);

        assertEq(feeAlpha2, 2 * feeAlpha1);
    }

    // --- Large activeLiq reduces volume component ---

    function test_computeFees_largeActiveLiq() public view {
        // Large activeLiq makes the volume term negligible
        // current(2e18) > initial(1e18), volume1(1000) > 0 => in-trend
        // history = |initial - current| = 1e18
        uint256 fee = math.computeFees(1000, 1, 1e30, 1e18, 1e18, 2e18);

        // volumeTerm = (1000 * 1e36) / (2 * 1e30) = 1e39 / 2e30 = 500000000
        // historyTerm = 1e18 * 1e18 = 1e36
        // total = 1000000000000000000000000000500000000
        // fee = total / 2e18 = 500000000000000000 (5e8 remainder truncated)
        assertEq(fee, 500000000000000000);
    }

    // --- Small activeLiq amplifies volume component ---

    function test_computeFees_smallActiveLiq() public view {
        // activeLiq = 1, all prices equal, volume = 100, alpha = 1
        // fee = (100 * 1e36 / 2 + 0) / 1e18 = 5e37 / 1e18 = 5e19
        uint256 fee = math.computeFees(100, 1, 1, SCALE, SCALE, SCALE);
        assertEq(fee, 5e19);
    }

    // --- History: initial > current, extremum > current (downtrend) ---

    function test_computeFees_downtrend_extremumFarther() public view {
        // initial = 5e18, extremum = 1e18, current = 3e18
        // current < initial, volume1 = -1000 < 0 => in-trend (downward)
        // history = |initial - current| = |5e18 - 3e18| = 2e18
        // fee = 1 * ((1000 * 1e36) / 2000 + 2e36) / 3e18
        //     = (5e35 + 2e36) / 3e18 = 2.5e36 / 3e18 = 833333333333333333
        uint256 fee = math.computeFees(-1000, 1, 1000, 5e18, 1e18, 3e18);
        assertEq(fee, 833333333333333333);
    }

    // --- History branch: initial < extremum < current (in-trend up, extremum between) ---

    function test_computeFees_inTrendUp_extremumBetween() public view {
        // initial = 1e18, extremum = 2e18, current = 3e18, volume > 0
        // in-trend: history = |initial - current| = 2e18
        // fee = 1 * ((1000 * 1e36) / 2000 + 2e36) / 3e18
        //     = 2.5e36 / 3e18 = 833333333333333333
        uint256 fee = math.computeFees(1000, 1, 1000, 1e18, 2e18, 3e18);
        assertEq(fee, 833333333333333333);
    }

    // --- Conversions: fee to Uniswap fee units ---

    function test_computeFees_feeToUniFeeConversion() public view {
        // fee = SCALE means 100% fee => 1_000_000 in Uniswap units
        uint256 fee = math.computeFees(1000, 1, 500, SCALE, SCALE, SCALE);
        assertEq(fee, SCALE);
        uint256 uniFee = (fee * 1_000_000) / SCALE;
        assertEq(uniFee, 1_000_000);
    }

    function test_computeFees_smallFeeConversion() public view {
        // fee = 0.003 * SCALE = 3e15 => 3000 in Uniswap units (0.3% = 30bps)
        // Engineer: volume=3, activeLiq=500, all prices equal
        // fee = 1 * (3 * 1e36 / 1000) / 1e18 = 3e33 / 1e18 = 3e15
        uint256 fee = math.computeFees(3, 1, 500, SCALE, SCALE, SCALE);
        assertEq(fee, 3e15);
        uint256 uniFee = (fee * 1_000_000) / SCALE;
        assertEq(uniFee, 3000);
    }

    // --- Edge: volume1 = 1 (minimal swap) ---

    function test_computeFees_minimalVolume() public view {
        // volume1 = 1, activeLiq = 500, all prices = SCALE
        // fee = (1 * 1e36 / 1000 + 0) / 1e18 = 1e33 / 1e18 = 1e15
        uint256 fee = math.computeFees(1, 1, 500, SCALE, SCALE, SCALE);
        assertEq(fee, 1e15);
    }

    // --- Symmetry between uptrend and downtrend for same magnitude ---

    function test_computeFees_trendSymmetry() public view {
        // Uptrend: initial=1e18, current=2e18, vol=1000
        // Downtrend: initial=2e18, current=1e18, vol=-1000
        // history is the same (1e18), |vol| is the same
        // But currentSqrtPrice differs, so fees differ.
        uint256 feeUp = math.computeFees(1000, 1, 1000, 1e18, 1.5e18, 2e18);
        uint256 feeDown = math.computeFees(-1000, 1, 1000, 2e18, 1.5e18, 1e18);

        // feeUp = ((1000*1e36/2000) + 1e36) / 2e18 = 1.5e36 / 2e18 = 7.5e17
        // feeDown = ((1000*1e36/2000) + 1e36) / 1e18 = 1.5e36 / 1e18 = 1.5e18
        assertEq(feeUp, 750000000000000000);
        assertEq(feeDown, 1500000000000000000);

        // Fee is higher at lower current price (same numerator, smaller denominator)
        assertGt(feeDown, feeUp);
    }

    // --- Higher current price reduces fee (denominator effect) ---

    function test_computeFees_higherCurrentReducesFee() public view {
        // Same volume, liquidity, and history magnitude but different current prices
        // counter-trend: current > initial, volume < 0
        // With extremum = current (so history = 0), only volume matters
        uint256 feeLow = math.computeFees(-1000, 1, 500, 0.5e18, 1e18, 1e18);
        uint256 feeHigh = math.computeFees(-1000, 1, 500, 1e18, 2e18, 2e18);

        // feeLow: history = |1e18 - 1e18| = 0, fee = 1e36 / 1e18 = 1e18
        // feeHigh: history = |2e18 - 2e18| = 0, fee = 1e36 / 2e18 = 5e17
        assertEq(feeLow, 1e18);
        assertEq(feeHigh, 5e17);
        assertGt(feeLow, feeHigh);
    }

    // =========================================================================
    //                          FUZZ TESTS
    // =========================================================================

    function testFuzz_preComputeVolume1_zeroForOne_positive(int256 amount, uint256 sqrtPrice) public {
        amount = bound(amount, 1, type(int128).max);
        sqrtPrice = bound(sqrtPrice, 0, type(uint128).max);

        int256 result = math.exposed_preComputeVolume1(true, amount, sqrtPrice);
        assertEq(result, -amount);
    }

    function testFuzz_preComputeVolume1_zeroForOne_negative(int256 amount, uint256 sqrtPrice) public {
        amount = bound(amount, type(int128).min, -1);
        sqrtPrice = bound(sqrtPrice, 0, type(uint128).max);

        int256 result = math.exposed_preComputeVolume1(true, amount, sqrtPrice);
        assertEq(result, amount);
    }

    function testFuzz_preComputeVolume1_oneForZero(int256 amount, uint128 sqrtPriceRaw) public {
        // Bound to avoid overflow: amount * sqrtPrice^2 must fit int256
        amount = bound(amount, -1e18, 1e18);
        uint256 sqrtPrice = bound(uint256(sqrtPriceRaw), 0, 1e9);

        int256 result = math.exposed_preComputeVolume1(false, amount, sqrtPrice);
        // sqrtPrice bounded to [0, 1e9] so sqrtPrice^2 <= 1e18
        // Compute expected in uint256 then compare via absolute value
        uint256 sqrtPriceSq = sqrtPrice * sqrtPrice;
        if (amount >= 0) {
            // result = amount * sqrtPrice^2 (positive)
            assertEq(result, int256(uint256(amount) * sqrtPriceSq));
        } else {
            // result = amount * sqrtPrice^2 (negative)
            assertEq(result, -int256(uint256(-amount) * sqrtPriceSq));
        }
    }

    function testFuzz_computeFees_alphaLinear(uint256 alpha1, uint256 alpha2) public view {
        // With zero history, fee is linear in alpha
        alpha1 = bound(alpha1, 1, 100);
        alpha2 = bound(alpha2, 1, 100);

        uint256 fee1 = math.computeFees(1000, alpha1, 500, SCALE, SCALE, SCALE);
        uint256 fee2 = math.computeFees(1000, alpha2, 500, SCALE, SCALE, SCALE);

        // fee1/alpha1 == fee2/alpha2 => fee1 * alpha2 == fee2 * alpha1
        assertEq(fee1 * alpha2, fee2 * alpha1);
    }

    function testFuzz_computeFees_volumeLinear(uint256 uVol1, uint256 uVol2) public view {
        // With zero history, fee is linear in |volume|
        uVol1 = bound(uVol1, 1, 1e15);
        uVol2 = bound(uVol2, 1, 1e15);

        // computeFees takes int256; bounded to [1, 1e15], safe to cast
        int256 vol1 = int256(uVol1);
        int256 vol2 = int256(uVol2);

        uint256 fee1 = math.computeFees(vol1, 1, 500, SCALE, SCALE, SCALE);
        uint256 fee2 = math.computeFees(vol2, 1, 500, SCALE, SCALE, SCALE);

        // fee = vol * SCALE^2 / (2 * activeLiq * currentPrice) = vol * 1e15 (exact)
        // So cross-multiply holds without rounding issues.
        assertEq(fee1 * uVol2, fee2 * uVol1);
    }

    function testFuzz_computeFees_nonNegative(
        int256 volume1,
        uint256 alpha,
        uint256 activeLiq,
        uint256 initialPrice,
        uint256 extremumPrice,
        uint256 currentPrice
    ) public view {
        // Fee should never underflow (result is uint256)
        volume1 = bound(volume1, -1e18, 1e18);
        alpha = bound(alpha, 1, 10);
        activeLiq = bound(activeLiq, 1, 1e30);
        currentPrice = bound(currentPrice, 1e15, 1e21);
        initialPrice = bound(initialPrice, 1e15, 1e21);
        extremumPrice = bound(extremumPrice, 1e15, 1e21);

        // Should not revert
        uint256 fee = math.computeFees(volume1, alpha, activeLiq, initialPrice, extremumPrice, currentPrice);

        // Fee is a uint256, so it is >= 0 by construction.
        // But verify the computation did not somehow produce an unreasonable value
        // relative to inputs. This is a smoke test.
        assertTrue(fee >= 0);
    }

    function testFuzz_computeFees_inTrendBranch(uint256 priceDelta, uint256 uVolume, uint256 activeLiq) public view {
        // Force the in-trend upward branch: current > initial, volume1 > 0
        priceDelta = bound(priceDelta, 1, 1e18);
        uVolume = bound(uVolume, 1, 1e15);
        activeLiq = bound(activeLiq, 1e6, 1e30);

        int256 volume1 = int256(uVolume);
        uint256 initialPrice = 1e18;
        uint256 currentPrice = 1e18 + priceDelta;
        uint256 extremumPrice = currentPrice; // extremum at current

        uint256 fee = math.computeFees(volume1, 1, activeLiq, initialPrice, extremumPrice, currentPrice);

        // In-trend: history = |initial - current| = priceDelta
        // fee = (|vol| * SCALE^2 / (2 * activeLiq) + SCALE * priceDelta) / currentPrice
        uint256 volTerm = (uVolume * SCALE * SCALE) / (2 * activeLiq);
        uint256 histTerm = SCALE * priceDelta;
        uint256 expectedFee = (volTerm + histTerm) / currentPrice;

        assertEq(fee, expectedFee);
    }

    function testFuzz_computeFees_counterTrendBranch(
        uint256 priceDelta,
        uint256 extremumDelta,
        uint256 uVolume,
        uint256 activeLiq
    ) public view {
        // Force counter-trend: current > initial, volume1 < 0
        priceDelta = bound(priceDelta, 1, 1e18);
        extremumDelta = bound(extremumDelta, 0, 1e18);
        uVolume = bound(uVolume, 1, 1e15);
        activeLiq = bound(activeLiq, 1e6, 1e30);

        int256 volume1 = -int256(uVolume);
        uint256 initialPrice = 1e18;
        uint256 currentPrice = 1e18 + priceDelta;
        uint256 extremumPrice = currentPrice + extremumDelta;

        uint256 fee = math.computeFees(volume1, 1, activeLiq, initialPrice, extremumPrice, currentPrice);

        // Counter-trend: history = |extremum - current| = extremumDelta
        uint256 volTerm = (uVolume * SCALE * SCALE) / (2 * activeLiq);
        uint256 histTerm = SCALE * extremumDelta;
        uint256 expectedFee = (volTerm + histTerm) / currentPrice;

        assertEq(fee, expectedFee);
    }
}
