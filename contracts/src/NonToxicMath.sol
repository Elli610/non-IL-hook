// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// import {console} from "forge-std/Test.sol";

uint256 constant SCALE = 1e18;
uint256 constant Q96 = 0x1000000000000000000000000;

contract NonToxicMath {
    function preComputeVolume1(bool zeroForOne, int256 amountSpecified, uint256 sqrtPrice)
        internal
        pure
        returns (int256 volume1)
    {
        if (zeroForOne && amountSpecified > 0) return -amountSpecified;
        if (zeroForOne && amountSpecified < 0) return amountSpecified;

        // (zeroForOne && amountSpecified < 0) || (!zeroForOne && amountSpecified > 0)
        return amountSpecified * int256(sqrtPrice) ** 2;
    }

    function computeFees(
        int256 volume1,
        uint256 alpha,
        uint256 activeLiq,
        uint256 initialSqrtpriceScaled_,
        uint256 extremumSqrtpriceScaled_,
        uint256 currentSqrtPriceScaled
    ) public pure returns (uint256) {
        // uint256 alpha = 2; // >= 1
        // uint256 activeLiq = 123456789123456789; // todo: handle activeLiq = 0

        // // dernier sqrt price ou on a pu se rebalancer (ie: n ticks contre le rally actuel)
        // uint256 initialSqrtprice_;
        // // extremum du sqrt price depuis dernier sqrt price ou on a pu se rebalancer (ie: n ticks contre le rally actuel) (ie: max sqrt price si prix monte, min sinon)
        // uint256 extremumSqrtprice_;
        // uint256 currentSqrtPrice;

        // tricky: au deploiment cas possible -> extremum > sqrtInit > currentSqrtPrice ou extremum < sqrtInit < currentSqrtPrice

        uint256 sqrtpriceHistoryScaled;
        // Swap  dans la tendance ?
        if (
            (currentSqrtPriceScaled > initialSqrtpriceScaled_ && volume1 > 0)
                || (currentSqrtPriceScaled < initialSqrtpriceScaled_ && volume1 < 0)
        ) {
            sqrtpriceHistoryScaled = initialSqrtpriceScaled_ > currentSqrtPriceScaled
                ? initialSqrtpriceScaled_ - currentSqrtPriceScaled
                : currentSqrtPriceScaled - initialSqrtpriceScaled_;
        } else {
            sqrtpriceHistoryScaled = extremumSqrtpriceScaled_ > currentSqrtPriceScaled
                ? extremumSqrtpriceScaled_ - currentSqrtPriceScaled
                : currentSqrtPriceScaled - extremumSqrtpriceScaled_;
        }

        uint256 volume1Signed = uint256(volume1 > 0 ? volume1 : -volume1);

        // todo: la c'est bizarre, j'ai l'impression que le scaling n'est pas homogene (vu que les sqrtPrice sont aussi scaled)
        uint256 feePercentScaled =
            (alpha * (((volume1Signed * SCALE * SCALE) / (2 * activeLiq)) + (SCALE * sqrtpriceHistoryScaled)))
                / currentSqrtPriceScaled;

        return feePercentScaled;
    }
}
