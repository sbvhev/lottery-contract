# cover-core-v2

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