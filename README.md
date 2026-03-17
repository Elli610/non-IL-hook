# Anti-Toxicity Hook for Optimal Onchain Market Making

A novel approach to automated market making on Uniswap V4 that addresses market toxicity through dynamic fees based on instantaneous transaction size and directional persistence.

## Overview

The Anti-Toxicity Hook protects liquidity providers from adverse selection by implementing a sophisticated fee mechanism that responds instantly to toxic order flow without relying on time-dependent volatility measures.

### Key Innovation

Unlike traditional adaptive fee models that adjust based on historical volatility (introducing lag and gaming vulnerabilities), our hook calculates fees **instantaneously** based on:

1. **Current swap size** relative to pool depth
2. **Directional imbalance accumulation** (without time dependency)
3. **Pool's active liquidity** at the moment of execution

This zero-lag approach provides immediate protection against toxic flow while automatically incentivizing rebalancing through asymmetric pricing.

## Mathematical Foundation

### The Break-Even Condition

For a market maker to be profitable without rebalancing, the fee earned must exceed the gamma loss (impermanent loss). Our analysis shows:

$$\left|\frac{\Delta P}{P}\right| < \frac{\text{tickSpacing}}{10^4}$$

**Critical Insight:** If a transaction creates slippage ≥ 1 tick spacing, the market maker loses money on that transaction (fees earned < gamma loss).

### Toxicity Measurement

Market toxicity quantifies persistent directional volatility that causes LP losses. After applying a fusion rule to isolate truly toxic directional runs:

$$\text{Toxicity} = \frac{1}{N_{\text{runs}}} \sum_{i=1}^{N_{\text{runs}}} \frac{\ln\left(\frac{\text{sqrtPrice} + \Delta\text{sqrtPrice}_i}{\text{sqrtPrice}}\right)}{f}$$

An LP position is profitable when:

$$\frac{\text{Toxicity}}{\text{fullRangeAPR}} < 1$$

### Complete Fee Formula

$$\mathrm{fee\%} = \frac{\alpha}{\mathrm{currentSqrtPrice}} \times \left[\frac{\mathrm{swapVolume1}}{2 \times \mathrm{activeLiquidity}} + \mathrm{sqrtPriceHistorique}(\beta)\right]$$

**where:**
- **α** (alpha) = toxicity filter strength (typically 2)
- **β** (beta) = reversal threshold ≈ 1.5 × tickSpacing
- **Term 1**: Immediate market impact of current swap
- **Term 2**: Accumulated directional imbalance from recent history

## Performance Analysis

### Real-World Backtesting Results

The following charts demonstrate the hook's performance using real onchain data from the [Uniswap V3 WETH/USDC (fee: 500)](https://arbiscan.io/address/0xc6962004f452be9203591991d15f6b388e09e8d0) pool on Arbitrum One.

**Backtest Details:**
- **Data source**: Arbitrum One blocks 401,412,426 to 403,076,967 (130,931 rows)
- **Simplification**: Only `deltaSqrtPrice` between block start and end is used. When multiple swaps occur within a single block, they are treated as one consolidated swap.
- **Fee impact**: This simplification means the fees generated in the backtest are **lower than what would actually occur** in production (where each swap would be charged separately), but results remain close enough to reality for meaningful analysis.
- **Volume considerations**: The backtest emulates the hook over swaps that occurred on a pool with fixed fees. In actual deployment with variable fees, trading volumes would differ—lower fees would attract more volume, while higher fees would reduce volume during toxic periods.
- **Gas costs**: Transaction gas costs have not been included in the P&L calculations.
- **Purpose**: These simplifications are acceptable for hackathon demonstration purposes and provide valid directional insights into the hook's effectiveness.

#### Bid/Ask Spread Dynamics

<img width="1236" height="660" alt="image" src="https://github.com/user-attachments/assets/966e2c8a-ba60-4ae4-9570-ae7a8c9c467c" />

