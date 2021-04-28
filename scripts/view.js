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

  const CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
  const CoverPool = await ethers.getContractFactory('CoverPool');
  const Cover = await ethers.getContractFactory('Cover');
  const CoverERC20 = await ethers.getContractFactory('CoverERC20');
  const ClaimManagement = await ethers.getContractFactory('ClaimManagement');
  // const coverPool = CoverPool.attach(envVars.coverPool);
  // const cover = Cover.attach(envVars.cover);
  // const coverERC20 = CoverERC20.attach(envVars.coverERC20);
  // const coverPoolFactory = CoverPoolFactory.attach(envVars.factory);
  // const claimManagement = ClaimManagement.attach(envVars.claimManagement);

  // check owners
  // const factoryOwner = await coverPoolFactory.owner();
  // console.log(`coverPoolFactory owner: ${factoryOwner}`);
  // const claimManagementOwner = await claimManagement.owner();
  // console.log(`claimManagement owner: ${claimManagementOwner}`);

  // check CoverPool 0x686f472d46b3c7bd58d2d0df22e9adbf0a4f2083 
  const coverPool = CoverPool.attach('0x3F116385699d5A93cbEE8460A521F37c6458574C');
  const name = await coverPool.name();
  console.log('coverPool name: ', name);
  const details = await coverPool.getCoverPoolDetails();
  console.log('coverPool details: ', details);
  await checkCoverDeploy('0x7A5613B2eA4fE58F4b4849769E00622CB1E6c4e5');
  
  // await coverPool.deployCover('0xcB02820d168D0C05f5c539abE0b9014E8B375C8F', 1640908800);
  
  // const coverYearn = Cover.attach('0xD316790fE78B6b9106ae8C7a524aBbB46a430b33');
  // const coverDetails = await coverYearn.getCovTokens();
  // console.log('coverDetails: ', coverDetails);
}

async function checkCoverDeploy(addr) {
  const Cover = await ethers.getContractFactory('Cover');
  const isComplete = await Cover.attach(addr).deployComplete();
  console.log(`Cover deploymenton ${addr} is ${isComplete} complete.`)
  return isComplete;
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
