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
  });

  it('Should emit CoverPoolCreation event', async () => {
    await expect(coverPoolFactory.connect(ownerAccount)
      .createCoverPool(consts.ASSET_1, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.emit(coverPoolFactory, 'CoverPoolCreation');
  });

  // test functions with governance access restriction
  it('Should NOT update governance to address(0) by governance', async () => {
    await expectRevert(coverPoolFactory.connect(governanceAccount).updateGovernance(consts.ADDRESS_ZERO), 'CoverPoolFactory: address cannot be 0');
  });

  it('Should NOT update governance to owner by governance', async () => {
    await expectRevert(coverPoolFactory.connect(governanceAccount).updateGovernance(ownerAddress), 'CoverPoolFactory: governance cannot be owner');
  });

  // test functions with owner access restriction
  it('Should update vars by owner', async () => {
    await coverPoolFactory.connect(ownerAccount).updateClaimManager(userAAddress);
    expect(await coverPoolFactory.claimManager()).to.equal(userAAddress);

    await coverPoolFactory.connect(ownerAccount).updateDeployGasMin(6000000);
    expect(await coverPoolFactory.deployGasMin()).to.equal(6000000);
  });

  it('Should NOT update claimManager by non-owner', async () => {
    await expect(coverPoolFactory.connect(userAAccount).updateClaimManager(userAAddress)).to.be.reverted;
  });

  it('Should add 2 new coverPools by owner', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_1, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, true, [consts.ASSET_1, consts.ASSET_2], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);
    expect((await coverPoolFactory.getCoverPoolAddresses()).length).to.equal(2);

    const coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_1));
    expect(await coverPool.name()).to.equal(consts.POOL_1);
    const coverPool2 = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_3));
    const [name2,,,assetList] = await coverPool2.getCoverPoolDetails();
    expect(name2).to.equal(consts.POOL_3);
    expect(assetList[0]).to.equal(consts.ASSET_1);
    expect(assetList[1]).to.equal(consts.ASSET_2);
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

  it('Should add and delete asset for open pool', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, true, [consts.ASSET_1, consts.ASSET_2, consts.ASSET_3], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);  

    const coverPoolAddr = await coverPoolFactory.coverPools(consts.POOL_3);
    const coverPool = CoverPool.attach(coverPoolAddr);
    expect(await coverPool.name()).to.equal(consts.POOL_3);

    await coverPoolFactory.deleteAsset(consts.POOL_3, consts.ASSET_2);
    const [,,,assetList, deletedAssetList] = await coverPool.getCoverPoolDetails();
    expect(assetList).to.deep.equal([consts.ASSET_1, consts.ASSET_3]);
    expect(deletedAssetList).to.deep.equal([consts.ASSET_2]);

    await expect(coverPoolFactory.addAsset(consts.POOL_3, consts.ASSET_2)).to.be.reverted;
    await coverPoolFactory.addAsset(consts.POOL_3, consts.ASSET_4);
    const [,,,assetListAfterAdd] = await coverPool.getCoverPoolDetails();
    expect(assetListAfterAdd).to.deep.equal([consts.ASSET_1, consts.ASSET_3, consts.ASSET_4]);
  });

  it('Should ONLY delete, NOT add asset for close pool', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, false, [consts.ASSET_1, consts.ASSET_2, consts.ASSET_3], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);  

    const coverPoolAddr = await coverPoolFactory.coverPools(consts.POOL_3);
    const coverPool = CoverPool.attach(coverPoolAddr);
    expect(await coverPool.name()).to.equal(consts.POOL_3);

    await coverPoolFactory.deleteAsset(consts.POOL_3, consts.ASSET_2);
    const [,,,assetList, deletedAssetList] = await coverPool.getCoverPoolDetails();
    expect(assetList).to.deep.equal([consts.ASSET_1, consts.ASSET_3]);
    expect(deletedAssetList).to.deep.equal([consts.ASSET_2]);

    await expect(coverPoolFactory.addAsset(consts.POOL_3, consts.ASSET_2)).to.be.reverted;
    await expect(coverPoolFactory.addAsset(consts.POOL_3, consts.ASSET_4)).to.be.reverted;
    const [,,,assetListAfterAdd] = await coverPool.getCoverPoolDetails();
    expect(assetListAfterAdd).to.deep.equal([consts.ASSET_1, consts.ASSET_3]);
  });

  it('Should NOT add new coverPool by userA', async () => {
    await expect(coverPoolFactory
      .connect(userAAccount)
      .createCoverPool(consts.ASSET_1, true, [consts.ASSET_1], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.be.reverted;
  });
});