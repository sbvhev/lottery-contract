const { expect } = require('chai');
const { expectRevert } = require("@openzeppelin/test-helpers");
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('CoverPoolFactory', () => {
  let ownerAccount, ownerAddress, userAAccount, userAAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl;
  let coverPoolFactory, dai, COLLATERAL;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    // use deployed stablecoin address for collaterals
    COLLATERAL = dai.address;
  });

  beforeEach(async () => {
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
  });

  it('Should deploy with correct state variable values', async () => {
    expect(await coverPoolFactory.coverPoolImpl()).to.equal(coverPoolImpl.address);
    expect(await coverPoolFactory.coverImpl()).to.equal(coverImpl.address);
    expect(await coverPoolFactory.coverERC20Impl()).to.equal(coverERC20Impl.address);
    expect(await coverPoolFactory.governance()).to.equal(governanceAddress);
    expect(await coverPoolFactory.treasury()).to.equal(treasuryAddress);
    expect(await coverPoolFactory.deployGasMin()).to.equal(1000000);
    expect(await coverPoolFactory.paused()).to.equal(false);
  });

  it('Should emit CoverPoolCreation event', async () => {
    await expect(coverPoolFactory.connect(ownerAccount)
      .createCoverPool(consts.ASSET_1, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.emit(coverPoolFactory, 'CoverPoolCreated');
  });

  // test functions with governance access restriction
  it('Should NOT update governance to address(0) by governance', async () => {
    await expectRevert(coverPoolFactory.setGovernance(consts.ADDRESS_ZERO), 'CoverPoolFactory: address cannot be 0');
  });

  it('Should NOT update governance to owner by governance', async () => {
    await expectRevert(coverPoolFactory.setGovernance(ownerAddress), 'CoverPoolFactory: governance cannot be owner');
  });

  // test functions with owner access restriction
  it('Should update vars by authorized only', async () => {
    // should only be updated by owner
    await expect(coverPoolFactory.connect(userAAccount).setClaimManager(userAAddress)).to.be.reverted;
    await expect(coverPoolFactory.connect(ownerAccount).setClaimManager(userAAddress)).to.emit(coverPoolFactory, 'AddressUpdated');
    expect(await coverPoolFactory.claimManager()).to.equal(userAAddress);

    // should only be updated by owner
    await coverPoolFactory.connect(ownerAccount).setDeployGasMin(6000000);
    expect(await coverPoolFactory.deployGasMin()).to.equal(6000000);
    await expect(coverPoolFactory.connect(ownerAccount).setTreasury(ownerAddress)).to.emit(coverPoolFactory, 'AddressUpdated');
    await expect(coverPoolFactory.connect(ownerAccount).setCoverERC20Impl(dai.address)).to.emit(coverPoolFactory, 'ImplUpdated');
    await expect(coverPoolFactory.connect(ownerAccount).setCoverImpl(dai.address)).to.emit(coverPoolFactory, 'ImplUpdated');
    await expect(coverPoolFactory.connect(ownerAccount).setCoverPoolImpl(dai.address)).to.emit(coverPoolFactory, 'ImplUpdated');

    await expect(coverPoolFactory.setGovernance(userAAddress)).to.emit(coverPoolFactory, 'AddressUpdated');

    await expect(coverPoolFactory.connect(ownerAccount).setResponder(userAAddress)).to.emit(coverPoolFactory, 'AddressUpdated');
    await expect(coverPoolFactory.connect(userAAccount).setPaused(true)).to.emit(coverPoolFactory, 'PausedStatusUpdated');
    expect(await coverPoolFactory.paused()).to.equal(false);
  });

  it('Should add 2 new coverPools by owner', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_1, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, true, [consts.ASSET_1, consts.ASSET_2], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);
    expect((await coverPoolFactory.getCoverPools()).length).to.equal(2);

    const coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_1));
    expect(await coverPool.name()).to.equal(consts.POOL_1);
    const coverPool2 = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_3));
    const [,,,,,assetList] = await coverPool2.getCoverPoolDetails();
    expect(await coverPool2.name()).to.equal(consts.POOL_3);
    expect(ethers.utils.parseBytes32String(assetList[0])).to.equal(consts.ASSET_1);
    expect(assetList[1]).to.equal(consts.ASSET_2_BYTES32);
    expect(await coverPool2.collateralStatusMap(COLLATERAL)).to.deep.equal([consts.DEPOSIT_RATIO, 1]);
  });

  it('Should compute the same coverPool addresses', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);  

    const coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_3));
    expect(await coverPool.name()).to.equal(consts.POOL_3);

    const computedAddr = await coverPoolFactory.getCoverPoolAddress(consts.POOL_3);
    expect(computedAddr).to.equal(coverPool.address);
  });

  it('Should NOT add new coverPool by userA', async () => {
    await expect(coverPoolFactory
      .connect(userAAccount)
      .createCoverPool(consts.ASSET_1, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.be.reverted;
  });
});