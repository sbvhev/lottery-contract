# cover-core-v2

## Design
The essense of Cover is CoverPools. Each CoverPool consists of multiple risky underlying to be covered. If any of the risky underlying of a pool experience an exploit (as per claims guidelines), all active coverages (Cover) of the CoverPool will be paid out up to 100%.

The following are the elements of the V2.
* **CoverPoolFactory** is the contract that creates CoverPools. It also stores information that are common to all V2 contracts, like logic contract implementation addresses, addresses of multi-sigs, claim manager address etc.
* **CoverPool** is the main element of V2. It handles coverage creation and minting, adding/deleting risk covered, stores accepted claims for the pool. A **risk** can be an asset or underlying that is covered in a coverage.
* **Cover** stores the deposited collateral funds for the coverage and handle minting and burning of covTokens, redeeming of collaterals
* **CoverERC20** the ERC20 covToken contract, normal ERC20 funcs with a few Cover specific func.
* **ClaimManagement** (ClaimConfig is part of that) manages the claiming process of Cover Protocol. It may call CoverPool on
..* `enactClaim` when a claim is accepted
..* `setNoclaimRedeemDelay` when a claim is filed or all claims are decided


## Development
* run `npm install` to install all node dependencies
* run `npx hardhat compile` to compile

### Run Test With hardhat EVM (as [an independent node](https://hardhat.dev/hardhat-evm/#connecting-to-hardhat-evm-from-wallets-and-other-software))
* Run `npx hardhat node` to setup a local blockchain emulator in one terminal.
* `npx hardhat test --network localhost` run tests in a new terminal.
 **`npx hardhat node` restart required after full test run.** As the blockchain timestamp has changed.

 ## Deploy to Kovan Testnet
* Run `npx hardhat run scripts/deploy.js --network kovan`
* Verify CoverPoolFactory: args - (coverPoolImpl, coverImpl, coverERC20Impl, treasury)
  * npx hardhat verify --network kovan 0xa237aBE9EF0dA5B39730171571E6752b2D66851a "0x235cfc4E58f6Cb8046185CE96e9fb36014e91cE1" "0x9442E7F630ecbCd730015279d47cAEAB62b050ce" "0x6FE027ce26bA469f01c9d155279E66E1385a7957" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d"
* Verify Claim Management: args - (fee, treasury, coverPoolFactory, defaultCVC/auditor)
  * npx hardhat verify --network kovan 0xBac927E70E97dd859fAF3B46698e98F82cAD6122 "0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xa237aBE9EF0dA5B39730171571E6752b2D66851a" "0x92E812467Df28763814f465048ae4c2AFfAd7631"
* Verify Implementations:
  * npx hardhat verify --network kovan {address}

* View on Kovan `npx hardhat run scripts/view.js --network kovan`