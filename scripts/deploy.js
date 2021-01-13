const configs = require('./configs');

async function main() {
  const [ deployer ] = await ethers.getSigners();
  console.log(`Deployer address: ${deployer.address}`);
  const deployerBalance = await deployer.getBalance();
  console.log(`Deployer balance: ${deployerBalance}`);

  const provider = deployer.provider;
  const network = await provider.getNetwork();
  console.log(`Network: ${network.name} is koven ${network.name === 'kovan'}`);
  const envVars = network.name === 'kovan' ? configs.kovan : configs.mainnet;

  const networkGasPrice = (await provider.getGasPrice()).toNumber();
  const gasPrice = networkGasPrice * 1.05;
  console.log(`Gas Price balance: ${gasPrice}`);
  
  // get the contract to deploy
  const CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
  const CoverPool = await ethers.getContractFactory('CoverPool');
  const Cover = await ethers.getContractFactory('Cover');
  const CoverERC20 = await ethers.getContractFactory('CoverERC20');
  const ClaimManagement = await ethers.getContractFactory('ClaimManagement');
  
  // deploy CoverPool logic contract
  const coverPoolImpl = await CoverPool.deploy({ gasPrice });
  await coverPoolImpl.deployed();
  console.log(`coverPoolImpl address: ${coverPoolImpl.address}`);
  
  // deploy Cover logic contract
  const coverImpl = await Cover.deploy({ gasPrice });
  await coverImpl.deployed();
  console.log(`coverImpl address: ${coverImpl.address}`);
  
  // deploy CoverERC20 logic contract
  const coverERC20Impl = await CoverERC20.deploy({ gasPrice });
  await coverERC20Impl.deployed();
  console.log(`coverERC20Impl address: ${coverERC20Impl.address}`);

  // deploy coverPoolFactory
  const coverPoolFactory = await CoverPoolFactory.deploy(
    coverPoolImpl.address,
    coverImpl.address,
    coverERC20Impl.address,
    envVars.gov,
    envVars.treasury,
    { gasPrice }
  );
  await coverPoolFactory.deployed();
  console.log(`CoverPoolFactory address: ${coverPoolFactory.address}`);

  // deploy claimManagement
  const claimManagement = await ClaimManagement.deploy(
    envVars.gov,
    envVars.treasury,
    coverPoolFactory.address,
    envVars.auditor,
    { gasPrice }
  );
  await claimManagement.deployed();
  console.log(`ClaimManagement address: ${claimManagement.address}`);
  await claimManagement.transferOwnership(envVars.dev, { gasPrice });
  const cmOwner = await claimManagement.owner();
  console.log(`ClaimManagement owner: ${cmOwner}`);
  
  // assign claimManagement address to be the claimManager of coverPoolFactory
  await coverPoolFactory.updateClaimManager(claimManagement.address);
  const cmInFactory = await coverPoolFactory.claimManager();
  console.log(`protocolFactory cm: ${cmInFactory}`);
  
  // transfer factory owner
  await coverPoolFactory.transferOwnership(envVars.dev, { gasPrice });
  const factoryOwner = await coverPoolFactory.owner();
  console.log(`coverPoolFactory owner: ${factoryOwner}`);
  console.log(`Deploy complete!`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
