const { expect } = require('chai');
const { expectRevert, time, BN } = require('@openzeppelin/test-helpers');
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('Cover', function() {
  const NAME = 'Pool2_0_DAI_2020_12_31';
  const ETHER_UINT_10000 = ethers.utils.parseEther('10000');
  const ETHER_UINT_20 = ethers.utils.parseEther('20');
  const ETHER_UINT_10 = ethers.utils.parseEther('10');
  const ETHER_UINT_6 = ethers.utils.parseEther('6');
  const ETHER_UINT_4 = ethers.utils.parseEther('4');
  const ETHER_UINT_DUST = ethers.utils.parseEther('0.0000000001');

  let startTimestamp, TIMESTAMP, TIMESTAMP_NAME, COLLATERAL;

  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, Cover, CoverERC20, coverPoolImpl, coverImpl, coverERC20Impl;
  let claimManager, cover, dai;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, Cover, CoverERC20, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());
    claimManager = governanceAccount;

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'DAI');
    // use deployed stablecoin address for COVRT collateral
    COLLATERAL = dai.address;
  }); 

  beforeEach(async () => {
    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.updateClaimManager(claimManager.getAddress());
    // await coverPoolFactory.updateTreasury(treasuryAddress);
    
    const startTime = await time.latest();
    startTimestamp = startTime.toNumber();
    TIMESTAMP = startTimestamp + 366 * 24 * 60 * 60;
    TIMESTAMP_NAME = '2020_12_31';

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.createCoverPool(consts.POOL_2, [consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], COLLATERAL, [TIMESTAMP], [ethers.utils.formatBytes32String(TIMESTAMP_NAME)]);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));

    // init test account balances
    dai.mint(userAAddress, ETHER_UINT_10000);
    dai.mint(userBAddress, ETHER_UINT_10000);
    await dai.connect(userAAccount).approve(coverPool.address, ETHER_UINT_10000);
    await dai.connect(userBAccount).approve(coverPool.address, ETHER_UINT_10000);

    // add cover through coverPool
    const txA = await coverPool.connect(userAAccount).addCover(COLLATERAL, TIMESTAMP, ETHER_UINT_10);
    await txA.wait();
    const coverAddress = await coverPool.coverMap(COLLATERAL, TIMESTAMP);
    cover = Cover.attach(coverAddress);
  });

  it('Should initialize correct state variables', async function() {
    const [name, expiry, collateral, claimNonce, claimCovTokens, noclaimCovToken] = await cover.getCoverDetails();
    expect(name).to.equal(NAME);
    expect(expiry).to.equal(TIMESTAMP);
    expect(collateral).to.equal(COLLATERAL);
    expect(claimNonce).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokens[0]).symbol()).to.equal('CLAIM_Binance_' + NAME);
    expect(await CoverERC20.attach(claimCovTokens[1]).symbol()).to.equal('CLAIM_Curve_' + NAME);
    expect(await CoverERC20.attach(noclaimCovToken).symbol()).to.equal('NOCLAIM_' + NAME);
    expect(await CoverERC20.attach(claimCovTokens[0]).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[1]).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovToken).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[0]).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[1]).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovToken).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10);
  });

  // owner access tests
  it('Should match computed covToken addresses', async function() {
    const claimCovTokenAddress = await cover.claimCovTokens(0);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    const claimNonce = await coverPool.claimNonce();

    const computedClaimCovTokenAddress = await coverPoolFactory.getCovTokenAddress(consts.POOL_2, TIMESTAMP, COLLATERAL, claimNonce, 'CLAIM_Binance');
    const computedNoclaimCovTokenAddress = await coverPoolFactory.getCovTokenAddress(consts.POOL_2, TIMESTAMP, COLLATERAL, claimNonce.toNumber(), 'NOCLAIM');
    expect(claimCovTokenAddress).to.equal(computedClaimCovTokenAddress);
    expect(noclaimCovTokenAddress).to.equal(computedNoclaimCovTokenAddress);
  });

  it('Should delete asset, mint, and redeem with active tokens only', async function() {
    await coverPool.deleteAsset(consts.PROTOCOL_NAME_2);

    await coverPool.connect(userBAccount).addCover(COLLATERAL, TIMESTAMP, ETHER_UINT_20);
    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME));
    const deletedClaimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME_2));
    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);
    expect(await deletedClaimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);

    const userABal = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await deletedClaimCovToken.balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    const fees = await calFees(ETHER_UINT_10);
    expect(await dai.balanceOf(userAAddress)).to.equal(userABal.add(ETHER_UINT_10).sub(fees));
  });

  it('Should redeem collateral without accepted claim', async function() {
    const treasuryBalBefore = await dai.balanceOf(treasuryAddress);
    await cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10);

    const claimCovTokenAddress = await cover.claimCovTokens(0);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const treasuryBal = await dai.balanceOf(treasuryAddress);
    const fees = await calFees(ETHER_UINT_10);
    expect(treasuryBal.sub(treasuryBalBefore)).to.equal(fees);
  });

  it('Should redeem collateral(0 fee) without accepted claim', async function() {
    await coverPool.connect(governanceAccount).updateFees(0, 1);
    const collateralBalanceBefore = await dai.balanceOf(userAAddress);
    const collateralTreasuryBefore = await dai.balanceOf(treasuryAddress);
    await cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10);

    const claimCovTokenAddress = await cover.claimCovTokens(0);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(userAAddress)).to.equal(collateralBalanceBefore.add(ETHER_UINT_10));
    expect(await dai.balanceOf(treasuryAddress)).to.equal(collateralTreasuryBefore);
  });

  it('Should NOT redeem collateral with accepted claim', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10)).to.be.reverted;
  });

  it('Should NOT redeem collateral after cover expired', async function() {
    const timestamp = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10)).to.be.reverted;
  });

  it('Should NOT redeemCollateral after expire before wait period ends', async function() {
    const timestamp = await cover.expiry();
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber() + delay.toNumber() - ethers.BigNumber.from(10).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemCollateral(1)).to.be.reverted;
  });

  it('Should redeemCollateral after expire and after wait period ends', async function() {
    const timestamp = await cover.expiry();
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber() + delay.toNumber());
    await time.advanceBlock();

    await cover.connect(userAAccount).redeemCollateral(1);

    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);
  });

  it('Should NOT redeemCollateral after expire if does not hold noclaim covToken', async function() {
    const timestamp = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userBAccount).redeemCollateral(1)).to.be.reverted;
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10);
  });

  it('Should NOT redeemClaim before accepted claim', async function() {
    const timestamp = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemClaim()).to.be.reverted;
  });

  it('Should NOT redeemClaim after enact claim before redeemDelay ends', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    const aDaiBalance = await dai.balanceOf(userAAddress);
    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;

    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10);

    const claimCovTokenAddress = await cover.claimCovTokens(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
  });

  async function calFees(amount) {
    const [num, den] = await coverPool.getRedeemFees();
    const duration = await cover.duration();
    return amount.mul(num).div(den).mul(duration).div(365 * 24 * 3600);
  }

  it('Should allow redeem partial claim and noclaim after enact 40% claim after claimRedeemDelay ends', async function() {
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    const transferAmount = ETHER_UINT_6;
    await noclaimCovToken.connect(userAAccount).transfer(ownerAddress, transferAmount);
    const ownerRedeemable = transferAmount.mul(40).div(100);
    const userARedeemable = ETHER_UINT_6.add(ETHER_UINT_10.sub(transferAmount).mul(40).div(100));

    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], [40, 20], 100, startTimestamp, 0);
    await txA.wait();

    const [,,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.claimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber());
    await time.advanceBlock();

    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME));
    const claimCovToken2 = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME_2));
    const aDaiBalance = await dai.balanceOf(userAAddress);
    const userAClaimable = await cover.viewClaimable(userAAddress);
    expect(userAClaimable).to.equal(userARedeemable);
    await cover.connect(userAAccount).redeemClaim();
    const aDaiBalanceAfter = await dai.balanceOf(userAAddress);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await claimCovToken2.balanceOf(userAAddress)).to.equal(0);
    
    expect(await dai.balanceOf(cover.address)).to.equal(ownerRedeemable);
    const userAFees = await calFees(userARedeemable);
    expect(aDaiBalanceAfter.sub(aDaiBalance)).to.equal(userARedeemable.sub(userAFees));
    
    const ownerClaimable = await cover.viewClaimable(ownerAddress);
    expect(ownerClaimable).to.equal(ownerRedeemable);
    const ownerDaiBalance = await dai.balanceOf(ownerAddress);
    await cover.connect(ownerAccount).redeemClaim();
    const ownerDaiBalanceAfter = await dai.balanceOf(ownerAddress);
    expect(await noclaimCovToken.balanceOf(ownerAddress)).to.equal(0);

    expect(await noclaimCovToken.totalSupply()).to.equal(0);
    expect(await claimCovToken.totalSupply()).to.equal(0);
    expect(await claimCovToken2.totalSupply()).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const ownerFees = await calFees(ownerRedeemable);
    expect(ownerDaiBalanceAfter.sub(ownerDaiBalance)).to.equal(ownerRedeemable.sub(ownerFees));
  });

  it('Should allow redeemCollateral ONLY after enact and noclaimRedeemDelay if incident after expiry', async function() {
    const incidentTimestamp = await cover.expiry();

    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [40], 100, incidentTimestamp + 1, 0);
    await txA.wait();

    const [,,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber() * 24 * 60 * 60);
    await time.advanceBlock();

    // since incident happened after expiry, CLAIM token redeems fails
    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;

    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemCollateral(1);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);

    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const aBalAfter = await dai.balanceOf(userAAddress);
    const aFee = await calFees(ETHER_UINT_10);
    expect(aDaiBalance.add(ETHER_UINT_10).sub(aBalAfter.add(aFee))).to.equal(0);
  });

  it('Should NOT redeemClaim after enact if does not have claim token', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;
  });
});