This chart shows how the variable fee mechanism creates dynamic bid/ask spreads that adapt to market conditions:
- **Blue line**: Actual price movement
- **Red lines**: Fixed fee bid/ask (constant spread shown in gray)
- **Dashed lines**: Variable fee bid/ask (adaptive spreads)

Key observations:
- During stable periods (blocks 0-200, 400-750), variable spreads remain tight and competitive
- During toxic periods (blocks 250-400, 800-950), the ask spread widens significantly to protect LPs from adverse selection
- The system responds instantaneously to market state changes

#### Fee Rate Evolution

<img width="1236" height="666" alt="image" src="https://github.com/user-attachments/assets/ae57b77f-913f-419b-b79e-918a223d74b2" />

This chart illustrates how variable fees adapt to market toxicity:
- **Blue line**: Fixed fee baseline (0.05%)
- **Green dashed line**: Ask fee (variable) for buying pressure
- **Orange dashed line**: Bid fee (variable) for selling pressure

Key observations:
- Fees spike during toxic flow periods (blocks 250-400, 800-950)
- Asymmetric pricing: higher fees for toxic direction, lower for rebalancing
- Automatic return to baseline during balanced market conditions

#### Cumulative Profitability

<img width="1236" height="670" alt="image" src="https://github.com/user-attachments/assets/203ab513-3bd7-4217-b717-f6f208040a3b" />

This chart demonstrates the economic impact across different strategies:
- **Blue line**: Fixed fee P&L (barely profitable, ~0.2%)
- **Orange line**: Variable fee P&L (strongly profitable, ~4.3%)
- **Black dashed line**: Holding value baseline (break-even)
- **Purple dashed line**: Variable fee expected P&L adjusted for volume changes

Key results:
- **Variable fees**: +4.3% profit over the period
- **Fixed fees**: +0.2% profit (effectively break-even)
- **Improvement**: ~20x better performance with variable fees
- The purple line shows conservative expected returns accounting for potential volume reduction from higher fees

### Why This Matters

These results demonstrate that the Anti-Toxicity Hook:

1. **Protects LPs**: Transforms structurally unprofitable toxic flow into profitable outcomes
2. **Maintains efficiency**: Keeps fees low during balanced market conditions
3. **Self-regulates**: Automatically adapts without parameter tuning or governance
4. **Real-world validated**: Performance confirmed using actual onchain data

## Parameters

### Alpha (α): Toxicity Filter Strength

Controls how aggressively the hook filters toxic flow:

- **α = 1**: Minimal filtering (conservative)
- **α = 2**: Moderate filtering (**recommended for production**)
- **α = 3**: Aggressive filtering (volatile pairs)
- **α = 5**: Very aggressive (high toxicity environments)

### Beta (β): Rebalancing Filter

Determines what constitutes a "true" directional reversal:

- Must satisfy: **β > tickSpacing**
- **Optimal: β ≈ 1.5 × tickSpacing**

This ensures only meaningful market reversals reset the directional tracking.

## Key Properties

1. **Anti-fragmentation**: Splitting a swap yields identical total fees
2. **Zero time dependency**: No lag, immediate response to market state
3. **Directional penalty**: Penalizes swaps continuing toxic trends
4. **Automatic rebalancing incentive**: Counter-directional swaps pay less
5. **Non-predictable**: Cannot game historical data accumulation
6. **Manipulation-resistant**: State-based rather than pattern-based

## Installation

```bash
# Install dependencies
forge install

# Run the demo script
forge script script/DeployNonToxicPool.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --via-ir \
  -vvv \
  --tc DeployNonToxicPool \
  --private-key $PRIVATE_KEY \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## License

GNU Affero General Public License v3.0 License - see [LICENSE](./LICENSE.md) file for details.

## Contact

- Email: nathan@lobster-protocol.com

## Acknowledgments

Built on [Uniswap V4](https://github.com/Uniswap/v4-core) - special thanks to the Uniswap team for creating an extensible AMM architecture.

---

**Disclaimer**: This software is provided as-is for research and educational purposes. Always conduct thorough testing and auditing before deploying to mainnet.
