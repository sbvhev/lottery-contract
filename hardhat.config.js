require("@nomiclabs/hardhat-waffle");
// require("@nomiclabs/buidler-web3"); // necessary for time to work
require('hardhat-contract-sizer');
require('@nomiclabs/hardhat-etherscan');

require('dotenv').config();

// This is a sample Buidler task. To learn how to create your own go to
// https://buidler.dev/guides/create-task.html
task("accounts", "Prints the list of accounts", async () => {
  const accounts = await ethers.getSigners();

  for (const account of accounts) {
    console.log(await account.getAddress());
  }
});

// You have to export an object to set up your config
// This object can have the following optional entries:
// defaultNetwork, networks, solc, and paths.
// Go to https://buidler.dev/config/ to learn more
module.exports = {
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
    disambiguatePaths: false,
  },
  optimizer: {
    enabled: true,
    runs: 200,
  },
  // defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
      loggingEnabled: true,
    },
    localhost: {
      url: "http://127.0.0.1:8545", // same address and port for both Buidler and Ganache node
      gas: 8000000,
      gasLimit: 8000000,
      gasPrice: 1,
    },
    kovan: {
      url: process.env.KOVAN_INFURA_URL ? process.env.KOVAN_INFURA_URL : '',
      accounts: process.env.KOVAN_DEV_PRIVATE_KEY ? [`0x${process.env.KOVAN_DEV_PRIVATE_KEY}`] : [],
      gas: 8000000,
      gasLimit: 8000000,
    },
    mainnet: {
      url: process.env.MAINNET_INFURA_URL ? process.env.MAINNET_INFURA_URL : '',
      accounts: process.env.MAINNET_DEV_PRIVATE_KEY ? [`0x${process.env.MAINNET_DEV_PRIVATE_KEY}`] : [],
      // gas: 8000000,
      // gasLimit: 8000000,
      // gasPrice: 65000000000,
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY
  },
  // This is a sample solc configuration that specifies which version of solc to use
  solidity: {
    version: "0.8.0",
    settings: {
      optimizer: {
        enabled: true
      }
    }
  },
};
