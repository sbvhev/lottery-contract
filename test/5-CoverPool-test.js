const { expect } = require('chai');
const { expectRevert, time, BN } = require("@openzeppelin/test-helpers");
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('CoverPool', () => {
  const NEW_TIMESTAMP = 2556057500000;
  const NEW_TIMESTAMP_NAME = ethers.utils.formatBytes32String('2040_12_31');
  const INCIDENT_TIMESTAMP = 1580515200000;

  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl;
  let COLLATERAL, NEW_COLLATERAL, coverPoolFactory, coverPool, dai, weth;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    weth = await deployCoin(ethers, 'weth');

    // use deployed stablecoin address for collaterals
    COLLATERAL = dai.address;
    NEW_COLLATERAL = weth.address;
  }); 
  
  beforeEach(async () => {
    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, perpCoverImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.updateClaimManager(ownerAddress);

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(consts.POOL_2, [consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));

    // init test account balances
    dai.mint(userAAddress, 1000);
    await dai.connect(userAAccount).approve(coverPool.address, 1000);
    dai.mint(userBAddress, 1000);
    await dai.connect(userBAccount).approve(coverPool.address, 1000);
  });

  it('Should initialize correct state variables', async () => {
    const [name, isActive, assetList, claimNonce, claimRedeemDelay, noclaimRedeemDelay, rolloverPeriod, collaterals, expiries, allCovers, allActiveCovers] = await coverPool.getCoverPoolDetails();

    expect(name).to.equal(consts.POOL_2);
    expect(isActive).to.equal(true);
    expect(claimNonce).to.equal(0);
    expect(rolloverPeriod).to.equal(30 * 24 * 60 * 60);
    expect(claimRedeemDelay).to.equal(2 * 24 * 60 * 60);
    expect(noclaimRedeemDelay).to.equal(10 * 24 * 60 * 60);
    expect(assetList).to.deep.equal([consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2]);
    expect(collaterals).to.deep.equal([COLLATERAL]);
    expect(expiries).to.deep.equal(consts.ALLOWED_EXPIRYS);
    expect(allCovers.length).to.equal(0);
    expect(allActiveCovers.length).to.equal(0);
  });

  it('Should update state variables by the correct authority', async () => {
    await coverPool.connect(ownerAccount).updateCollateral(NEW_COLLATERAL, 2);
    expect(await coverPool.collaterals(1)).to.equal(NEW_COLLATERAL);
    expect(await coverPool.collateralStatusMap(NEW_COLLATERAL)).to.equal(2);
    
    await coverPool.connect(ownerAccount).updateExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1);
    expect(await coverPool.expiries(consts.ALLOWED_EXPIRYS.length)).to.equal(NEW_TIMESTAMP);
    expect((await coverPool.expiryInfoMap(NEW_TIMESTAMP)).status).to.equal(1);

    await coverPool.connect(ownerAccount).setActive(false);
    expect(await coverPool.isActive()).to.equal(false);

    const newDelay = 10 * 24 * 60 * 60;
    await coverPool.connect(governanceAccount).updateClaimRedeemDelay(newDelay);
    expect(await coverPool.claimRedeemDelay()).to.equal(newDelay);
    await coverPool.updateRolloverPeriod(newDelay);
    expect(await coverPool.rolloverPeriod()).to.equal(newDelay);

    await expect(coverPool.connect(governanceAccount).updateFees(0, 0, 0)).to.be.reverted;

    await coverPool.connect(governanceAccount).updateFees(0, 0, 1);
    const [perpFeeNum, expiryFeeNum, feeDenominator] = await coverPool.getRedeemFees();
    expect(perpFeeNum).to.equal(0);
    expect(expiryFeeNum).to.equal(0);
    expect(feeDenominator).to.equal(1);
  });

  it('Should NOT update state variables by the wrong authority', async () => {
    await expect(coverPool.connect(userAAccount).updateCollateral(NEW_COLLATERAL, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).updateExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).setActive(false)).to.be.reverted;
    await expect(coverPool.connect(ownerAccount).updateClaimRedeemDelay(10 * 24 * 60 * 60)).to.be.reverted;
  });

  it('Should add cover for userA and emit event', async () => {
    await expect(coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10)).to.emit(coverPool, 'CoverAdded')
    const coverAddress = await coverPool.coverWithExpiryMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should add perp cover for userA and userB and emit event', async () => {
    await expect(coverPool.connect(userAAccount).addPerpCover(COLLATERAL, 10)).to.emit(coverPool, 'CoverAdded')
    const coverAddress = await coverPool.perpCoverMap(COLLATERAL);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);

    const currentTime = await time.latest();
    const rolloverPeriod = await coverPool.rolloverPeriod();
    await time.increaseTo(currentTime.toNumber() + rolloverPeriod.toNumber());
    await time.advanceBlock();

    await expect(coverPool.connect(userBAccount).addPerpCover(COLLATERAL, 100)).to.emit(coverPool, 'CoverAdded');
    expect(await dai.balanceOf(coverAddress)).to.equal(110);
  });

  it('Should match cover with computed cover address', async () => {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const coverAddress = await coverPool.coverWithExpiryMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);

    const claimNonce = await coverPool.claimNonce();
    const computedAddress = await coverPoolFactory.getCoverAddress(consts.POOL_2, consts.ALLOWED_EXPIRYS[1], COLLATERAL, claimNonce)
    expect(computedAddress).to.equal(coverAddress);
  });

  it('Should create new cover contract for diffrent expiries', async () => {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const txB = await coverPool.connect(userBAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[2], 10);
    await txB.wait();

    const lastActiveCover = await coverPool.activeCovers(1);
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);
  });

  it('Should add cover for userB on existing contract', async () => {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');

    const txB = await coverPool.connect(userBAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txB.wait();

    const lastActiveCover = await coverPool.activeCovers(0);
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);

    const coverAddress = await coverPool.coverWithExpiryMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should create new cover for userB on existing contract when accepted claim', async () => {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');

    const txB = await coverPool.connect(userBAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txB.wait();

    const lastActiveCover = await coverPool.activeCovers(0);
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);

    const coverAddress = await coverPool.coverWithExpiryMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should emit event and enactClaim if called by claimManager', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');
    expect(await coverPool.name()).to.equal(consts.POOL_2);
    expect(await coverPool.isActive()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);
  });

  it('Should NOT enactClaim if coverPool nonce not match', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0);
    expect(await coverPool.name()).to.equal(consts.POOL_2);
    expect(await coverPool.isActive()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);

    await expect(coverPool.connect(userAAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0)).to.be.reverted;
  });
  
  it('Should NOT enactClaim if called by non-claimManager', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(userAAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0)).to.be.reverted;
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce);
  });


  it('Should NOT add cover for userA for expired timestamp', async () => {
    await time.increaseTo(consts.ALLOWED_EXPIRYS[1]);
    await time.advanceBlock();

    await expect(coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10)).to.be.reverted;
  });
});