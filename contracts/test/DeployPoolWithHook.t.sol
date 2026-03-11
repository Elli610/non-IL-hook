// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.13;

// import {Test} from "forge-std/Test.sol";
// import {NonToxicPool, HOOK_FLAGS} from "../src/NonToxicPool.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {MockERC20} from "./MockERC20.sol";
// import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// contract HookTest is Test {
//     using LPFeeLibrary for uint24;

//     IPoolManager public poolManager;
//     IPositionManager public positionManager;
//     NonToxicPool public hook;
//     IERC20 public token0;
//     IERC20 public token1;

//     function setUp() public {
//         string memory rpcUrl = vm.envString("RPC_URL");
//         vm.createSelectFork(rpcUrl);
//         vm.selectFork(0);

//         poolManager = IPoolManager(
//             address(0x000000000004444c5dc75cB358380D2e3dE08A90) // mainnet address
//         );

//         positionManager = IPositionManager(
//             address(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e)
//         );

//         address stateView = address(0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227);

//         uint256 alpha = 1;

//         // Deploy BOTH tokens
//         MockERC20 tokenA = new MockERC20("tokenA", "TA");
//         MockERC20 tokenB = new MockERC20("tokenB", "TB");

//         // Sort tokens - currency0 must be < currency1
//         if (address(tokenA) < address(tokenB)) {
//             token0 = tokenA;
//             token1 = tokenB;
//         } else {
//             token0 = tokenB;
//             token1 = tokenA;
//         }

//         // Deploy our hook with the proper flags
//         address hookAddress = address(HOOK_FLAGS);

//         deployCodeTo(
//             "NonToxicPool",
//             abi.encode(poolManager, stateView, alpha),
//             hookAddress
//         );
//         hook = NonToxicPool(hookAddress);
//     }

//     function testDeployPoolWithHook() public {
//         int24 tickSpacing = 1; // Minimum
//         uint24 initialFee = 0x800000; // Dynamic fee flag

//         PoolKey memory key = PoolKey({
//             currency0: Currency.wrap(address(token0)),
//             currency1: Currency.wrap(address(token1)),
//             fee: initialFee,
//             tickSpacing: initialFee.isDynamicFee()
//                 ? int24(60)
//                 : int24((initialFee / 100) * 2),
//             hooks: hook
//         });

//         poolManager.initialize(key, uint160(2288668768328953335596493506431));
//     }
// }
