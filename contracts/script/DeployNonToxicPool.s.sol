// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {NonToxicPool, HOOK_FLAGS} from "../src/NonToxicPool.sol";
import {MockERC20} from "../test/MockERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Helper contract for CREATE2 deployment
contract Create2Factory {
    event Deployed(address addr, bytes32 salt);

    function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        emit Deployed(addr, salt);
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}

contract DeployNonToxicPool is Script {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IStateView public stateView;
    IPermit2 public permit2;
    PoolSwapTest public swapRouter;
    NonToxicPool public hook;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public poolKey;
    Create2Factory public factory;

    // Deployment parameters
    uint256 public constant ALPHA = 1; // Fee multiplier
    uint160 public constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // Roughly 1:1 price

    // Liquidity parameters
    uint256 public constant LIQUIDITY_AMOUNT = 1000 ether; // Amount of each token to provide
    int24 public constant TICK_RANGE = 600; // Range around current tick (10 ticks * 60 tickSpacing)

    // Swap parameters
    uint256 public constant SWAP_AMOUNT = 10 ether; // Amount to swap

    // ═══════════════════════════════════════════════════════════════════════
    // LOGGING HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function logHeader(string memory title) internal pure {
        console.log("");
        console.log("=======================================================================");
        console.log(string.concat("  ", title));
        console.log("=======================================================================");
    }

    function logSection(string memory title) internal pure {
        console.log("");
        console.log(string.concat("----- ", title, " -----"));
    }

    function logSuccess(string memory message) internal pure {
        console.log(string.concat("[OK] ", message));
    }

    function logInfo(string memory label, string memory value) internal pure {
        console.log(string.concat("  * ", label, ": ", value));
    }

    function logInfo(string memory label, address value) internal pure {
        console.log(string.concat("  * ", label, ":"));
        console.log(string.concat("    ", vm.toString(value)));
    }

    function logInfo(string memory label, uint256 value) internal pure {
        console.log(string.concat("  * ", label, ": ", vm.toString(value)));
    }

    function logInfo(string memory label, int24 value) internal pure {
        console.log(string.concat("  * ", label, ": ", vm.toString(int256(value))));
    }

    function logBytes32(string memory label, bytes32 value) internal pure {
        console.log(string.concat("  * ", label, ":"));
        console.log(string.concat("    0x", vm.toString(value)));
    }

    function logProgress(string memory message, uint256 current, uint256 total) internal pure {
        console.log(string.concat("[...] ", message, " (", vm.toString(current), "/", vm.toString(total), ")"));
    }

    function logWarning(string memory message) internal pure {
        console.log(string.concat("[WARN] ", message));
    }

    function logDivider() internal pure {
        console.log("-----------------------------------------------------------------------");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        logHeader("NONTOXIC POOL DEPLOYMENT");

        logSection("Deployer Configuration");
        logInfo("Address", deployer);
        logInfo("Balance", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the CREATE2 factory first
        logSection("Deploying CREATE2 Factory");
        factory = new Create2Factory();
        logSuccess("Create2Factory deployed");
        logInfo("Address", address(factory));

        // Set up mainnet contract addresses
        logSection("Connecting to Protocol Contracts");
        poolManager = IPoolManager(
            address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) // Sepolia PoolManager
        );

        positionManager = IPositionManager(
            address(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4) // Sepolia PositionManager
        );

        stateView = IStateView(address(0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C));

        permit2 = IPermit2(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

        swapRouter = new PoolSwapTest(poolManager);

        logSuccess("Connected to protocol contracts");
        logInfo("PoolManager", address(poolManager));
        logInfo("PositionManager", address(positionManager));
        logInfo("StateView", address(stateView));
        logInfo("Permit2", address(permit2));
        logInfo("SwapRouter", address(swapRouter));

        // Deploy mock tokens
        logSection("Deploying Mock Tokens");
        MockERC20 tokenA = new MockERC20("tokenA", "TA");
        MockERC20 tokenB = new MockERC20("tokenB", "TB");

        logSuccess("Mock tokens deployed");
        logInfo("TokenA", address(tokenA));
        logInfo("TokenB", address(tokenB));

        // Sort tokens - currency0 must be < currency1
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        logSection("Token Sorting");
        logInfo("Token0 (lower address)", address(token0));
        logInfo("Token1 (higher address)", address(token1));

        // Get the bytecode for the hook
        logSection("Preparing Hook Deployment");
        bytes memory hookBytecode = abi.encodePacked(
            type(NonToxicPool).creationCode, abi.encode(positionManager, poolManager, token0, token1, stateView, ALPHA)
        );

        bytes32 bytecodeHash = keccak256(hookBytecode);
        logBytes32("Bytecode Hash", bytecodeHash);
        logInfo("Target Hook Flags", HOOK_FLAGS);

        // Mine for the correct salt
        console.log("");
        console.log("[MINING] Searching for valid salt...");
        bytes32 salt = mineSalt(address(factory), hookBytecode);
        logSuccess("Valid salt found!");
        logBytes32("Salt", salt);

        // Deploy the hook using CREATE2
        logSection("Deploying NonToxicPool Hook");
        address hookAddress = factory.deploy(hookBytecode, salt);
        hook = NonToxicPool(hookAddress);

        logSuccess("NonToxicPool hook deployed");
        logInfo("Address", address(hook));
        logInfo("Alpha parameter", hook.alpha());

        // Verify the hook address has the correct flags
        uint160 hookAddressInt = uint160(address(hook));
        uint160 actualFlags = hookAddressInt & Hooks.ALL_HOOK_MASK;

        logSection("Hook Verification");
        logInfo("Expected Flags", HOOK_FLAGS);
        logInfo("Actual Flags", actualFlags);

        require(actualFlags == HOOK_FLAGS, "Hook address does not have required flags");
        logSuccess("Hook flags verified successfully");

        // Set up dynamic fee (0x800000 is the dynamic fee flag)
        uint24 dynamicFee = 0x800000;

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: dynamicFee,
            tickSpacing: int24(60), // Standard tick spacing for dynamic fee pools
            hooks: hook
        });

        logSection("Initializing Pool");
        logInfo("Currency0", Currency.unwrap(poolKey.currency0));
        logInfo("Currency1", Currency.unwrap(poolKey.currency1));
        logInfo("Fee (Dynamic)", poolKey.fee);
        logInfo("Tick Spacing", poolKey.tickSpacing);
        logInfo("Initial Sqrt Price", INITIAL_SQRT_PRICE);

        // Initialize the pool
        poolManager.initialize(poolKey, INITIAL_SQRT_PRICE);
        logSuccess("Pool initialized successfully");

        // Add liquidity around the current tick
        addLiquidity(deployer);

        // Perform a test swap
        performSwap(deployer, SWAP_AMOUNT);

        // Perform another swap in the same direction
        performSwap(deployer, SWAP_AMOUNT * 2);

        vm.stopBroadcast();

        PoolId poolId = poolKey.toId();

        // Log deployment info for verification
        logHeader("DEPLOYMENT SUMMARY");

        logBytes32("Pool ID", PoolId.unwrap(poolId));
        console.log("");

        logSection("Contract Addresses");
        logInfo("Factory", address(factory));
        logInfo("Hook", address(hook));
        logInfo("Token0", address(token0));
        logInfo("Token1", address(token1));
        logInfo("PoolManager", address(poolManager));
        logInfo("PositionManager", address(positionManager));
        logInfo("StateView", address(stateView));
        logInfo("SwapRouter", address(swapRouter));

        console.log("");
        logSection("Configuration");
        logInfo("Alpha", ALPHA);
        logInfo("Initial Price", INITIAL_SQRT_PRICE);
        logInfo("Tick Spacing", poolKey.tickSpacing);

        console.log("");
        logSuccess("Deployment completed successfully!");
        logDivider();
    }

    /// @notice Add liquidity to the pool around the current tick
    function addLiquidity(address deployer) internal {
        logHeader("ADDING LIQUIDITY");

        logSection("Minting Tokens");
        token0.mint(deployer, LIQUIDITY_AMOUNT);
        token1.mint(deployer, LIQUIDITY_AMOUNT);

        logSuccess("Tokens minted");
        logInfo("Token0 Balance", token0.balanceOf(deployer));
        logInfo("Token1 Balance", token1.balanceOf(deployer));

        // Approve PositionManager to spend tokens
        logSection("Setting Approvals");

        // First approve Permit2 to spend tokens
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        logSuccess("Permit2 approved for both tokens");

        // Then use Permit2 to approve PositionManager
        permit2.approve(
            address(token0),
            address(positionManager),
            type(uint160).max,
            type(uint48).max // No expiration
        );

        permit2.approve(
            address(token1),
            address(positionManager),
            type(uint160).max,
            type(uint48).max // No expiration
        );
        logSuccess("PositionManager approved through Permit2");

        // Calculate tick range around current price
        int24 currentTick = 0; // Approximate tick for 1:1 price

        // Align ticks to tickSpacing
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = ((currentTick - TICK_RANGE) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + TICK_RANGE) / tickSpacing) * tickSpacing;

        logSection("Position Configuration");
        logInfo("Current Tick (approx)", currentTick);
        logInfo("Tick Lower", tickLower);
        logInfo("Tick Upper", tickUpper);

        // Prepare mint parameters
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION parameters
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            LIQUIDITY_AMOUNT, // liquidity amount
            LIQUIDITY_AMOUNT, // amount0Max
            LIQUIDITY_AMOUNT, // amount1Max
            deployer, // recipient
            bytes("") // hookData
        );

        // SETTLE_PAIR parameters
        params[1] = abi.encode(Currency.wrap(address(token0)), Currency.wrap(address(token1)));

        logSection("Executing Liquidity Addition");
        console.log("[...] Calling modifyLiquidities...");

        // Add liquidity through PositionManager
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60 // deadline
        );

        logSuccess("Liquidity added successfully");
        logInfo("Liquidity Amount", LIQUIDITY_AMOUNT);
        logDivider();
    }

    /// @notice Perform a test swap on the pool
    function performSwap(address deployer, uint256 amount) internal {
        logHeader("EXECUTING SWAP");

        logSection("Preparing Swap");
        // Mint tokens for swap
        token0.mint(deployer, amount);
        logSuccess("Tokens minted for swap");
        logInfo("Swap Amount", amount);

        logSection("Balances Before Swap");
        uint256 token0Before = token0.balanceOf(deployer);
        uint256 token1Before = token1.balanceOf(deployer);
        logInfo("Token0", token0Before);
        logInfo("Token1", token1Before);

        // Approve swap router to spend tokens
        token0.approve(address(swapRouter), amount);
        logSuccess("SwapRouter approved");

        // Set up swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: true, // Swapping token0 for token1
            amountSpecified: -int256(amount), // Negative for exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 // No price limit
        });

        // Prepare test settings
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        logSection("Executing Swap");
        console.log(string.concat("[...] Swapping ", vm.toString(amount), " token0 for token1..."));

        // Execute swap
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            params,
            testSettings,
            bytes("") // hookData
        );

        logSuccess("Swap completed successfully");

        logSection("Balances After Swap");
        uint256 token0After = token0.balanceOf(deployer);
        uint256 token1After = token1.balanceOf(deployer);
        logInfo("Token0", token0After);
        logInfo("Token1", token1After);

        logSection("Balance Deltas");
        console.log(string.concat("  * Amount0: ", vm.toString(delta.amount0())));
        console.log(string.concat("  * Amount1: ", vm.toString(delta.amount1())));

        logSection("Net Changes");
        console.log(string.concat("  * Token0 Change: ", vm.toString(int256(token0After) - int256(token0Before))));
        console.log(string.concat("  * Token1 Change: ", vm.toString(int256(token1After) - int256(token1Before))));

        logDivider();
    }

    /// @notice Mine for a salt that will produce a hook address with the desired flags
    /// @param factoryAddr The address of the CREATE2 factory
    /// @param bytecode The creation bytecode
    /// @return salt The salt that produces the correct address
    function mineSalt(address factoryAddr, bytes memory bytecode) internal view returns (bytes32) {
        bytes32 bytecodeHash = keccak256(bytecode);

        // Mine for a salt
        for (uint256 i = 0; i < 100_000_000; i++) {
            bytes32 salt = bytes32(i);

            address predictedAddress = computeCreate2Address(factoryAddr, salt, bytecodeHash);

            uint160 addressFlags = uint160(predictedAddress) & Hooks.ALL_HOOK_MASK;

            // Check if this address has the required hook flags
            if (addressFlags == HOOK_FLAGS) {
                console.log(string.concat("  [OK] Found after ", vm.toString(i), " iterations"));
                logInfo("Predicted Address", predictedAddress);
                return salt;
            }

            // Log progress every million iterations
            if (i % 1_000_000 == 0 && i > 0) {
                logProgress("Mining", i, 100_000_000);
            }
        }

        revert("Could not find valid salt within range");
    }

    /// @notice Compute the CREATE2 address
    /// @param deployer The deployer address (factory)
    /// @param salt The salt
    /// @param initCodeHash The init code hash
    /// @return The predicted address
    function computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
