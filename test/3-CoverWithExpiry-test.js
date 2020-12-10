const { expect } = require('chai');
const { time, BN } = require("@openzeppelin/test-helpers");
const testHelper = require('./testHelper');

// TODO: add test for the fee amounts, how to deal with decimal
describe('CoverWithExpiry', function() {
  const PROTOCOL_NAME = ethers.utils.formatBytes32String('CURVE');
  const NAME = 'CURVE_0_DAI_2020_12_31';
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  const ETHER_UINT_10000 = ethers.utils.parseEther("10000");
  const ETHER_UINT_20 = ethers.utils.parseEther("20");
  const ETHER_UINT_10 = ethers.utils.parseEther("10");
  const ETHER_UINT_6 = ethers.utils.parseEther("6");
  const ETHER_UINT_4 = ethers.utils.parseEther("4");

  let startTimestamp, TIMESTAMP, TIMESTAMP_NAME, COLLATERAL;
  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress;
  let governanceAccount, governanceAddress, treasuryAccount, treasuryAddress, claimManager;
  let CoverPoolFactory, CoverPool, coverPoolImpl, CoverWithExpiry, coverImpl, CoverERC20, coverERC20Impl;
  let cover, dai;

  before(async () => {
    // get test accounts
    const accounts = await ethers.getSigners();
    [ ownerAccount, userAAccount, userBAccount, governanceAccount, treasuryAccount, treasuryAccount ] = accounts;
    ownerAddress = await ownerAccount.getAddress();
    userAAddress = await userAAccount.getAddress();
    userBAddress = await userBAccount.getAddress();
    governanceAddress = await governanceAccount.getAddress();
    treasuryAddress = await treasuryAccount.getAddress();
    claimManager = await governanceAccount;

    // get main contracts
    CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
    CoverPool = await ethers.getContractFactory('CoverPool');
    CoverWithExpiry = await ethers.getContractFactory('CoverWithExpiry');
    CoverERC20 = await ethers.getContractFactory('CoverERC20');

    // deploy stablecoins to local blockchain emulator
    dai = await testHelper.deployCoin(ethers, 'DAI');

    // use deployed stablecoin address for COVRT collateral
    COLLATERAL = dai.address;

    // deploy CoverPool contract
    coverPoolImpl = await CoverPool.deploy();
    await coverPoolImpl.deployed();

    // deploy Cover contract
    coverImpl = await CoverWithExpiry.deploy();
    await coverImpl.deployed();

    // deploy CoverERC20 contract
    coverERC20Impl = await CoverERC20.deploy();
    await coverERC20Impl.deployed();
  }); 

  beforeEach(async () => {
    const startTime = await time.latest();
    startTimestamp = startTime.toNumber();
    TIMESTAMP = startTimestamp + 1 * 24 * 60 * 60;
    TIMESTAMP_NAME = '2020_12_31';

    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.updateClaimManager(claimManager.getAddress());
    // await coverPoolFactory.updateTreasury(treasuryAddress);

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.createCoverPool(PROTOCOL_NAME, [PROTOCOL_NAME], COLLATERAL, [TIMESTAMP], [ethers.utils.formatBytes32String(TIMESTAMP_NAME)]);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(PROTOCOL_NAME));

    // init test account balances
    dai.mint(userAAddress, ETHER_UINT_10000);
    dai.mint(userBAddress, ETHER_UINT_10000);
    await dai.connect(userAAccount).approve(coverPool.address, ETHER_UINT_10000);
    await dai.connect(userBAccount).approve(coverPool.address, ETHER_UINT_10000);

    // add cover through coverPool
    const txA = await coverPool.connect(userAAccount).addCoverWithExpiry(COLLATERAL, TIMESTAMP, ETHER_UINT_10);
    await txA.wait();
    const coverAddress = await coverPool.coverMap(COLLATERAL, TIMESTAMP);
    cover = CoverWithExpiry.attach(coverAddress);
  });

  it('Should initialize correct state variables', async function() {
    expect(await cover.expiry()).to.equal(TIMESTAMP);
    expect(await cover.collateral()).to.equal(COLLATERAL);
    expect(await cover.claimNonce()).to.equal(0);
    expect(await cover.name()).to.equal(NAME);
    const claimCovTokenAddress = await cover.claimCovTokens(0);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(claimCovTokenAddress).symbol()).to.equal("CLAIM_" + NAME);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).symbol()).to.equal("NOCLAIM_" + NAME);
    expect(claimCovTokenAddress).to.not.equal(ADDRESS_ZERO);
    expect(noclaimCovTokenAddress).to.not.equal(ADDRESS_ZERO);
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10);
  });

  // owner access tests
  it('Should match computed covToken addresses', async function() {
    const claimCovTokenAddress = await cover.claimCovTokens(0);
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    const claimNonce = await coverPool.claimNonce();
    
    const computedClaimCovTokenAddress = await coverPoolFactory.getCovTokenAddress(PROTOCOL_NAME, TIMESTAMP, COLLATERAL, claimNonce, true);
    const computedNoclaimCovTokenAddress = await coverPoolFactory.getCovTokenAddress(PROTOCOL_NAME, TIMESTAMP, COLLATERAL, claimNonce.toNumber(), false);
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
    const txA = await coverPool.connect(claimManager).enactClaim([PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10)).to.be.reverted;
  });

  it('Should NOT redeem collateral after cover expired', async function() {
    const timestamp = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemCollateral(ETHER_UINT_10)).to.be.reverted;
  });

  it('Should NOT redeemNoclaim before expire', async function() {
    await expect(cover.connect(userAAccount).redeemNoclaim()).to.be.reverted;
  });

  it('Should NOT redeemNoclaim after expire before wait period ends', async function() {
    const timestamp = await cover.expiry();
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber() + delay.toNumber() - ethers.BigNumber.from(10).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemNoclaim()).to.be.reverted;
  });

  it('Should redeemNoclaim after expire and after wait period ends', async function() {
    const timestamp = await cover.expiry();
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber() + delay.toNumber());
    await time.advanceBlock();

    await cover.connect(userAAccount).redeemNoclaim();

    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);
  });

  it('Should NOT redeemNoclaim after expire if does not hold noclaim covToken', async function() {
    const timestamp = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userBAccount).redeemNoclaim()).to.be.reverted;
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10);
  });

  it('Should NOT redeemClaim before accepted claim', async function() {
    const timestamp = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemClaim()).to.be.reverted;
  });

  it('Should NOT redeemClaim after enact claim before redeemDelay ends', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    const aDaiBalance = await dai.balanceOf(userAAddress);
    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;

    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10);

    const claimCovTokenAddress = await cover.claimCovTokens(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
  });

  it('Should allow redeem partial claim and noclaim after enact 40% claim after claimRedeemDelay ends', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([PROTOCOL_NAME], [40], 100, startTimestamp, 0);
    await txA.wait();

    const [,,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.claimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber() * 24 * 60 * 60);
    await time.advanceBlock();

    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemClaim();

    const claimCovTokenAddress = await cover.claimCovTokens(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);

    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_6);
    const [num, den] = await coverPool.getRedeemFees();
    expect(await dai.balanceOf(userAAddress)).to.equal(aDaiBalance.add(ETHER_UINT_4).sub(ETHER_UINT_4.mul(num).div(den)));

    const aDaiBalance2 = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemNoclaim();
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);

    expect(await dai.balanceOf(cover.address)).to.equal(0);
    expect(await dai.balanceOf(userAAddress)).to.equal(aDaiBalance2.add(ETHER_UINT_6).sub(ETHER_UINT_6.mul(num).div(den)));
  });

  it('Should allow redeem noclaim ONLY after enact and noclaimRedeemDelay if incident after expiry', async function() {
    const incidentTimestamp = await cover.expiry();
    // const delay = await coverPool.noclaimRedeemDelay();
    // await time.increaseTo(ethers.BigNumber.from(timestamp).toNumber() + delay.toNumber());

    const txA = await coverPool.connect(claimManager).enactClaim([PROTOCOL_NAME], [40], 100, incidentTimestamp + 1, 0);
    await txA.wait();

    const [,,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber() * 24 * 60 * 60);
    await time.advanceBlock();

    // since incident happened after expiry, CLAIM token redeems fails
    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;

    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeemNoclaim();
    const noclaimCovTokenAddress = await cover.noclaimCovToken();
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(userAAddress)).to.equal(0);

    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const [num, den] = await coverPool.getRedeemFees();
    expect(await dai.balanceOf(userAAddress)).to.equal(aDaiBalance.add(ETHER_UINT_10).sub(ETHER_UINT_10.mul(num).div(den)));
  });

  it('Should NOT redeemClaim after enact if does not have claim token', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([PROTOCOL_NAME], [100], 100, startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;
  });
});