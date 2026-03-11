// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {NonToxicMath, SCALE, Q96} from "./NonToxicMath.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

uint160 constant HOOK_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
);

struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

contract NonToxicPool is BaseHook, NonToxicMath, ERC20, IUnlockCallback {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeTransferLib for ERC20;

    /// @dev Drawback threshold numerator. A rebalance triggers when
    ///      delta * 1_000_000 > WANTED_DRAWBACK * extremumSqrtPriceScaled,
    ///      i.e. when price has moved ~0.9% from the extremum.
    uint24 public constant WANTED_DRAWBACK = 9_000;

    /// @dev Dead shares burned on first deposit to prevent ERC4626-style inflation attacks.
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;

    IStateView public immutable stateView;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint256 public immutable alpha;
    int24 public immutable wideRangeMultiplier;
    int24 public immutable narrowRangeMultiplier;

    // Pool state
    PoolKey internal storedPoolKey;
    bool public poolInitialized;

    // Price tracking
    uint256 public initialSqrtPriceScaled;
    uint256 public extremumSqrtPriceScaled;
    int24 public extremumTick;

    // Positions (wide = earning range, narrow = limit-order rebalancing range)
    Position public widePosition;
    Position public narrowPosition;

    bytes32 internal constant WIDE_SALT = bytes32(uint256(1));
    bytes32 internal constant NARROW_SALT = bytes32(uint256(2));

    uint8 internal constant ACTION_DEPOSIT = 1;
    uint8 internal constant ACTION_WITHDRAW = 2;

    error MustUseDynamicFee();
    error PoolNotInitialized();
    error ZeroDeposit();
    error ZeroShares();
    error InsufficientShares();
    error OnlyPoolManager();
    error SlippageTooHigh();
    error InvalidConstructorParams();
    error UnknownAction(uint8 action);

    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event Rebalance(int24 wideLower, int24 wideUpper, int24 narrowLower, int24 narrowUpper);

    constructor(
        IPoolManager _poolManager,
        IERC20 _token0,
        IERC20 _token1,
        IStateView _stateView,
        uint256 _alpha,
        int24 _wideRangeMultiplier,
        int24 _narrowRangeMultiplier
    ) BaseHook(_poolManager) ERC20("NonToxic Vault", "ntVLT", 18) {
        if (address(_token0) == address(0) || address(_token1) == address(0)) {
            revert InvalidConstructorParams();
        }
        if (address(_stateView) == address(0)) revert InvalidConstructorParams();
        if (_alpha == 0) revert InvalidConstructorParams();
        if (_wideRangeMultiplier <= 0 || _narrowRangeMultiplier <= 0) revert InvalidConstructorParams();

        alpha = _alpha;
        token0 = _token0;
        token1 = _token1;
        stateView = _stateView;
        wideRangeMultiplier = _wideRangeMultiplier;
        narrowRangeMultiplier = _narrowRangeMultiplier;
    }

    // ===================== HOOK PERMISSIONS =====================

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ===================== HOOK CALLBACKS =====================

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        extremumTick = tick;
        uint256 sqrtPrice = (SCALE * uint256(sqrtPriceX96)) / Q96;
        initialSqrtPriceScaled = sqrtPrice;
        extremumSqrtPriceScaled = sqrtPrice;

        storedPoolKey = key;
        poolInitialized = true;

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        uint256 currentSqrtPriceScaled = (SCALE * uint256(sqrtPriceX96)) / Q96;

        uint256 activeLiq = uint256(stateView.getLiquidity(poolId));
        if (activeLiq == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int256 volume1 = preComputeVolume1(params.zeroForOne, params.amountSpecified, uint256(sqrtPriceX96) / Q96);

        uint256 newPoolFeePercentScaled = computeFees(
            volume1, alpha, activeLiq, initialSqrtPriceScaled, extremumSqrtPriceScaled, currentSqrtPriceScaled
        );

        uint256 newPoolFee = (newPoolFeePercentScaled * 1_000_000) / SCALE;

        poolManager.updateDynamicLPFee(key, uint24(newPoolFee > 1_000_000 ? 1_000_000 : newPoolFee));

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bool isUpTrend = extremumSqrtPriceScaled >= initialSqrtPriceScaled;
        (uint160 sqrtPriceX96, int24 currentTick,,) = stateView.getSlot0(key.toId());
        uint256 currentSqrtPriceScaled = (SCALE * uint256(sqrtPriceX96)) / Q96;

        uint256 delta = currentSqrtPriceScaled > extremumSqrtPriceScaled
            ? currentSqrtPriceScaled - extremumSqrtPriceScaled
            : extremumSqrtPriceScaled - currentSqrtPriceScaled;

        // Drawback check: delta / extremum > WANTED_DRAWBACK / 1_000_000
        // Rewritten as: delta * 1_000_000 > WANTED_DRAWBACK * extremum (no division truncation)
        if (delta * 1_000_000 > uint256(WANTED_DRAWBACK) * extremumSqrtPriceScaled) {
            initialSqrtPriceScaled = extremumSqrtPriceScaled;
            extremumSqrtPriceScaled = currentSqrtPriceScaled;

            if (widePosition.liquidity > 0 || narrowPosition.liquidity > 0) {
                _rebalance();
            }

            return (BaseHook.afterSwap.selector, 0);
        }

        if ((isUpTrend && currentTick > extremumTick) || (!isUpTrend && currentTick < extremumTick)) {
            extremumTick = currentTick;
            extremumSqrtPriceScaled = currentSqrtPriceScaled;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // ===================== VAULT: DEPOSIT & WITHDRAW =====================

    /// @notice Deposit tokens into the vault and receive shares.
    /// @param amount0 Amount of token0 to deposit.
    /// @param amount1 Amount of token1 to deposit.
    /// @param minShares Minimum shares to receive (slippage protection). Pass 0 to skip.
    function deposit(uint256 amount0, uint256 amount1, uint256 minShares) external {
        if (!poolInitialized) revert PoolNotInitialized();
        if (amount0 == 0 && amount1 == 0) revert ZeroDeposit();

        if (amount0 > 0) ERC20(address(token0)).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) ERC20(address(token1)).safeTransferFrom(msg.sender, address(this), amount1);

        bytes memory result = poolManager.unlock(abi.encode(ACTION_DEPOSIT, amount0, amount1));
        uint256 shares = abi.decode(result, (uint256));
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert SlippageTooHigh();

        _mint(msg.sender, shares);
        emit Deposit(msg.sender, amount0, amount1, shares);
    }

    /// @notice Withdraw shares from the vault and receive proportional tokens.
    /// @param shares Number of shares to burn.
    /// @param minAmount0 Minimum token0 to receive (slippage protection). Pass 0 to skip.
    /// @param minAmount1 Minimum token1 to receive (slippage protection). Pass 0 to skip.
    function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1) external {
        if (shares == 0 || shares > balanceOf[msg.sender]) revert InsufficientShares();

        uint256 supply = totalSupply;
        _burn(msg.sender, shares);

        bytes memory result = poolManager.unlock(abi.encode(ACTION_WITHDRAW, shares, supply));
        (uint256 out0, uint256 out1) = abi.decode(result, (uint256, uint256));

        if (out0 < minAmount0 || out1 < minAmount1) revert SlippageTooHigh();

        if (out0 > 0) ERC20(address(token0)).safeTransfer(msg.sender, out0);
        if (out1 > 0) ERC20(address(token1)).safeTransfer(msg.sender, out1);

        emit Withdraw(msg.sender, shares, out0, out1);
    }

    // ===================== UNLOCK CALLBACK =====================

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        uint8 action = abi.decode(data[:32], (uint8));

        if (action == ACTION_DEPOSIT) {
            return _handleDeposit(data);
        } else if (action == ACTION_WITHDRAW) {
            return _handleWithdraw(data);
        }

        revert UnknownAction(action);
    }

    // ===================== INTERNAL: CALLBACK HANDLERS =====================

    function _handleDeposit(bytes calldata data) internal returns (bytes memory) {
        (, uint256 depositAmount0, uint256 depositAmount1) = abi.decode(data, (uint8, uint256, uint256));

        // Remove all existing liquidity so we can compute accurate vault value
        _removeAllLiquidity();

        uint256 totalBal0 = token0.balanceOf(address(this));
        uint256 totalBal1 = token1.balanceOf(address(this));

        uint256 preBal0 = totalBal0 - depositAmount0;
        uint256 preBal1 = totalBal1 - depositAmount1;

        // Compute shares
        uint256 shares;
        uint256 supply = totalSupply;

        if (supply == 0) {
            shares = depositAmount0 + depositAmount1;
            // Dead shares: burn MINIMUM_LIQUIDITY to address(1) to prevent inflation attacks
            if (shares > MINIMUM_LIQUIDITY) {
                _mint(address(1), MINIMUM_LIQUIDITY);
                shares -= MINIMUM_LIQUIDITY;
            }
        } else {
            (uint160 sqrtPriceX96,,,) = stateView.getSlot0(storedPoolKey.toId());
            uint256 preValue = _valueInToken1(preBal0, preBal1, sqrtPriceX96);
            uint256 depositValue = _valueInToken1(depositAmount0, depositAmount1, sqrtPriceX96);
            shares = (depositValue * supply) / preValue;
        }

        // Re-provision all tokens as liquidity
        _provisionLiquidity();

        return abi.encode(shares);
    }

    function _handleWithdraw(bytes calldata data) internal returns (bytes memory) {
        (, uint256 shares, uint256 supply) = abi.decode(data, (uint8, uint256, uint256));

        // Remove all liquidity
        _removeAllLiquidity();

        // Compute proportional amounts
        uint256 totalBal0 = token0.balanceOf(address(this));
        uint256 totalBal1 = token1.balanceOf(address(this));

        uint256 out0 = (totalBal0 * shares) / supply;
        uint256 out1 = (totalBal1 * shares) / supply;

        // Re-provision remaining tokens
        uint256 remaining0 = totalBal0 - out0;
        uint256 remaining1 = totalBal1 - out1;

        if (remaining0 > 0 || remaining1 > 0) {
            _provisionLiquidityWithAmounts(remaining0, remaining1);
        }

        return abi.encode(out0, out1);
    }

    // ===================== INTERNAL: LIQUIDITY MANAGEMENT =====================

    function _removeAllLiquidity() internal {
        int256 netDelta0;
        int256 netDelta1;

        if (widePosition.liquidity > 0) {
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                storedPoolKey,
                ModifyLiquidityParams({
                    tickLower: widePosition.tickLower,
                    tickUpper: widePosition.tickUpper,
                    liquidityDelta: -int256(uint256(widePosition.liquidity)),
                    salt: WIDE_SALT
                }),
                ""
            );
            netDelta0 += callerDelta.amount0();
            netDelta1 += callerDelta.amount1();
            widePosition.liquidity = 0;
        }

        if (narrowPosition.liquidity > 0) {
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                storedPoolKey,
                ModifyLiquidityParams({
                    tickLower: narrowPosition.tickLower,
                    tickUpper: narrowPosition.tickUpper,
                    liquidityDelta: -int256(uint256(narrowPosition.liquidity)),
                    salt: NARROW_SALT
                }),
                ""
            );
            netDelta0 += callerDelta.amount0();
            netDelta1 += callerDelta.amount1();
            narrowPosition.liquidity = 0;
        }

        _settleDelta(storedPoolKey.currency0, netDelta0);
        _settleDelta(storedPoolKey.currency1, netDelta1);
    }

    function _provisionLiquidity() internal {
        _provisionLiquidityWithAmounts(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    function _provisionLiquidityWithAmounts(uint256 bal0, uint256 bal1) internal {
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96, int24 currentTick,,) = stateView.getSlot0(storedPoolKey.toId());
        int24 ts = storedPoolKey.tickSpacing;

        // --- Wide position (80% of tokens) ---
        int24 wideTickLower = _alignTick(currentTick - wideRangeMultiplier * ts, ts);
        int24 wideTickUpper = _alignTick(currentTick + wideRangeMultiplier * ts, ts);
        wideTickLower = wideTickLower < TickMath.minUsableTick(ts) ? TickMath.minUsableTick(ts) : wideTickLower;
        wideTickUpper = wideTickUpper > TickMath.maxUsableTick(ts) ? TickMath.maxUsableTick(ts) : wideTickUpper;

        uint256 wideUsed0;
        uint256 wideUsed1;

        if (wideTickLower < wideTickUpper) {
            uint256 wide0 = (bal0 * 80) / 100;
            uint256 wide1 = (bal1 * 80) / 100;
            uint128 wideLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(wideTickLower),
                TickMath.getSqrtPriceAtTick(wideTickUpper),
                wide0,
                wide1
            );

            if (wideLiq > 0) {
                _addPositionAndSettle(wideTickLower, wideTickUpper, wideLiq, WIDE_SALT);
                widePosition = Position(wideTickLower, wideTickUpper, wideLiq);
                wideUsed0 = wide0 > bal0 ? bal0 : wide0;
                wideUsed1 = wide1 > bal1 ? bal1 : wide1;
            }
        }

        // --- Narrow position (remaining tokens, limit order for rebalancing) ---
        bool isUpTrend = extremumSqrtPriceScaled >= initialSqrtPriceScaled;
        int24 narrowTickLower;
        int24 narrowTickUpper;

        if (isUpTrend) {
            narrowTickLower = _alignTick(currentTick, ts) + ts;
            narrowTickUpper = narrowTickLower + narrowRangeMultiplier * ts;
        } else {
            narrowTickUpper = _alignTick(currentTick, ts);
            narrowTickLower = narrowTickUpper - narrowRangeMultiplier * ts;
        }

        narrowTickLower = narrowTickLower < TickMath.minUsableTick(ts) ? TickMath.minUsableTick(ts) : narrowTickLower;
        narrowTickUpper = narrowTickUpper > TickMath.maxUsableTick(ts) ? TickMath.maxUsableTick(ts) : narrowTickUpper;

        if (narrowTickLower < narrowTickUpper) {
            uint256 rem0 = bal0 > wideUsed0 ? bal0 - wideUsed0 : 0;
            uint256 rem1 = bal1 > wideUsed1 ? bal1 - wideUsed1 : 0;

            if (rem0 > 0 || rem1 > 0) {
                uint128 narrowLiq = LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(narrowTickLower),
                    TickMath.getSqrtPriceAtTick(narrowTickUpper),
                    rem0,
                    rem1
                );

                if (narrowLiq > 0) {
                    _addPositionAndSettle(narrowTickLower, narrowTickUpper, narrowLiq, NARROW_SALT);
                    narrowPosition = Position(narrowTickLower, narrowTickUpper, narrowLiq);
                }
            }
        }
    }

    function _addPositionAndSettle(int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt) internal {
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            storedPoolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: salt
            }),
            ""
        );

        _settleDelta(storedPoolKey.currency0, callerDelta.amount0());
        _settleDelta(storedPoolKey.currency1, callerDelta.amount1());
    }

    function _rebalance() internal {
        _removeAllLiquidity();
        _provisionLiquidity();

        emit Rebalance(
            widePosition.tickLower, widePosition.tickUpper, narrowPosition.tickLower, narrowPosition.tickUpper
        );
    }

    // ===================== INTERNAL: SETTLEMENT =====================

    function _settleDelta(Currency currency, int256 delta) internal {
        if (delta < 0) {
            // Hook owes tokens to pool (adding liquidity)
            uint256 amount = uint256(-delta);
            poolManager.sync(currency);
            ERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        } else if (delta > 0) {
            // Pool owes tokens to hook (removing liquidity)
            poolManager.take(currency, address(this), uint256(delta));
        }
    }

    // ===================== INTERNAL: HELPERS =====================

    function _alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _valueInToken1(uint256 amt0, uint256 amt1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // price_token1_per_token0 = (sqrtPriceX96 / 2^96)^2
        // value = amt0 * price + amt1
        uint256 value0 = (uint256(sqrtPriceX96) * amt0) / Q96;
        value0 = (value0 * uint256(sqrtPriceX96)) / Q96;
        return value0 + amt1;
    }

    function getStoredPoolKey() external view returns (PoolKey memory) {
        return storedPoolKey;
    }
}
