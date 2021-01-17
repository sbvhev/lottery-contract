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
* Verify CoverPoolFactory: args - (coverPoolImpl, coverImpl, coverERC20Impl, gov, treasury)
  * npx hardhat verify --network kovan 0x629A9F87b08131855e1fDBCC8e051b6313c0E0F5 "0xeA9cDbB866E3FF0484434d21ca378C9c923865EC" "0xE9DE405618a1f788C64f579fB36749d77725ACa5" "0x6d735fdf8670d138e04398F20f7aD12c7b769fd3" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d"
* Verify Claim Management: args - (gov, treasury, coverPoolFactory, defaultCVC/auditor)
  * npx hardhat verify --network kovan 0x47b2989d5123DA47B4113f0FB55758ECeee0341A "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0x629A9F87b08131855e1fDBCC8e051b6313c0E0F5" "0x92E812467Df28763814f465048ae4c2AFfAd7631"
* Verify Implementations:
  * npx hardhat verify --network kovan 0xeA9cDbB866E3FF0484434d21ca378C9c923865EC
  * npx hardhat verify --network kovan 0xE9DE405618a1f788C64f579fB36749d77725ACa5
  * npx hardhat verify --network kovan 0x6d735fdf8670d138e04398F20f7aD12c7b769fd3

* View on Kovan `npx hardhat run scripts/view.js --network kovan`