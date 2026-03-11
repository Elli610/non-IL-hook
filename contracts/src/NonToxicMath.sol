// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

uint256 constant SCALE = 1e18;
uint256 constant Q96 = 0x1000000000000000000000000;

contract NonToxicMath {
    /// @notice Estimates the swap volume denominated in token1 terms.
    /// @dev For zeroForOne swaps (selling token0), the volume is returned as-is since amountSpecified
    ///      is already in token0/token1 units depending on exact-input vs exact-output.
    ///      For oneForZero swaps (!zeroForOne), the amount is scaled by sqrtPrice^2 to approximate
    ///      the token1-equivalent volume.
    ///      The sign convention is: negative = downward price pressure, positive = upward.
    /// @param zeroForOne True if swapping token0 for token1.
    /// @param amountSpecified The swap amount (negative = exact input, positive = exact output).
    /// @param sqrtPrice The integer-truncated sqrt price (sqrtPriceX96 / Q96). Coarse but overflow-safe.
    /// @return volume1 The estimated volume in token1-equivalent terms.
    function preComputeVolume1(bool zeroForOne, int256 amountSpecified, uint256 sqrtPrice)
        internal
        pure
        returns (int256 volume1)
    {
        if (zeroForOne && amountSpecified > 0) return -amountSpecified;
        if (zeroForOne && amountSpecified < 0) return amountSpecified;

        // !zeroForOne (or zeroForOne with zero amount): scale by price = sqrtPrice^2
        return amountSpecified * int256(sqrtPrice) ** 2;
    }

    /// @notice Computes a dynamic fee percentage based on swap volume, liquidity, and price history.
    /// @dev The fee has two components:
    ///      1. Volume impact: larger swaps relative to liquidity pay higher fees.
    ///      2. Price history: swaps in the trend direction (toxic flow) pay higher fees than
    ///         counter-trend swaps (arbitrage / mean-reversion).
    ///      The result is a SCALE-denominated fee percentage (1e18 = 100%).
    /// @param volume1 Estimated volume in token1 terms (from preComputeVolume1).
    /// @param alpha Fee multiplier (>= 1). Higher alpha = higher fees.
    /// @param activeLiq Current active liquidity in the pool. Must be > 0.
    /// @param initialSqrtpriceScaled_ Sqrt price at last rebalance (SCALE-denominated).
    /// @param extremumSqrtpriceScaled_ Most extreme sqrt price since last rebalance (SCALE-denominated).
    /// @param currentSqrtPriceScaled Current sqrt price (SCALE-denominated). Must be > 0.
    /// @return feePercentScaled The fee as a fraction of SCALE (e.g., 3e15 = 0.3%).
    function computeFees(
        int256 volume1,
        uint256 alpha,
        uint256 activeLiq,
        uint256 initialSqrtpriceScaled_,
        uint256 extremumSqrtpriceScaled_,
        uint256 currentSqrtPriceScaled
    ) public pure returns (uint256) {
        uint256 sqrtpriceHistoryScaled;

        // Determine if this swap follows the current price trend (toxic) or opposes it.
        // In-trend swaps use |initial - current| as the history measure (larger = more toxic).
        // Counter-trend swaps use |extremum - current| (smaller = less toxic).
        if (
            (currentSqrtPriceScaled > initialSqrtpriceScaled_ && volume1 > 0)
                || (currentSqrtPriceScaled < initialSqrtpriceScaled_ && volume1 < 0)
        ) {
            // In-trend: swap pushes price further from initial
            sqrtpriceHistoryScaled = initialSqrtpriceScaled_ > currentSqrtPriceScaled
                ? initialSqrtpriceScaled_ - currentSqrtPriceScaled
                : currentSqrtPriceScaled - initialSqrtpriceScaled_;
        } else {
            // Counter-trend: swap pushes price back toward initial (or neutral/zero volume)
            sqrtpriceHistoryScaled = extremumSqrtpriceScaled_ > currentSqrtPriceScaled
                ? extremumSqrtpriceScaled_ - currentSqrtPriceScaled
                : currentSqrtPriceScaled - extremumSqrtpriceScaled_;
        }

        uint256 absVolume1 = uint256(volume1 > 0 ? volume1 : -volume1);

        // fee = alpha * (volumeImpact + historyPremium) / currentPrice
        // where volumeImpact = |volume1| * SCALE^2 / (2 * activeLiq)
        //       historyPremium = SCALE * sqrtpriceHistoryScaled
        uint256 feePercentScaled =
            (alpha * (((absVolume1 * SCALE * SCALE) / (2 * activeLiq)) + (SCALE * sqrtpriceHistoryScaled)))
                / currentSqrtPriceScaled;

        return feePercentScaled;
    }
}
