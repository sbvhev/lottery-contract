const configs = require('./configs');

async function main() {
  const [ deployer ] = await ethers.getSigners();
  console.log(`Deployer address: ${deployer.address}`);
  const deployerBalance = await deployer.getBalance();
  console.log(`Deployer balance: ${deployerBalance}`);

  const provider = deployer.provider;
  const network = await provider.getNetwork();
  console.log(`Network: ${network.name} with chainId ${network.chainId}`);
  const envVars = configs[network.chainId];

  const networkGasPrice = (await provider.getGasPrice()).toNumber();
  const gasPrice = Math.ceil(networkGasPrice * 1.2);
  console.log(`Gas Price balance: ${gasPrice}`);
  
  // get the contract to deploy
  const CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
  const CoverPool = await ethers.getContractFactory('CoverPool');
  const Cover = await ethers.getContractFactory('Cover');
  const CoverERC20 = await ethers.getContractFactory('CoverERC20');
  const ClaimManagement = await ethers.getContractFactory('ClaimManagement');
  
  // deploy CoverPool logic contract
  let coverPoolImpl = envVars.coverPool;
  if (coverPoolImpl) {
    coverPoolImpl = CoverPool.attach(coverPoolImpl);
  } else {
    coverPoolImpl = await CoverPool.deploy({ gasPrice });
    await coverPoolImpl.deployed();
  }
  console.log(`coverPoolImpl address: ${coverPoolImpl.address}`);
  
  // deploy Cover logic contract
  let coverImpl = envVars.cover;
  if (coverImpl) {
    coverImpl = Cover.attach(coverImpl);
  } else {
    coverImpl = await Cover.deploy({ gasPrice });
    await coverImpl.deployed();
  }
  console.log(`coverImpl address: ${coverImpl.address}`);
  
  // deploy CoverERC20 logic contract
  let coverERC20Impl = envVars.coverERC20;
  if (coverERC20Impl) {
    coverERC20Impl = CoverERC20.attach(coverERC20Impl);
  } else {
    coverERC20Impl = await CoverERC20.deploy({ gasPrice });
    await coverERC20Impl.deployed();
  }
  console.log(`coverERC20Impl address: ${coverERC20Impl.address}`);

  // deploy coverPoolFactory
  let coverPoolFactory = envVars.factory;
  if (coverPoolFactory) {
    coverPoolFactory = CoverPoolFactory.attach(coverPoolFactory);
  } else {
    coverPoolFactory = await CoverPoolFactory.deploy(
      coverPoolImpl.address,
      coverImpl.address,
      coverERC20Impl.address,
      envVars.treasury,
      { gasPrice }
    );
    await coverPoolFactory.deployed();
  }
  console.log(`CoverPoolFactory address: ${coverPoolFactory.address}`);

  // add one cover Pool
  if (![1].includes(network.chainId)) {
    try {
      await coverPoolFactory.createCoverPool(
        'Badger',
        true,
        ['Digg', 'Badger', 'wbtcDiggSLP', 'wbtcBadgerSLP', 'wbtcWethSLP', 'wbtcDiggUNI-V2', 'wbtcBadgerUNI-V2', 'crvRenWBTCHavest', 'tbtc/sbtcCrv', 'crvRenWSBTC', 'crvRenWBTC'],
        '0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa',
        ethers.utils.parseEther("1"),
        1640908800,
        '2012_12_31'
      );
      await coverPoolFactory.createCoverPool(
        'RulerCDS1',
        true,
        ['wBTC', 'wETH', 'xCOVER', 'COVER', 'INV', 'vETH2'],
        '0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa',
        ethers.utils.parseEther("1"),
        1640908800,
        '2012_12_31'
      );
      await coverPoolFactory.createCoverPool(
        'Rari',
        true,
        ['pool1', 'pool3', 'pool4'],
        '0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa',
        ethers.utils.parseEther("1"),
        1640908800,
        '2012_12_31'
      );
    } catch (e) {
      console.log('Error create cover pool', e);
    }
  }

  // deploy claimManagement
  let claimManagement = envVars.claimManagement;
  if (claimManagement) {
    claimManagement = ClaimManagement.attach(claimManagement);
  } else {
    claimManagement = await ClaimManagement.deploy(
      envVars.dai,
      envVars.treasury,
      coverPoolFactory.address,
      envVars.auditor,
      { gasPrice }
    );
    await claimManagement.deployed();
    await claimManagement.transferOwnership(envVars.dev, { gasPrice });
    const cmOwner = await claimManagement.owner();
    console.log(`ClaimManagement owner: ${cmOwner}`);
  }
  console.log(`ClaimManagement address: ${claimManagement.address}`);
  
  // assign claimManagement address to be the claimManager of coverPoolFactory
  await coverPoolFactory.setClaimManager(claimManagement.address);
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
