const configs = require('./configs');

async function main() {
  const [ deployer ] = await ethers.getSigners();
  console.log(`Deployer address: ${deployer.address}`);
  const deployerBalance = await deployer.getBalance();
  console.log(`Deployer balance: ${deployerBalance}`);

  const provider = deployer.provider;
  const network = await provider.getNetwork();
  console.log(`Network: ${network.name} is kovan ${network.name === 'kovan'}`);
  const envVars = network.name === 'kovan' ? configs.kovan : configs.mainnet;

  const CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
  const CoverPool = await ethers.getContractFactory('CoverPool');
  const Cover = await ethers.getContractFactory('Cover');
  const CoverERC20 = await ethers.getContractFactory('CoverERC20');
  const ClaimManagement = await ethers.getContractFactory('ClaimManagement');
  const coverPool = CoverPool.attach(envVars.coverPool);
  const cover = Cover.attach(envVars.cover);
  const coverERC20 = CoverERC20.attach(envVars.coverERC20);
  const coverPoolFactory = CoverPoolFactory.attach(envVars.factory);
  const claimManagement = ClaimManagement.attach(envVars.claimManagement);

  const factoryOwner = await coverPoolFactory.owner();
  console.log(`coverPoolFactory owner: ${factoryOwner}`);
  const claimManagementOwner = await claimManagement.owner();
  console.log(`claimManagement owner: ${claimManagementOwner}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
