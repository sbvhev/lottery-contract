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

  let startTimestamp, TIMESTAMP, TIMESTAMP_NAME, COLLATERAL;

  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, PerpCover, CoverWithExpiry, CoverERC20, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl;
  let claimManager, cover, dai;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, PerpCover, CoverWithExpiry, CoverERC20, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl} = await getImpls());
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
    const [name, rolloverPeriod, createdAt, collateral, claimNonce, claimCovTokens, noclaimCovToken] = await cover.getCoverDetails();
    expect(name).to.equal(NAME);
    expect(rolloverPeriod.toNumber()).to.equal(30 * 24 * 60 * 60); // 30 days
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
    await cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10);

    const claimCovTokenAddress = await cover.claimCovTokens(0);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);
    const [num, den] = await coverPool.getRedeemFees();
    expect(await dai.balanceOf(treasuryAddress)).to.deep.equal(ETHER_UINT_10.mul(num).div(den));
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

  it('Should NOT redeem claim and Noclaim before accepted claim', async function() {
    await expect(cover.connect(userAAccount).redeemNoclaim()).to.be.reverted;
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

    const claimCovTokenAddress = await cover.claimCovTokenMap(consts.PROTOCOL_NAME);
    const claimCovTokenAddress2 = await cover.claimCovTokenMap(consts.PROTOCOL_NAME_2);
    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemClaim();

    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);

    expect(await CoverERC20.attach(claimCovTokenAddress2).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress2).balanceOf(userAAddress)).to.equal(0);

    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_4);
    const [num, den] = await coverPool.getRedeemFees();
    expect(await dai.balanceOf(userAAddress)).to.equal(aDaiBalance.add(ETHER_UINT_6).sub(ETHER_UINT_6.mul(num).div(den)));
    
    const aDaiBalance2 = await dai.balanceOf(userAAddress);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    await cover.connect(userAAccount).redeemNoclaim();
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    
    expect(await dai.balanceOf(cover.address)).to.equal(0);
    expect(await dai.balanceOf(userAAddress)).to.equal(aDaiBalance2.add(ETHER_UINT_4).sub(ETHER_UINT_4.mul(num).div(den)));
  });

  it('Should NOT redeemClaim after enact if does not have claim token', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;
  });
});