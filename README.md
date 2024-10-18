# Solutions For Damn Vulnerable DeFi v4

This repository contains my solutions for the challenges in Damn Vulnerable DeFi v4.

Damn Vulnerable DeFi v4 is a collection of deliberately vulnerable smart contracts designed to educate developers about the risks and vulnerabilities in DeFi protocols.

## Explain

In these series of challenges, the vulnerable code will be presented in src/{challenge-name}/ and the test/hack code will be in test/

## Table of Contents

1. [ABI Smuggling](./test/abi-smuggling/) -> Solved ✅ => Learned about how to manually construct a calldata to bypass checks
2. [Side Entrace](./test/side-entrace) -> Solved ✅
3. [Free Rider](./test/free-rider) -> Solved ✅
4. [Puppet](./test/puppet) -> Solved ✅ (The test design is flawed as how Foundry's vm increases nonce is different than real life)
5. [Puppet V2](./test/puppet-v2) -> Solved ✅
6. [Truster](./test/truster/) -> Solved ✅ Easiest so far
7. [Selfie](./test/selfie/) -> Solved ✅
8. [Compromised](./test/compromised/) -> Solved ✅ => Not so much of a code bug but rather a leak
9. [Backdoor](./test/backdoor/) -> Solved ✅ => Indeed something new, forced to look into ProxyWallet's inplementation code
10. [Unstoppable](./test/unstoppable/) -> Solved ✅ => The most LOL, upon seeing this ```if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance();``` transferred 10 tokens to the vault and it halts. Learned about ERC4626, good thing.
11. [Naive Receiver](./test/naive-receiver/) -> Learned more details about meta-transactions, relayers ERC2771, and multicall