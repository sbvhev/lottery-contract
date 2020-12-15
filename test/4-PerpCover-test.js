const { expect } = require('chai');
const { expectRevert, time, BN } = require('@openzeppelin/test-helpers');
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

// TODO: add test for the fee amounts, how to deal with decimal
describe('PerpCover', function() {
  const NAME = 'Pool2_0_DAI';
  const ETHER_UINT_10000 = ethers.utils.parseEther('10000');
  const ETHER_UINT_20 = ethers.utils.parseEther('20');
  const ETHER_UINT_10 = ethers.utils.parseEther('10');
  const ETHER_UINT_6 = ethers.utils.parseEther('6');
  const ETHER_UINT_4 = ethers.utils.parseEther('4');
  const ETHER_UINT_1 = ethers.utils.parseEther('1');
  const ETHER_UINT_DUST = ethers.utils.parseEther('0.0000000001');

  let startTimestamp, TIMESTAMP, TIMESTAMP_NAME, COLLATERAL;

  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, PerpCover, CoverERC20, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl;
  let claimManager, cover, dai;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, PerpCover, CoverERC20, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl} = await getImpls());
    claimManager = governanceAccount;

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'DAI');
    // use deployed stablecoin address for COVRT collateral
    COLLATERAL = dai.address;
  }); 

  beforeEach(async () => {
    const startTime = await time.latest();
    startTimestamp = startTime.toNumber();
    TIMESTAMP = startTimestamp + 1 * 24 * 60 * 60;
    TIMESTAMP_NAME = '2020_12_31';

    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, perpCoverImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.updateClaimManager(claimManager.getAddress());

    // add coverPool through coverPool factory
    await coverPoolFactory.createCoverPool(consts.POOL_2, [consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], COLLATERAL, [], []);
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));

    // init test account balances
    dai.mint(userAAddress, ETHER_UINT_10000);
    dai.mint(userBAddress, ETHER_UINT_10000);
    await dai.connect(userAAccount).approve(coverPool.address, ETHER_UINT_10000);
    await dai.connect(userBAccount).approve(coverPool.address, ETHER_UINT_10000);

    // add cover through coverPool
    const txA = await coverPool.connect(userAAccount).addPerpCover(COLLATERAL, ETHER_UINT_10);
    await txA.wait();
    const coverAddress = await coverPool.perpCoverMap(COLLATERAL);
    cover = PerpCover.attach(coverAddress);
  });

  it('Should initialize correct state variables', async function() {
    const [name, createdAt, collateral, claimNonce, claimCovTokens, noclaimCovToken] = await cover.getCoverDetails();
    expect(name).to.equal(NAME);
    expect(createdAt).to.gt(startTimestamp);
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
    const claimCovTokenAddress = await cover.claimCovTokenMap(consts.PROTOCOL_NAME);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    const createdAt = await cover.createdAt();
    const claimNonce = await coverPool.claimNonce();
    
    const computedClaimCovTokenAddress = await coverPoolFactory.getPerpCovTokenAddress(consts.POOL_2, createdAt, COLLATERAL, claimNonce, 'CLAIM_Binance');
    const computedNoclaimCovTokenAddress = await coverPoolFactory.getPerpCovTokenAddress(consts.POOL_2, createdAt, COLLATERAL, claimNonce, 'NOCLAIM');
    expect(claimCovTokenAddress).to.equal(computedClaimCovTokenAddress);
    expect(noclaimCovTokenAddress).to.equal(computedNoclaimCovTokenAddress);
  });

  it('Should redeem collateral without accepted claim', async function() {
    const collateralBalanceBefore = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10);

    const claimCovToken = CoverERC20.attach(await cover.claimCovTokens(0));
    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    expect(await claimCovToken.totalSupply()).to.equal(0);
    expect(await noclaimCovToken.totalSupply()).to.equal(0);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);
    const feeFactor = await cover.feeFactor();
    const fee = ETHER_UINT_10.sub(ETHER_UINT_10.mul(ETHER_UINT_1).div(feeFactor));
    expect(await dai.balanceOf(treasuryAddress)).to.equal(fee);
    expect(await dai.balanceOf(userAAddress)).to.equal(collateralBalanceBefore.add(ETHER_UINT_10).sub(fee));
  });

  it('Should redeem collateral(0 fee) without accepted claim', async function() {
    await coverPool.connect(governanceAccount).updateFees(0, 0, 1);
    await coverPool.connect(userBAccount).addPerpCover(COLLATERAL, ETHER_UINT_10);
    const collateralUserBBefore = await dai.balanceOf(userBAddress);
    const collateralTreasuryBefore = await dai.balanceOf(treasuryAddress);
    const claimCovToken = CoverERC20.attach(await cover.claimCovTokens(0));
    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    await cover.connect(userBAccount).redeemCollateral(await claimCovToken.balanceOf(userBAddress));

    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect((await dai.balanceOf(userBAddress)).sub(collateralUserBBefore.add(ETHER_UINT_10))).to.lt(ETHER_UINT_DUST);
    expect(await dai.balanceOf(treasuryAddress)).to.equal(collateralTreasuryBefore);
  });

  it('Should delete asset, mint, and redeem with active tokens only', async function() {
    await coverPool.deleteAsset(consts.PROTOCOL_NAME_2);
    await coverPool.connect(governanceAccount).updateFees(0, 0, 1);

    await coverPool.connect(userBAccount).addPerpCover(COLLATERAL, ETHER_UINT_20);
    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME));
    const deletedClaimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME_2));
    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    expect(await claimCovToken.balanceOf(userBAddress)).to.gt(ETHER_UINT_20);
    expect(await deletedClaimCovToken.balanceOf(userBAddress)).to.equal(0);
    const userBNoclaimBal = await noclaimCovToken.balanceOf(userBAddress);
    expect(userBNoclaimBal).to.gt(ETHER_UINT_20);

    const userBBal = await dai.balanceOf(userBAddress);
    await cover.connect(userBAccount).redeemCollateral(userBNoclaimBal);
    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(0);
    const feeFactor = await cover.feeFactor();
    const fee = ETHER_UINT_20.sub(ETHER_UINT_20.mul(ETHER_UINT_1).div(feeFactor));
    expect(await dai.balanceOf(userAAddress)).to.equal(userBBal.add(ETHER_UINT_20).sub(fee));
  });

  it('Should NOT redeem collateral with accepted claim', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10)).to.be.reverted;
  });

  it('Should NOT redeem claim and Noclaim before accepted claim', async function() {
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

  it('Should allow redeem partial claim and noclaim after enact 40% claim after claimRedeemDelay ends', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], [40, 20], 100, startTimestamp, 0);
    await txA.wait();

    const [,,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.claimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber());
    await time.advanceBlock();

    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME));
    const claimCovToken2 = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME_2));
    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemClaim();

    expect(await claimCovToken.totalSupply()).to.equal(0);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await claimCovToken2.totalSupply()).to.equal(0);
    expect(await claimCovToken2.balanceOf(userAAddress)).to.equal(0);
    expect(await noclaimCovToken.totalSupply()).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const feeFactor = await cover.feeFactor();
    const fee = ETHER_UINT_10.sub(ETHER_UINT_10.mul(ETHER_UINT_1).div(feeFactor));
    expect(await dai.balanceOf(userAAddress)).to.equal(aDaiBalance.add(ETHER_UINT_10).sub(fee));
  });

  it('Should NOT redeemClaim after enact if does not have claim token', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;
  });

  it('Should add perp cover for userB after 30 days and redeem correctly', async function() {
    const [feeNum,, feeDen,] = await coverPool.getRedeemFees();
    const feesPerDay = ETHER_UINT_1.mul(feeNum).div(feeDen).div(365);
    const daysInSec = 24 * 60 * 60;
    const monthInSec = 30 * daysInSec;
    const currentTime = await time.latest();
    await time.increaseTo(currentTime.toNumber() + monthInSec);
    await time.advanceBlock();

    await expect(coverPool.connect(userBAccount).addPerpCover(COLLATERAL, ETHER_UINT_20)).to.emit(coverPool, 'CoverAdded');

    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    const extraNoClaimForBMin = ETHER_UINT_20.mul(feesPerDay).div(ETHER_UINT_1).mul(30);
    const extraNoClaimForBMax = ETHER_UINT_20.mul(feesPerDay).div(ETHER_UINT_1).mul(31);
    const userBNoclaimBal = await noclaimCovToken.balanceOf(userBAddress);
    // user B should receive more covTokens than depositted amount to compensate the fees
    expect(userBNoclaimBal).to.gt(ETHER_UINT_20.add(extraNoClaimForBMin));
    expect(userBNoclaimBal).to.lt(ETHER_UINT_20.add(extraNoClaimForBMax));

    // user A redeem, A minted in period 0
    const treasuryDaiBal = await dai.balanceOf(treasuryAddress);
    const userADaiBal = await dai.balanceOf(userAAddress);
    const userBDaiBal = await dai.balanceOf(userBAddress);
    await cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10);
    const userADaiBalAfterA = await dai.balanceOf(userAAddress);
    const treasuryDaiBalAfterA = await dai.balanceOf(treasuryAddress);

    const feeFromUserAMin = ETHER_UINT_10.mul(feesPerDay).div(ETHER_UINT_1).mul(29);
    const feeFromUserAMax = ETHER_UINT_10.mul(feesPerDay).div(ETHER_UINT_1).mul(31);
    const feeFromUserBMin = ETHER_UINT_20.mul(feesPerDay).div(ETHER_UINT_1).div(daysInSec);
    const feeFromUserBMax = ETHER_UINT_20.mul(feesPerDay).div(ETHER_UINT_1);

    // User A will have no dust
    expect(userADaiBalAfterA.sub(userADaiBal)).to.gt(ETHER_UINT_10.sub(feeFromUserAMax));
    expect(userADaiBalAfterA.sub(userADaiBal)).to.lt(ETHER_UINT_10.sub(feeFromUserAMin));
    // fees received should be from both A and B, but less than total due to the buffer
    expect(treasuryDaiBalAfterA.sub(treasuryDaiBal)).to.gt(feeFromUserAMin);
    expect(treasuryDaiBalAfterA.sub(treasuryDaiBal)).to.lt(feeFromUserAMax);

    // redeem for user B, cover is empty
    await cover.connect(userBAccount).redeemCollateral(userBNoclaimBal);
    const userBDaiBalAfter = await dai.balanceOf(userBAddress);
    expect(userBDaiBalAfter.sub(userBDaiBal)).to.gt(ETHER_UINT_20.sub(feeFromUserBMax));
    expect(userBDaiBalAfter.sub(userBDaiBal)).to.lt(ETHER_UINT_20.sub(feeFromUserBMin));
    
    // last redeem, collect all to treasury
    expect(await dai.balanceOf(cover.address)).to.equal(0);
    expect((await dai.balanceOf(treasuryAddress)).sub(treasuryDaiBalAfterA)).to.gt(0);
  });

  it('Should allow redeem claim with multi-period mint users', async function() {
    const [feeNum,, feeDen,] = await coverPool.getRedeemFees();
    const feesPerDay = ETHER_UINT_1.mul(feeNum).div(feeDen).div(365);
    const daysInSec = 24 * 60 * 60;

    const currentTime = await time.latest();
    await time.increaseTo(currentTime.toNumber() + 3 * daysInSec);
    await time.advanceBlock();
    await expect(coverPool.connect(userBAccount).addPerpCover(COLLATERAL, ETHER_UINT_20)).to.emit(coverPool, 'CoverAdded');
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], [40, 20], 100, startTimestamp, 0);
    await txA.wait();
    const [,,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.claimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber());
    await time.advanceBlock();
    
    const feeFromUserAMin = ETHER_UINT_10.mul(feesPerDay).div(ETHER_UINT_1).mul(4); // 5 days fees
    const feeFromUserAMax = ETHER_UINT_10.mul(feesPerDay).div(ETHER_UINT_1).mul(6); // 5 days fees
    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME));
    const claimCovToken2 = CoverERC20.attach(await cover.claimCovTokenMap(consts.PROTOCOL_NAME_2));
    const noclaimCovToken = CoverERC20.attach(await cover.noclaimCovToken());
    const treaBal = await dai.balanceOf(treasuryAddress);

    // verify redeem User A
    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemClaim();
    const aDaiBalanceAfter = await dai.balanceOf(userAAddress);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await claimCovToken2.balanceOf(userAAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(aDaiBalanceAfter.sub(aDaiBalance)).to.gt(ETHER_UINT_10.sub(feeFromUserAMax));
    expect(aDaiBalanceAfter.sub(aDaiBalance)).to.lt(ETHER_UINT_10.sub(feeFromUserAMin));
    
    // verify redeem User B
    const feeFromUserBMin = ETHER_UINT_20.mul(feesPerDay).div(ETHER_UINT_1).mul(1); // 2 days fees
    const feeFromUserBMax = ETHER_UINT_20.mul(feesPerDay).div(ETHER_UINT_1).mul(3); // 2 days fees
    const bDaiBalance = await dai.balanceOf(userBAddress);
    await cover.connect(userBAccount).redeemClaim();
    const bDaiBalanceAfter = await dai.balanceOf(userBAddress);
    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect(await claimCovToken2.balanceOf(userBAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect(bDaiBalanceAfter.sub(bDaiBalance)).to.gt(ETHER_UINT_20.sub(feeFromUserBMax));
    expect(bDaiBalanceAfter.sub(bDaiBalance)).to.lt(ETHER_UINT_20.sub(feeFromUserBMin));

    // verify vaults and treasury
    expect(await claimCovToken.totalSupply()).to.equal(0);
    expect(await claimCovToken2.totalSupply()).to.equal(0);
    expect(await noclaimCovToken.totalSupply()).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);
    expect((await dai.balanceOf(treasuryAddress)).sub(treaBal)).to.gt(feeFromUserBMin.add(feeFromUserAMin));
    expect((await dai.balanceOf(treasuryAddress)).sub(treaBal)).to.lt(feeFromUserBMax.add(feeFromUserAMax));
  });
});