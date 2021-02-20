const { expect } = require('chai');
const { expectRevert, time, BN } = require('@openzeppelin/test-helpers');
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('Cover', function() {
  const NAME = 'Pool2_0_DAI_2020_12_31';
  const ETHER_UINT_10000 = ethers.utils.parseEther('10000');
  const ETHER_UINT_20 = ethers.utils.parseEther('20');
  const ETHER_UINT_10 = ethers.utils.parseEther('10');
  const ETHER_UINT_6 = ethers.utils.parseEther('6');
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
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.setClaimManager(claimManager.getAddress());
    
    const startTime = await time.latest();
    startTimestamp = startTime.toNumber();
    TIMESTAMP = startTimestamp + 366 * 24 * 60 * 60;
    TIMESTAMP_NAME = '2020_12_31';

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.createCoverPool(consts.POOL_2, true, [consts.ASSET_1, consts.ASSET_2, consts.ASSET_3], COLLATERAL, consts.DEPOSIT_RATIO, TIMESTAMP, TIMESTAMP_NAME);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));

    // init test account balances
    await dai.mint(userAAddress, ETHER_UINT_10000);
    await dai.mint(userBAddress, ETHER_UINT_10000);
    await dai.connect(userAAccount).approve(coverPool.address, ETHER_UINT_10000);
    await dai.connect(userBAccount).approve(coverPool.address, ETHER_UINT_10000);

    // add cover through coverPool
    await coverPool.connect(userAAccount).addCover(
      COLLATERAL, TIMESTAMP, userAAddress,
      ETHER_UINT_10, ETHER_UINT_10, '0x'
    );
    const coverAddress = await coverPool.coverMap(COLLATERAL, TIMESTAMP);
    cover = Cover.attach(coverAddress);
    await cover.connect(userAAccount).collectFees();
  });

  async function calFees(amount, coverPassed = cover) {
    const feeRate = await coverPassed.feeRate();
    return amount.mul(feeRate).div(ethers.utils.parseEther('1'));
  }

  it('Should initialize correct state variables', async function() {
    const [noclaimCovToken, claimCovTokens, futureCovTokens] = await cover.getCovTokens();
    expect(await cover.name()).to.equal(NAME);
    expect(await cover.expiry()).to.equal(TIMESTAMP);
    expect(await cover.collateral()).to.equal(COLLATERAL);
    expect(await cover.mintRatio()).to.equal(consts.DEPOSIT_RATIO);
    expect(await cover.feeRate()).to.gt(consts.FEE_RATE);
    expect(await cover.feeRate()).to.lt(consts.FEE_RATE.mul(10).div(9));
    expect(await cover.claimNonce()).to.equal(0);
    expect(await CoverERC20.attach(futureCovTokens[0]).symbol()).to.equal('C_FUT0_' + NAME);
    expect(await CoverERC20.attach(claimCovTokens[0]).symbol()).to.equal('C_Binance_' + NAME);
    expect(await CoverERC20.attach(claimCovTokens[1]).symbol()).to.equal('C_Curve_' + NAME);
    expect(await CoverERC20.attach(noclaimCovToken).symbol()).to.equal('NC_' + NAME);
    expect(await CoverERC20.attach(claimCovTokens[0]).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[1]).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovToken).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[0]).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[1]).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovToken).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    const fees = await calFees(ETHER_UINT_10);
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10.sub(fees));
    expect(await dai.balanceOf(treasuryAddress)).to.equal(fees);
  });

  it('Should addCover flashMint by contract', async function() {
    const FlashCover = await ethers.getContractFactory('FlashCover');
    const flashCover = await FlashCover.deploy();
    await flashCover.deployed();
    await dai.mint(flashCover.address, ETHER_UINT_20);
    expect(await dai.balanceOf(flashCover.address)).to.equal(ETHER_UINT_20);
    await flashCover.addCover(coverPool.address, COLLATERAL, TIMESTAMP, flashCover.address, ETHER_UINT_10, ETHER_UINT_10, '0x12');
    expect(await dai.balanceOf(flashCover.address)).to.equal(ETHER_UINT_10);

    const [noclaimCovToken, claimCovTokens] = await cover.getCovTokens();
    expect(await CoverERC20.attach(claimCovTokens[0]).balanceOf(flashCover.address)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokens[1]).balanceOf(flashCover.address)).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(noclaimCovToken).balanceOf(flashCover.address)).to.equal(ETHER_UINT_10);
  });

  it('Should deploy Cover in two txs with CoverPool', async function() {
    const tx = await coverPoolFactory.createCoverPool(consts.POOL_3, true, [consts.ASSET_1, consts.ASSET_2, consts.ASSET_3], COLLATERAL, consts.DEPOSIT_RATIO, TIMESTAMP, TIMESTAMP_NAME, {gasLimit: 3000000});
    await tx;
    const coverPool2 = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_3));
    await dai.connect(userAAccount).approve(coverPool2.address, ETHER_UINT_10000);

    // revert cause deploy incomplete
    await expectRevert(coverPool2.connect(userAAccount).addCover(
      COLLATERAL, TIMESTAMP, userAAddress,
      ETHER_UINT_10, ETHER_UINT_10, '0x',
      {gasLimit: 2112841}
    ), 'CP: cover deploy incomplete');
    const coverIP = Cover.attach(await coverPool2.coverMap(COLLATERAL, TIMESTAMP));
    await expect(coverPool2.deployCover(COLLATERAL, TIMESTAMP)).to.emit(coverIP, 'CoverDeployCompleted');
    await coverPool2.connect(userAAccount).addCover(
      COLLATERAL, TIMESTAMP, userAAddress,
      ETHER_UINT_10, ETHER_UINT_10, '0x'
    );
    await cover.connect(userAAccount).collectFees();
  });

  // owner access tests
  it('Should match computed covToken addresses', async function() {
    const claimNonce = await cover.claimNonce();
    const [noclaimCovTokenAddress, claimCovTokens] = await cover.getCovTokens();
    const claimCovTokenAddress = claimCovTokens[0];

    const computedClaimCovTokenAddress = await coverPoolFactory.getCovTokenAddress(consts.POOL_2, TIMESTAMP, COLLATERAL, claimNonce, 'C_Binance_');
    const computedNoclaimCovTokenAddress = await coverPoolFactory.getCovTokenAddress(consts.POOL_2, TIMESTAMP, COLLATERAL, claimNonce, 'NC_');
    expect(claimCovTokenAddress).to.equal(computedClaimCovTokenAddress);
    expect(noclaimCovTokenAddress).to.equal(computedNoclaimCovTokenAddress);
  });

  it('Should add risk, convert, mint, and redeem with new active tokens only', async function() {
    await expect(coverPool.addRisk(consts.ASSET_4)).to.emit(cover, 'CovTokenCreated');
    await expect(coverPool.addRisk(consts.ASSET_5)).to.emit(cover, 'CovTokenCreated');
    const [noclaimCovTokenAddress, claimCovTokens, futureCovTokens] = await cover.getCovTokens();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    const futureCovToken = CoverERC20.attach(futureCovTokens[futureCovTokens.length - 1]);
    const middleFutureToken = CoverERC20.attach(futureCovTokens[futureCovTokens.length - 2]);
    const lastFutureToken = CoverERC20.attach(futureCovTokens[futureCovTokens.length - 3]);
    // 2nd to the last future token points to newly created claim token
    expect(await cover.futureCovTokenMap(lastFutureToken.address)).to.equal(claimCovTokens[claimCovTokens.length - 2]);
    expect(await cover.futureCovTokenMap(middleFutureToken.address)).to.equal(claimCovTokens[claimCovTokens.length - 1]);

    // verify convert for userA
    expect(await futureCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await lastFutureToken.balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    await cover.connect(userAAccount).convert([lastFutureToken.address, middleFutureToken.address]);
    expect(await lastFutureToken.balanceOf(userAAddress)).to.equal(0);
    expect(await middleFutureToken.balanceOf(userAAddress)).to.equal(0);
    expect(await futureCovToken.balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    
    await coverPool.connect(userBAccount).addCover(
      COLLATERAL, TIMESTAMP, userBAddress,
      ETHER_UINT_20, ETHER_UINT_20, '0x'
    );
    await cover.connect(userAAccount).collectFees();
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);
    for (let i = 0; i < claimCovTokens.length; i++) {
      const claimCovToken = CoverERC20.attach(claimCovTokens[i]);
      expect(await claimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);
      expect(await claimCovToken.balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    }
    expect(futureCovTokens.length).to.equal(3);
    expect(await futureCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);

    const userABal = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeem(ETHER_UINT_10);
    for (let i = 0; i < claimCovTokens.length; i++) {
      const claimCovToken = CoverERC20.attach(claimCovTokens[i]);
      expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    }
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await futureCovToken.balanceOf(userAAddress)).to.equal(0);
    const fees = await calFees(ETHER_UINT_10);
    expect(await dai.balanceOf(userAAddress)).to.equal(userABal.add(ETHER_UINT_10).sub(fees));
  });

  it('Should delete risk, mint, and redeem with active tokens only', async function() {
    await coverPool.deleteRisk(consts.ASSET_2);
    await expectRevert(coverPool.addRisk(consts.ASSET_2), "CP: deleted risk not allowed");

    await coverPool.connect(userBAccount).addCover(
      COLLATERAL, TIMESTAMP, userBAddress,
      ETHER_UINT_20, ETHER_UINT_20, '0x'
    );
    await cover.connect(userAAccount).collectFees();
    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.ASSET_1_BYTES32));
    const deletedClaimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.ASSET_2_BYTES32));
    const [noclaimCovTokenAddress] = await cover.getCovTokens();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);
    expect(await deletedClaimCovToken.balanceOf(userBAddress)).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20);

    const userABal = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeem(ETHER_UINT_10);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await deletedClaimCovToken.balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    const fees = await calFees(ETHER_UINT_10);
    expect(await dai.balanceOf(userAAddress)).to.equal(userABal.add(ETHER_UINT_10).sub(fees));
  });

  it('Should mint, and redeem correctly for non 1 deposit ratio', async function() {
    const ratio = 2;
    const tx = await coverPoolFactory.createCoverPool(consts.POOL_3, true, [consts.ASSET_1, consts.ASSET_2], COLLATERAL, consts.DEPOSIT_RATIO.mul(ratio), TIMESTAMP, TIMESTAMP_NAME);
    await tx;
    const coverPool2 = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_3));
    await dai.connect(userBAccount).approve(coverPool2.address, ETHER_UINT_10000);
    
    await coverPool2.connect(userBAccount).addCover(
      COLLATERAL, TIMESTAMP, userBAddress,
      ETHER_UINT_20, ETHER_UINT_20, '0x'
    );
    const coverAddress = await coverPool2.coverMap(COLLATERAL, TIMESTAMP);
    const cover2 = Cover.attach(coverAddress);
    await cover2.connect(userAAccount).collectFees();

    const claimCovToken = CoverERC20.attach(await cover2.claimCovTokenMap(consts.ASSET_1_BYTES32));
    const claimCovToken2 = CoverERC20.attach(await cover2.claimCovTokenMap(consts.ASSET_2_BYTES32));
    const [noclaimCovTokenAddress, , futureCovTokens] = await cover2.getCovTokens();
    const futureToken = CoverERC20.attach(futureCovTokens[futureCovTokens.length - 1]);
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20.mul(ratio));
    expect(await claimCovToken2.balanceOf(userBAddress)).to.equal(ETHER_UINT_20.mul(ratio));
    expect(await futureToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20.mul(ratio));
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_20.mul(ratio));

    const userBBal = await dai.balanceOf(userBAddress);
    await cover2.connect(userBAccount).redeem(ETHER_UINT_20);
    expect(await claimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_10.mul(ratio));
    expect(await claimCovToken2.balanceOf(userBAddress)).to.equal(ETHER_UINT_10.mul(ratio));
    expect(await noclaimCovToken.balanceOf(userBAddress)).to.equal(ETHER_UINT_10.mul(ratio));
    const fees = await calFees(ETHER_UINT_10, cover2);
    expect(await dai.balanceOf(userBAddress)).to.equal(userBBal.add(ETHER_UINT_10).sub(fees));
  });

  it('Should redeem collateral without accepted claim', async function() {
    await verifyredeem(userAAddress, ETHER_UINT_10);
  });

  it('Should redeem collateral with accepted claim with all tokens', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.ASSET_1_BYTES32], [ethers.utils.parseEther('1')], startTimestamp, 0);
    await txA.wait();

    await verifyredeem(userAAddress, ETHER_UINT_10);
  });

  async function verifyredeem(address, amount) {
    const treasuryBalBefore = await dai.balanceOf(treasuryAddress);
    await cover.connect(userAAccount).redeem(amount);
    const [noclaimCovTokenAddress, claimCovTokens] = await cover.getCovTokens();
    const claimCovTokenAddress = claimCovTokens[0];
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).totalSupply()).to.equal(0);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(address)).to.equal(0);
    expect(await CoverERC20.attach(noclaimCovTokenAddress).balanceOf(address)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const treasuryBal = await dai.balanceOf(treasuryAddress);
    expect(treasuryBal.sub(treasuryBalBefore)).to.equal(0);
  }

  it('Should redeem collateral after cover expired with all tokens', async function() {
    const expiry = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(expiry).toNumber());
    await time.advanceBlock();

    await verifyredeem(userAAddress, ETHER_UINT_10);
  });

  it('Should NOT redeem if dont have all tokens', async function() {
    const [noclaimCovTokenAddress, claimCovTokens] = await cover.getCovTokens();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    const balance = await noclaimCovToken.balanceOf(userAAddress);
    await noclaimCovToken.connect(userAAccount).transfer(userBAddress, balance);

    await expect(cover.connect(userAAccount).redeem(ETHER_UINT_10)).to.be.reverted;
  });

  it('Should redeem after expire and after wait period ends', async function() {
    const expiry = await cover.expiry();
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(expiry).toNumber() + delay.toNumber());
    await time.advanceBlock();

    await cover.connect(userAAccount).redeem(ETHER_UINT_10);

    const [noclaimCovTokenAddress] = await cover.getCovTokens();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    expect(await noclaimCovToken.totalSupply()).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);
  });

  it('Should NOT redeem after expire if does not hold noclaim covToken', async function() {
    const expiry = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(expiry).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userBAccount).redeem(1)).to.be.reverted;
    const fees = await calFees(ETHER_UINT_10);
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10.sub(fees));
  });

  it('Should NOT redeemClaim before accepted claim', async function() {
    const expiry = await cover.expiry();
    await time.increaseTo(ethers.BigNumber.from(expiry).toNumber());
    await time.advanceBlock();

    await expect(cover.connect(userAAccount).redeemClaim()).to.be.reverted;
  });

  it('Should NOT redeemClaim after enact claim before redeemDelay ends', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.ASSET_1_BYTES32], [ethers.utils.parseEther('1')], startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;
    const fees = await calFees(ETHER_UINT_10);
    expect(await dai.balanceOf(cover.address)).to.equal(ETHER_UINT_10.sub(fees));

    const [, claimCovTokens] = await cover.getCovTokens();
    const claimCovTokenAddress = claimCovTokens[0];
    expect(await CoverERC20.attach(claimCovTokenAddress).totalSupply()).to.equal(ETHER_UINT_10);
    expect(await CoverERC20.attach(claimCovTokenAddress).balanceOf(userAAddress)).to.equal(ETHER_UINT_10);
  });

  it('Should allow redeem partial claim and noclaim after enact 40% claim after defaultRedeemDelay ends', async function() {
    const [noclaimCovTokenAddress] = await cover.getCovTokens();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    const transferAmount = ETHER_UINT_6;
    await noclaimCovToken.connect(userAAccount).transfer(ownerAddress, transferAmount);
    const ownerRedeemable = transferAmount.mul(40).div(100);
    const userARedeemable = ETHER_UINT_6.add(ETHER_UINT_10.sub(transferAmount).mul(40).div(100));

    const txA = await coverPool.connect(claimManager).enactClaim([consts.ASSET_1_BYTES32, consts.ASSET_2_BYTES32], [ethers.utils.parseEther('0.4'), ethers.utils.parseEther('0.2')], startTimestamp, 0);
    await txA.wait();

    const [,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber());
    await time.advanceBlock();

    const claimCovToken = CoverERC20.attach(await cover.claimCovTokenMap(consts.ASSET_1_BYTES32));
    const claimCovToken2 = CoverERC20.attach(await cover.claimCovTokenMap(consts.ASSET_2_BYTES32));
    const aDaiBalance = await dai.balanceOf(userAAddress);
    const userAClaimable = await cover.viewClaimable(userAAddress);
    expect(userAClaimable).to.equal(userARedeemable);
    await cover.connect(userAAccount).redeemClaim();
    const aDaiBalanceAfter = await dai.balanceOf(userAAddress);
    expect(await claimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await claimCovToken2.balanceOf(userAAddress)).to.equal(0);

    const userAFees = await calFees(userARedeemable);
    expect(aDaiBalanceAfter.sub(aDaiBalance)).to.equal(userARedeemable.sub(userAFees));

    const fees = (await calFees(ownerRedeemable)).add(1);
    expect(await dai.balanceOf(cover.address)).to.equal(ownerRedeemable.sub(fees));
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

    const ownerFees = (await calFees(ownerRedeemable)).add(1);
    expect(ownerDaiBalanceAfter.sub(ownerDaiBalance)).to.equal(ownerRedeemable.sub(ownerFees));
  });

  it('Should allow redeem ONLY after enact and noclaimRedeemDelay if incident after expiry', async function() {
    const expiry = await cover.expiry();

    const txA = await coverPool.connect(claimManager).enactClaim([consts.ASSET_1_BYTES32], [ethers.utils.parseEther('0.4')], expiry + 1, 0);
    await txA.wait();

    const [,,,, claimEnactedTimestamp] = await coverPool.getClaimDetails(0);
    const delay = await coverPool.noclaimRedeemDelay();
    await time.increaseTo(ethers.BigNumber.from(claimEnactedTimestamp).toNumber() + delay.toNumber() * 24 * 60 * 60);
    await time.advanceBlock();

    // since incident happened after expiry, CLAIM token redeems fails
    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;

    const aDaiBalance = await dai.balanceOf(userAAddress);
    await cover.connect(userAAccount).redeem(ETHER_UINT_10);
    const [noclaimCovTokenAddress] = await cover.getCovTokens();
    const noclaimCovToken = CoverERC20.attach(noclaimCovTokenAddress);
    expect(await noclaimCovToken.totalSupply()).to.equal(0);
    expect(await noclaimCovToken.balanceOf(userAAddress)).to.equal(0);
    expect(await dai.balanceOf(cover.address)).to.equal(0);

    const aBalAfter = await dai.balanceOf(userAAddress);
    const aFee = await calFees(ETHER_UINT_10);
    expect(aDaiBalance.add(ETHER_UINT_10).sub(aBalAfter.add(aFee))).to.equal(0);
  });

  it('Should NOT redeemClaim after enact if does not have claim token', async function() {
    const txA = await coverPool.connect(claimManager).enactClaim([consts.ASSET_1_BYTES32], [ethers.utils.parseEther('1')], startTimestamp, 0);
    await txA.wait();

    await expect(cover.connect(userBAccount).redeemClaim()).to.be.reverted;
  });
});