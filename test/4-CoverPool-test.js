const { expect } = require('chai');
const { expectRevert, time, BN } = require("@openzeppelin/test-helpers");
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('CoverPool', () => {
  const NEW_TIMESTAMP = 2556057500000;
  const NEW_TIMESTAMP_NAME = ethers.utils.formatBytes32String('2040_12_31');
  const INCIDENT_TIMESTAMP = 1580515200000;

  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl;
  let COLLATERAL, NEW_COLLATERAL, coverPoolFactory, coverPool, dai, weth;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    weth = await deployCoin(ethers, 'weth');

    // use deployed stablecoin address for collaterals
    COLLATERAL = dai.address;
    NEW_COLLATERAL = weth.address;
  }); 
  
  beforeEach(async () => {
    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.updateClaimManager(ownerAddress);

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(consts.POOL_2, consts.CAT, [consts.ASSET_1, consts.ASSET_2], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0]);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));
    await coverPool.connect(ownerAccount).updateExpiry(consts.ALLOWED_EXPIRYS[1], consts.ALLOWED_EXPIRY_NAMES[1], 1);
    await coverPool.connect(ownerAccount).updateExpiry(consts.ALLOWED_EXPIRYS[2], consts.ALLOWED_EXPIRY_NAMES[2], 1);

    // init test account balances
    dai.mint(userAAddress, 1000);
    await dai.connect(userAAccount).approve(coverPool.address, 1000);
    dai.mint(userBAddress, 1000);
    await dai.connect(userBAccount).approve(coverPool.address, 1000);
  });

  it('Should initialize correct state variables', async () => {
    const [name, category, isActive, assetList,, claimNonce, claimRedeemDelay, noclaimRedeemDelay, collaterals, expiries, allCovers, allActiveCovers] = await coverPool.getCoverPoolDetails();

    expect(name).to.equal(consts.POOL_2);
    expect(category).to.equal(consts.CAT);
    expect(isActive).to.equal(true);
    expect(claimNonce).to.equal(0);
    expect(claimRedeemDelay).to.equal(2 * 24 * 60 * 60);
    expect(noclaimRedeemDelay).to.equal(10 * 24 * 60 * 60);
    expect(assetList).to.deep.equal([consts.ASSET_1, consts.ASSET_2]);
    expect(collaterals).to.deep.equal([COLLATERAL]);
    expect(expiries).to.deep.equal(consts.ALLOWED_EXPIRYS);
    expect(allCovers.length).to.equal(0);
    expect(allActiveCovers.length).to.equal(0);
  });

  it('Should update state variables by the correct authority', async () => {
    await coverPool.connect(ownerAccount).updateCollateral(NEW_COLLATERAL, consts.DEPOSIT_RATIO, 2);
    expect(await coverPool.collaterals(1)).to.equal(NEW_COLLATERAL);
    const [, status] = await coverPool.collateralStatusMap(NEW_COLLATERAL);
    expect(status).to.equal(2);
    
    await coverPool.connect(ownerAccount).updateExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1);
    expect(await coverPool.expiries(consts.ALLOWED_EXPIRYS.length)).to.equal(NEW_TIMESTAMP);
    expect((await coverPool.expiryInfoMap(NEW_TIMESTAMP)).status).to.equal(1);

    await coverPool.connect(ownerAccount).setActive(false);
    expect(await coverPool.isActive()).to.equal(false);

    const newDelay = 10 * 24 * 60 * 60;
    await coverPool.connect(governanceAccount).updateClaimRedeemDelay(newDelay);
    expect(await coverPool.claimRedeemDelay()).to.equal(newDelay);

    await expect(coverPool.connect(governanceAccount).updateFees(0, 0)).to.be.reverted;

    await coverPool.connect(governanceAccount).updateFees(0, 1);
    const [feeNumerator, feeDenominator] = await coverPool.getRedeemFees();
    expect(feeNumerator).to.equal(0);
    expect(feeDenominator).to.equal(1);
  });

  it('Should NOT update state variables by the wrong authority', async () => {
    await expect(coverPool.connect(userAAccount).updateCollateral(NEW_COLLATERAL, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).updateExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).setActive(false)).to.be.reverted;
    await expect(coverPool.connect(ownerAccount).updateClaimRedeemDelay(10 * 24 * 60 * 60)).to.be.reverted;
  });

  it('Should delete asset from pool correctly', async () => {
    await expect(coverPool.deleteAsset(consts.ASSET_1)).to.emit(coverPool, 'AssetUpdated');
    const [,,,assetList, deletedAssetList] = await coverPool.getCoverPoolDetails();
    expect(assetList).to.deep.equal([consts.ASSET_2]);
    expect(deletedAssetList).to.deep.equal([consts.ASSET_1]);

    await expectRevert(coverPool.deleteAsset(consts.ASSET_1), "CoverPool: not active asset");
    await expectRevert(coverPool.deleteAsset(consts.ASSET_2), "CoverPool: only 1 asset");
  });

  it('Should add cover for userA and emit event', async () => {
    await expect(coverPool.connect(userAAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10)).to.emit(coverPool, 'CoverAdded')
    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should match cover with computed cover address', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);

    const claimNonce = await coverPool.claimNonce();
    const computedAddress = await coverPoolFactory.getCoverAddress(consts.POOL_2, consts.ALLOWED_EXPIRYS[1], COLLATERAL, claimNonce)
    expect(computedAddress).to.equal(coverAddress);
  });

  it('Should create new cover contract for diffrent expiries', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const txB = await coverPool.connect(userBAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[2], 10);
    await txB.wait();

    const lastActiveCover = await coverPool.activeCovers(1);
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);
  });

  it('Should add cover for userB on existing contract', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');
    
    const txB = await coverPool.connect(userBAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txB.wait();

    const lastActiveCover = await coverPool.activeCovers(0);
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);

    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should create new cover for userB on existing contract when accepted claim', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');

    const txB = await coverPool.connect(userBAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txB.wait();

    const lastActiveCover = await coverPool.activeCovers(0);
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);

    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should emit event and enactClaim if called by claimManager', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');
    expect(await coverPool.name()).to.equal(consts.POOL_2);
    expect(await coverPool.isActive()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);
  });

  it('Should NOT enactClaim if coverPool nonce not match', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1], [100], 100, INCIDENT_TIMESTAMP, 0);
    expect(await coverPool.name()).to.equal(consts.POOL_2);
    expect(await coverPool.isActive()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);

    await expect(coverPool.connect(userAAccount).enactClaim([consts.ASSET_1], [100], 100, INCIDENT_TIMESTAMP, 0)).to.be.reverted;
  });

  it('Should NOT enactClaim if have non active asset', async () => {
    await expectRevert(coverPool.enactClaim([consts.ASSET_1, consts.ASSET_3], [20, 40], 100, INCIDENT_TIMESTAMP, 0), "CoverPool: has non active asset");
  });
  
  it('Should NOT enactClaim if called by non-claimManager', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(userAAccount).enactClaim([consts.ASSET_1], [100], 100, INCIDENT_TIMESTAMP, 0)).to.be.reverted;
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce);
  });


  it('Should NOT add cover for userA for expired timestamp', async () => {
    await time.increaseTo(consts.ALLOWED_EXPIRYS[1]);
    await time.advanceBlock();

    await expect(coverPool.connect(userAAccount).addCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10)).to.be.reverted;
  });
});