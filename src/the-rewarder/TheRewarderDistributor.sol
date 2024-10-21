// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

struct Distribution {
    uint256 remaining;
    uint256 nextBatchNumber;
    mapping(uint256 batchNumber => bytes32 root) roots;
    mapping(address claimer => mapping(uint256 word => uint256 bits)) claims;
}

struct Claim {
    uint256 batchNumber;
    uint256 amount;
    uint256 tokenIndex;
    bytes32[] proof;
}

/**
 * An efficient token distributor contract based on Merkle proofs and bitmaps
 */
contract TheRewarderDistributor {
    /*---------- Libraries ----------*/
    using BitMaps for BitMaps.BitMap;

    /*---------- Contract Variables ----------*/
    address public immutable owner = msg.sender;
    mapping(IERC20 token => Distribution) public distributions;

    /*---------- Errors ----------*/
    error StillDistributing();
    error InvalidRoot();
    error AlreadyClaimed();
    error InvalidProof();
    error NotEnoughTokensToDistribute();

    /*---------- Events ----------*/
    event NewDistribution(IERC20 token, uint256 batchNumber, bytes32 newMerkleRoot, uint256 totalAmount);

    /*---------- View Functions ----------*/
    /**
     * @notice      Get the remaining tokens to be distributed in the current batch.
     * @param       token       The address of the token to be distributed
     */
    function getRemaining(address token) external view returns (uint256) {
        return distributions[IERC20(token)].remaining;
    }

    function getNextBatchNumber(address token) external view returns (uint256) {
        return distributions[IERC20(token)].nextBatchNumber;
    }

    /**
     * @notice      Retrieve the merkle root of a distribution batch for a specific token.
     * @param       token           The address of the token to be distributed
     * @param       batchNumber     The batch number of the distribution
     */
    function getRoot(address token, uint256 batchNumber) external view returns (bytes32) {
        return distributions[IERC20(token)].roots[batchNumber];
    }

    /**
     * @notice      Creates a new distribution for a specific token.
     * @param       token       The address of the token to be distributed
     * @param       newRoot     The merkle root of the distribution
     * @param       amount      The amount to be distributed
     */
    function createDistribution(IERC20 token, bytes32 newRoot, uint256 amount) external {
        if (amount == 0) revert NotEnoughTokensToDistribute(); // Distribution amount can't be 0
        if (newRoot == bytes32(0)) revert InvalidRoot(); // Invalid merkle root
        if (distributions[token].remaining != 0) revert StillDistributing(); // The token needs to be either finished distributed or haven't created

        distributions[token].remaining = amount; // Assign the distribution remaining to amount

        uint256 batchNumber = distributions[token].nextBatchNumber; // Get the next batch number, if first created it will be 0
        distributions[token].roots[batchNumber] = newRoot; // Assign the merkle root to batch number
        distributions[token].nextBatchNumber++; // The next batch number

        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount); // Transfer token from the person who created this

        emit NewDistribution(token, batchNumber, newRoot, amount); // Emit NewDistribution event
    }

    /**
     * @notice      Seems like a function to cleanup tokens that were accidentally sent to this contract.
     * @param       tokens      The array of tokens to be cleaned
     */
    function clean(IERC20[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = tokens[i];
            if (distributions[token].remaining == 0) {
                token.transfer(owner, token.balanceOf(address(this)));
            }
        }
    }

    // struct Claim {
    //     uint256 batchNumber;
    //     uint256 amount;
    //     uint256 tokenIndex;
    //     bytes32[] proof;
    // }

    /**
     * @notice      Allow claiming rewards of multiple tokens in a single transaction
     * @param       inputClaims       The array of inputClaim of type struct Claim
     */
    function claimRewards(Claim[] memory inputClaims, IERC20[] memory inputTokens) external {
        Claim memory inputClaim; // Container to hold a single Claim information
        IERC20 token; // Container to hold a single IERC20 information
        uint256 bitsSet; // Bitmap to indicate which batch has been claimed
        uint256 amount; // Amount to be claimed

        // Iterate through the entire Claims[]
        for (uint256 i = 0; i < inputClaims.length; i++) {
            inputClaim = inputClaims[i];

            uint256 wordPosition = inputClaim.batchNumber / 256; // The word position represented by a 2^256 - 1 uint
            uint256 bitPosition = inputClaim.batchNumber % 256; // The bit position represented by 256 bits

            // If the token in memory is not same as the current token that we are processing
            if (token != inputTokens[inputClaim.tokenIndex]) {
                // This condition effectively means if not the first iter
                if (address(token) != address(0)) {
                    // Set claimed for the previous token
                    if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
                }
                // Change token in memory
                token = inputTokens[inputClaim.tokenIndex];
                // Effectively resets bitsSet and movess the new bitset to bitPosition
                bitsSet = 1 << bitPosition; // set bit at given position
                // Set amount as the new amount to claim
                amount = inputClaim.amount;
            } else {
                // This condition enters indicates that ther previous claiming tokens and the current token ins the same
                // Uses 'OR' operator to merge bitSet + bitPosition
                bitsSet = bitsSet | 1 << bitPosition;
                // add the inputClaim.amount to amount
                amount += inputClaim.amount;
            }

            // for the last claim
            // If we are currently processing the last cycle, since we are not entering the next iter,
            // we need to set claimed now
            if (i == inputClaims.length - 1) {
                if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
            }

            // Generate the leaf
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, inputClaim.amount));
            // Merkle root
            bytes32 root = distributions[token].roots[inputClaim.batchNumber];
            // Verify the proof provided by claimer
            if (!MerkleProof.verify(inputClaim.proof, root, leaf)) revert InvalidProof();
            // Transfer to claimer
            inputTokens[inputClaim.tokenIndex].transfer(msg.sender, inputClaim.amount);
        }
    }

    function _setClaimed(IERC20 token, uint256 amount, uint256 wordPosition, uint256 newBits) private returns (bool) {
        uint256 currentWord = distributions[token].claims[msg.sender][wordPosition];
        if ((currentWord & newBits) != 0) return false;

        // update state
        distributions[token].claims[msg.sender][wordPosition] = currentWord | newBits;
        distributions[token].remaining -= amount;

        return true;
    }
}
