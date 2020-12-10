const { expect } = require('chai');
const { expectRevert, time, BN } = require("@openzeppelin/test-helpers");
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('CoverPool', function() {
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
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(consts.PROTOCOL_NAME, [consts.PROTOCOL_NAME], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.PROTOCOL_NAME));

    // init test account balances
    dai.mint(userAAddress, 1000);
    await dai.connect(userAAccount).approve(coverPool.address, 1000);
    dai.mint(userBAddress, 1000);
    await dai.connect(userBAccount).approve(coverPool.address, 1000);
  });

  it('Should initialize correct state variables', async function() {
    expect(await coverPool.name()).to.equal(consts.PROTOCOL_NAME);
    expect(await coverPool.active()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(0);
    expect(await coverPool.claimRedeemDelay()).to.equal(2 * 24 * 60 * 60);
    expect(await coverPool.noclaimRedeemDelay()).to.equal(10 * 24 * 60 * 60);
    expect(await coverPool.expiriesLength()).to.equal(consts.ALLOWED_EXPIRYS.length);
    expect(await coverPool.expiries(0)).to.equal(consts.ALLOWED_EXPIRYS[0]);
    expect(await coverPool.collateralsLength()).to.equal(1);
    expect(await coverPool.collaterals(0)).to.equal(COLLATERAL);
  });

  it('Should update state variables by the correct authority', async function() {
    await coverPool.connect(ownerAccount).updateCollateral(NEW_COLLATERAL, 2);
    expect(await coverPool.collateralsLength()).to.equal(2);
    expect(await coverPool.collaterals(1)).to.equal(NEW_COLLATERAL);
    expect(await coverPool.collateralStatusMap(NEW_COLLATERAL)).to.equal(2);
    
    await coverPool.connect(ownerAccount).updateExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1);
    expect(await coverPool.expiriesLength()).to.equal(consts.ALLOWED_EXPIRYS.length + 1);
    expect(await coverPool.expiries(consts.ALLOWED_EXPIRYS.length)).to.equal(NEW_TIMESTAMP);
    expect((await coverPool.expiryInfoMap(NEW_TIMESTAMP)).status).to.equal(1);

    await coverPool.connect(ownerAccount).setActive(false);
    expect(await coverPool.active()).to.equal(false);

    const newDelay = 10 * 24 * 60 * 60;
    await coverPool.connect(governanceAccount).updateClaimRedeemDelay(newDelay);
    expect(await coverPool.claimRedeemDelay()).to.equal(newDelay);

    await expect(coverPool.connect(governanceAccount).updateFees(0, 0)).to.be.reverted;

    await coverPool.connect(governanceAccount).updateFees(0, 1);
    const [redeemFeeNumerator, redeemFeeDenominator] = await coverPool.getRedeemFees();
    expect(redeemFeeNumerator).to.equal(0);
    expect(redeemFeeDenominator).to.equal(1);
  });

  it('Should NOT update state variables by the wrong authority', async function() {
    await expect(coverPool.connect(userAAccount).updateCollateral(NEW_COLLATERAL, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).updateExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).setActive(false)).to.be.reverted;
    await expect(coverPool.connect(ownerAccount).updateClaimRedeemDelay(10 * 24 * 60 * 60)).to.be.reverted;
  });

  it('Should add cover for userA', async function() {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should match cover with computed cover address', async function() {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);

    const claimNonce = await coverPool.claimNonce();
    const computedAddress = await coverPoolFactory.getCoverAddress(consts.PROTOCOL_NAME, consts.ALLOWED_EXPIRYS[1], COLLATERAL, claimNonce)
    expect(computedAddress).to.equal(coverAddress);
  });

  it('Should create new cover contract for diffrent expiries', async function() {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();
    const txB = await coverPool.connect(userBAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[2], 10);
    await txB.wait();

    const activeCoversLength = await coverPool.activeCoversLength();
    expect(activeCoversLength).to.equal(2);
  });

  it('Should add cover for userB on existing contract', async function() {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');

    const txB = await coverPool.connect(userBAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txB.wait();
    const activeCoversLength = await coverPool.activeCoversLength();
    expect(activeCoversLength).to.equal(1);

    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should create new cover for userB on existing contract when accepted claim', async function() {
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');

    const txB = await coverPool.connect(userBAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10);
    await txB.wait();
    const activeCoversLength = await coverPool.activeCoversLength();
    expect(activeCoversLength).to.equal(1);

    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.equal(10);
  });

  it('Should emit event and enactClaim if called by claimManager', async function() {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimAccepted');
    expect(await coverPool.name()).to.equal(consts.PROTOCOL_NAME);
    expect(await coverPool.active()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);
  });

  it('Should NOT enactClaim if coverPool nonce not match', async function() {
    const oldClaimNonce = await coverPool.claimNonce();
    await coverPool.connect(ownerAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0);
    expect(await coverPool.name()).to.equal(consts.PROTOCOL_NAME);
    expect(await coverPool.active()).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);

    await expect(coverPool.connect(userAAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0)).to.be.reverted;
  });
  
  it('Should NOT enactClaim if called by non-claimManager', async function() {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(userAAccount).enactClaim([consts.PROTOCOL_NAME], [100], 100, INCIDENT_TIMESTAMP, 0)).to.be.reverted;
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce);
  });


  it('Should NOT add cover for userA for expired timestamp', async function() {
    await time.increaseTo(consts.ALLOWED_EXPIRYS[1]);
    await time.advanceBlock();

    await expect(coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, consts.ALLOWED_EXPIRYS[1], 10)).to.be.reverted;
  });
});