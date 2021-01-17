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
  * npx hardhat verify --network kovan 0xe15d59AD268759e6fB8D22Afc9a46E5E6f96f600 "0xCfA977dd0844E7DC8Dbdab00aeD076e6189e0765" "0xA5C0D4982588e54b9095590C8C2e03E0F811fb5a" "0x71fB7954bA078091A13FC85c7EF0d0D33210B9A6" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d"
* Verify Claim Management: args - (gov, treasury, coverPoolFactory, defaultCVC/auditor)
  * npx hardhat verify --network kovan 0x8928eFa288Ef2d694dafA18975467FA5f9f97B8E "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xe15d59AD268759e6fB8D22Afc9a46E5E6f96f600" "0x92E812467Df28763814f465048ae4c2AFfAd7631"
* Verify Implementations:
  * npx hardhat verify --network kovan 0xCfA977dd0844E7DC8Dbdab00aeD076e6189e0765
  * npx hardhat verify --network kovan 0xA5C0D4982588e54b9095590C8C2e03E0F811fb5a
  * npx hardhat verify --network kovan 0x71fB7954bA078091A13FC85c7EF0d0D33210B9A6

* View on Kovan `npx hardhat run scripts/view.js --network kovan`