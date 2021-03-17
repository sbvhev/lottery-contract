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

## Coverage
* run `npx hardhat coverage --solcoverjs ./.solcover.js --network localhost`, note one test (`Should deploy Cover in two txs with CoverPool`) will fail. Follow the steps above, it should pass.

## Deploy to Kovan Testnet
* Run `npx hardhat run scripts/deploy.js --network kovan`
* Verify CoverPoolFactory: args - (coverPoolImpl, coverImpl, coverERC20Impl, treasury)
  * npx hardhat verify --network kovan 0xDC265877074655DF30712Cb59B5b24eBE51df698 "0x907c2eDC9A31E0d6230FaC98B2e6E441bE61E7cB" "0xa7515d4eB1eA8a57B879D4A4c267647f080B44f8" "0x3Ff814F5D104Ee696F721A600A8def5D8346858D" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d"
* Verify Claim Management: args - (fee, treasury, coverPoolFactory, defaultCVC/auditor)
  * npx hardhat verify --network kovan 0x584288Fa61D899066aCad1deF556ca0f3DB0e469 "0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa" "0xe50fb5e4f608d96beb8b4364522e189fb98d821d" "0xF975ED6E2296Ec6953Dd77450Fb23389053d188F" "0x92E812467Df28763814f465048ae4c2AFfAd7631"
* Verify Implementations:
  * npx hardhat verify --network kovan {address}

* View on Kovan `npx hardhat run scripts/view.js --network kovan`