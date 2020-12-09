const { expect } = require('chai');
const testHelper = require('./testHelper');

describe('CoverPoolFactory', function() {
  const PROTOCOL_NAME = ethers.utils.formatBytes32String('Binance');
  const PROTOCOL_NAME_2 = ethers.utils.formatBytes32String('Curve');
  const ADDRESS_ZERO = ethers.constants.AddressZero;

  // allowed timestamps: [1/1/2020, 31/12/2020, 1/1/2100] UTC
  const ALLOWED_EXPIRATION_TIMESTAMPS = [1580515200000, 1612051200000, 4105123200000];
  const ALLOWED_EXPIRATION_TIMESTAMP_NAMES = ['2020_1_1', '2050_12_31', '2100_1_1'].map(s => ethers.utils.formatBytes32String(s));
  
  let COLLATERAL;
  let ownerAddress, ownerAccount, userAAccount, userAAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, Cover, coverImpl, CoverERC20, coverERC20Impl;
  let coverPoolFactory, dai;

  before(async () => {
    const accounts = await ethers.getSigners();
    [ ownerAccount, userAAccount, governanceAccount, treasuryAccount ] = accounts;
    ownerAddress = await ownerAccount.getAddress();
    userAAddress = await userAAccount.getAddress();
    governanceAddress = await governanceAccount.getAddress();
    treasuryAddress = await treasuryAccount.getAddress();

    // get main contracts
    CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
    CoverPool = await ethers.getContractFactory('CoverPool');
    Cover = await ethers.getContractFactory('Cover');
    CoverERC20 = await ethers.getContractFactory('CoverERC20');

    // deploy stablecoins to local blockchain emulator
    dai = await testHelper.deployCoin(ethers, 'dai');
    // use deployed stablecoin address for collaterals
    COLLATERAL = dai.address;


    // deploy CoverPool contract
    coverPoolImpl = await CoverPool.deploy();
    await coverPoolImpl.deployed();

    // deploy Cover contract
    coverImpl = await Cover.deploy();
    await coverImpl.deployed();

    // deploy CoverERC20 contract
    coverERC20Impl = await CoverERC20.deploy();
    await coverERC20Impl.deployed();
  });

  beforeEach(async () => {
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
  });

  it('Should deploy with correct state variable values', async function() {
    expect(await coverPoolFactory.coverPoolImplementation()).to.equal(coverPoolImpl.address);
    expect(await coverPoolFactory.coverImplementation()).to.equal(coverImpl.address);
    expect(await coverPoolFactory.coverERC20Implementation()).to.equal(coverERC20Impl.address);
    expect(await coverPoolFactory.governance()).to.equal(governanceAddress);
    expect(await coverPoolFactory.treasury()).to.equal(treasuryAddress);
  });

  it('Should emit CoverPoolCreation event', async function() {
    await expect(coverPoolFactory.connect(ownerAccount)
      .createCoverPool(PROTOCOL_NAME, [PROTOCOL_NAME], COLLATERAL, ALLOWED_EXPIRATION_TIMESTAMPS, ALLOWED_EXPIRATION_TIMESTAMP_NAMES)
      ).to.emit(coverPoolFactory, 'CoverPoolCreation');
  });

  // test functions with governance access restriction
  it('Should NOT update governance to address(0) by governance', async function() {
    await expect(coverPoolFactory.connect(governanceAccount).updateGovernance(ADDRESS_ZERO)).to.be.reverted;
  });

  it('Should NOT update governance to owner by governance', async function() {
    await expect(coverPoolFactory.connect(governanceAccount).updateGovernance(ownerAddress)).to.be.reverted;
  });

  // test functions with owner access restriction
  it('Should update claimManager by owner', async function() {
    await coverPoolFactory.connect(ownerAccount).updateClaimManager(userAAddress);
    expect(await coverPoolFactory.claimManager()).to.equal(userAAddress);
  });

  it('Should NOT update claimManager by non-owner', async function() {
    await expect(coverPoolFactory.connect(userAAccount).updateClaimManager(userAAddress)).to.be.reverted;
  });

  it('Should add 2 new coverPools by owner', async function() {
    expect(await coverPoolFactory
      .createCoverPool(PROTOCOL_NAME, [PROTOCOL_NAME], COLLATERAL, ALLOWED_EXPIRATION_TIMESTAMPS, ALLOWED_EXPIRATION_TIMESTAMP_NAMES)
      ).to.not.equal(ADDRESS_ZERO);  
    expect(await coverPoolFactory
      .createCoverPool(PROTOCOL_NAME_2, [PROTOCOL_NAME_2], COLLATERAL, ALLOWED_EXPIRATION_TIMESTAMPS, ALLOWED_EXPIRATION_TIMESTAMP_NAMES)
      ).to.not.equal(ADDRESS_ZERO);
    expect(await coverPoolFactory.getCoverPoolsLength()).to.equal([PROTOCOL_NAME, PROTOCOL_NAME_2].length);

    const coverPoolAddr1 = await coverPoolFactory.coverPools(PROTOCOL_NAME);
    expect(await CoverPool.attach(coverPoolAddr1).name()).to.equal(PROTOCOL_NAME);

    const coverPoolAddr2 = await coverPoolFactory.coverPools(PROTOCOL_NAME_2);
    expect(await CoverPool.attach(coverPoolAddr2).name()).to.equal(PROTOCOL_NAME_2);
  });

  it('Should compute the same coverPool addresses', async function() {
    expect(await coverPoolFactory
      .createCoverPool(PROTOCOL_NAME, [PROTOCOL_NAME], COLLATERAL, ALLOWED_EXPIRATION_TIMESTAMPS, ALLOWED_EXPIRATION_TIMESTAMP_NAMES)
      ).to.not.equal(ADDRESS_ZERO);  

    const coverPoolAddr1 = await coverPoolFactory.coverPools(PROTOCOL_NAME);
    expect(await CoverPool.attach(coverPoolAddr1).name()).to.equal(PROTOCOL_NAME);

    const computedAddr1 = await coverPoolFactory.getCoverPoolAddress(PROTOCOL_NAME);
    expect(computedAddr1).to.equal(coverPoolAddr1);
  });

  it('Should NOT add new coverPool by userA', async function() {
    await expect(coverPoolFactory
      .connect(userAAccount)
      .createCoverPool(PROTOCOL_NAME, [PROTOCOL_NAME], COLLATERAL, ALLOWED_EXPIRATION_TIMESTAMPS, ALLOWED_EXPIRATION_TIMESTAMP_NAMES)
      ).to.be.reverted;
  });
});