const { expect } = require("chai");
const { time } = require("@openzeppelin/test-helpers");

const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe("ClaimManagement", function () {
  const BOGEY_PROTOCOL = ethers.utils.formatBytes32String("BOGEY");
  const EXPLOIT_ASSETS = [consts.ASSET_1_BYTES32];
  const DESC = "Binance is hacked.";
  const DAY = 24 * 3600;

  let timestamp;
  const state = {
    filed: 0,
    forceFiled: 1,
    validated: 2,
    invalidated: 3,
    accepted: 4,
    denied: 5,
  };
  let COLLATERAL;
  let ownerAccount, ownerAddress, auditorAccount, auditorAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl;
  let management, coverPool, dai, coverPoolFactory;

  before(async () => {
    timestamp = (await time.latest()).toNumber();
    ({ownerAccount, ownerAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, treasuryAddress);
    await coverPoolFactory.deployed();

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    await dai.mint(ownerAddress, ethers.utils.parseEther('5000'));
    COLLATERAL = dai.address;

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(consts.POOL_2, true, [consts.ASSET_1, consts.ASSET_2], COLLATERAL, consts.DEPOSIT_RATIO, consts.CM_TIMESTAMPS[0], consts.ALLOWED_EXPIRY_NAMES[0]);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));
    await coverPool.connect(ownerAccount).setExpiry(consts.CM_TIMESTAMPS[1], consts.ALLOWED_EXPIRY_NAMES[1], 1);

    const ClaimManagement = await ethers.getContractFactory("ClaimManagement");
    management = await ClaimManagement.deploy(
      dai.address,
      treasuryAddress,
      coverPoolFactory.address,
      ownerAddress
    );
    await management.deployed();
    
    // set claim manager in coverPool Factory
    await coverPoolFactory.setClaimManager(management.address);
    await dai.approve(management.address, await dai.balanceOf(ownerAddress));
  });

  it("Should deploy ClaimManagement correctly", async function () {
    expect(await management.treasury()).to.equal(treasuryAddress);
    expect(await management.coverPoolFactory()).to.equal(coverPoolFactory.address);
  });

  it("Should set vars correctly", async function () {
    let baseClaimFee = ethers.utils.parseEther("40");
    let forceClaimFee = ethers.utils.parseEther("500");
    let feeCurrency = dai.address;
    await management.connect(ownerAccount).setFeeAndCurrency(baseClaimFee, forceClaimFee, feeCurrency);
    expect(await management.feeCurrency()).to.equal(dai.address);
    expect(await management.isCVCMember(coverPool.address, ownerAddress)).to.equal(true);
  });

  it("Should add cvc to deployed cover pool" , async function () {
    await management.connect(ownerAccount).addCVCForPools([coverPool.address], [auditorAddress]);
    expect(await management.isCVCMember(coverPool.address, auditorAddress)).to.equal(true);
    expect(await management.isCVCMember(coverPool.address, ownerAddress)).to.equal(false);
  })

  // hasPendingClaim
  it("Should return false when no claims exist", async function () {
    expect(await management.hasPendingClaim(coverPool.address, 0)).to.equal(false);
    const noclaimDelay = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay.toNumber()).to.deep.equal(3 * DAY);
  });

  // fileClaim
  it("Should file a claim for incident correctly", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(ethers.utils.parseEther("40"));
    await expect(management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp + 5000), DESC, false).to.be.reverted;
    await expect(management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp - 10000000, DESC, false)).to.be.reverted;
    await expect(management.fileClaim(BOGEY_PROTOCOL, EXPLOIT_ASSETS, timestamp), DESC, false).to.be.reverted;

    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
    const noclaimDelay = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay.toNumber()).to.deep.equal(10 * DAY);
    const claim = await management.getCoverPoolClaims(coverPool.address, 0, 0);
    expect(claim.state).to.equal(state.filed);
    expect(claim.filedBy).to.equal(ownerAddress);
    expect(claim.feePaid).to.equal(ethers.utils.parseEther("40"));
    expect(claim.payoutRates).to.deep.equal([ethers.utils.parseEther("0")]);
    expect(await management.getCoverPoolClaims(coverPool.address, 0, 0)).to.exist;
    expect(await dai.balanceOf(ownerAddress)).to.equal(ethers.utils.parseEther("4960"));
  });

  it("Should return true for pending claim on coverPool", async function () {
    expect(await management.hasPendingClaim(coverPool.address, 0)).to.equal(true);
    const noclaimDelay = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay.toNumber()).to.deep.equal(10 * DAY);
  });

  it("Should return false for pending claim on non-existent pool", async function () {
    expect(await management.hasPendingClaim(coverPoolFactory.address, 0)).to.equal(false);
  });

  it("Should cost 80 dai to file next claim", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(ethers.utils.parseEther("80"));
    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
    expect(await dai.balanceOf(ownerAddress)).to.equal(ethers.utils.parseEther("4880"));
    let filedClaims = await management.getAllClaimsByState(coverPool.address, 0, state.filed);
    expect(filedClaims.length).to.equal(2);
  });

  it("Should file a forced claim", async function () {
    const userBal = await dai.balanceOf(ownerAddress);
    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, true);
    const noclaimDelay = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay.toNumber()).to.deep.equal(10 * DAY);
    expect(await dai.balanceOf(ownerAddress)).to.equal(userBal.sub(ethers.utils.parseEther("500")));
    const claim = await management.getCoverPoolClaims(coverPool.address, 0, 2);
    expect(claim.state).to.equal(state.forceFiled);
    expect(claim.filedBy).to.equal(ownerAddress);
    expect(claim.feePaid).to.equal(ethers.utils.parseEther("500"));
    expect(claim.payoutRates).to.deep.equal([ethers.utils.parseEther("0")]);

    // Should have (40 + 80 + 500) dai in management contract
    expect(await dai.balanceOf(management.address)).to.equal(ethers.utils.parseEther("620"));
  });

  // validateClaim
  it("Should NOT validate if condition is wrong", async function () {
    // validate zero address
    await expect(management.connect(ownerAccount).validateClaim(consts.ADDRESS_ZERO, 0, 0, true)).to.be.reverted;
    // nonce != claimNonce()
    await expect(management.connect(ownerAccount).validateClaim(coverPool.address, 1, 0, true)).to.be.reverted;
    // index >= coverPoolClaims length
    await expect(management.connect(ownerAccount).validateClaim(coverPool.address, 0, 5, true)).to.be.reverted;
    // validating a forcedClaim
    await expect(management.connect(ownerAccount).validateClaim(coverPool.address, 0, 2, true)).to.be.reverted;
  });

  // invalidated
  it("Should invalidate claim once", async function () {
    await management.connect(ownerAccount).validateClaim(coverPool.address, 0, 0, false);
    const claim = await management.getCoverPoolClaims(coverPool.address, 0, 0);
    expect(claim.state).to.equal(state.invalidated);
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(await dai.balanceOf(treasuryAddress)).to.equal(ethers.utils.parseEther("40"));

    await expect(management.connect(ownerAccount).validateClaim(coverPool.address, 0, 0, true)).to.be.reverted;
  });

  // validated
  it("Should validate claim", async function () {
    await management.connect(ownerAccount).validateClaim(coverPool.address, 0, 1, true);
    const claim = await management.getCoverPoolClaims(coverPool.address, 0, 1);
    expect(claim.state).to.equal(state.validated);
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(await management.baseClaimFee());
  });

  it("Should file and validate more claims for further testing", async function () {
    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
    await management.connect(ownerAccount).validateClaim(coverPool.address, 0, 3, true);

    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
    await management.connect(ownerAccount).validateClaim(coverPool.address, 0, 4, true);
  });
  // decideClaim
  it("Should NOT decideClaim if condition is wrong", async function () {
    // default CVC cannot call
    await expect(management.connect(ownerAccount).decideClaim(coverPool.address, 0, 1, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')])).to.be.reverted;
    // non-CVC cannot call
    await expect(management.connect(treasuryAccount).decideClaim(coverPool.address, 0, 1, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')])).to.be.reverted;
    // if deciding a claim for zero address
    await expect(management.connect(auditorAccount).decideClaim(consts.ADDRESS_ZERO, 0, 1, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')])).to.be.reverted;
    // if input nonce != coverPool nonce
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 1, 1, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')])).to.be.reverted;
    // if index >= length
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 10, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')])).to.be.reverted;
    // Should throw if claim is not pending for decideClaim
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 0, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')])).to.be.reverted;
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1.05')])).to.be.reverted;
    // if payoutNumerator <= 0 when accepting
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, timestamp, true, EXPLOIT_ASSETS, [0])).to.be.reverted;
  });

  // claim accepted
  it("Should accept claim", async function () {
    const ownerBal = await dai.balanceOf(ownerAddress);
    await management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, timestamp, true, EXPLOIT_ASSETS, [ethers.utils.parseEther('1')]);
    const claim = await management.getCoverPoolClaims(coverPool.address, 0, 1);
    expect(claim.state).to.equal(state.accepted);
    expect(claim.payoutRates[0]).to.equal(ethers.utils.parseEther('1'));
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(await dai.balanceOf(ownerAddress)).to.equal(ownerBal.add(ethers.utils.parseEther("80")));
  });

  it("Should file new claims under nonce = 1", async function () {
    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
    expect(await management.getCoverPoolClaims(coverPool.address, 1, 0)).to.exist;
  });

  it("Should NOT decideClaim throw if payoutNumerator != 0 when denying claim", async function () {
    await expect(management.connect(ownerAccount).decideClaim(coverPool.address, 1, 0, timestamp, false, EXPLOIT_ASSETS, [1], 100)).to.be.reverted;
  });

  // claim denied
  it("Should deny claim", async function () {
    await management.connect(ownerAccount).validateClaim(coverPool.address, 1, 0, true);
    await management.connect(auditorAccount).decideClaim(coverPool.address, 1, 0, 0, false, EXPLOIT_ASSETS, [0]);
    const claim = await management.getCoverPoolClaims(coverPool.address, 1, 0);
    expect(claim.state).to.equal(state.denied);
    expect(claim.payoutRates[0].toNumber()).to.equal(0);
  });
  
  it("Should return false for pending claim", async function () {
    expect(await management.hasPendingClaim(coverPool.address, 1)).to.equal(false);
    const noclaimDelay = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay.toNumber()).to.deep.equal(3 * DAY);
  });

  // edge cases
  it("Should file 2 new claims", async function () {
    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
    await management.fileClaim(consts.POOL_2, EXPLOIT_ASSETS, timestamp, DESC, false);
  });
  
  it("Should revert if try to validate claim with payoutNumerator > 0 after window passed", async function () {
    await time.increaseTo(consts.CM_TIMESTAMPS[1]);
    await time.advanceBlock();
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 1, 1, timestamp, true, EXPLOIT_ASSETS, [1], 1)).to.be.reverted;
  });

  it("Should deny claim if window passed", async function () {
    await management.connect(ownerAccount).validateClaim(coverPool.address, 1, 1, true);
    const noclaimDelay1 = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay1.toNumber()).to.deep.equal(10 * DAY);
    await management.connect(auditorAccount).decideClaim(coverPool.address, 1, 1, timestamp, false, EXPLOIT_ASSETS, [0]);
    const claim = await management.getCoverPoolClaims(coverPool.address, 1, 1);
    expect(claim.state).to.equal(state.denied);
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(claim.payoutRates[0]).to.equal(0);
    await management.connect(ownerAccount).validateClaim(coverPool.address, 1, 2, true);
    await management.connect(auditorAccount).decideClaim(coverPool.address, 1, 2, timestamp, true, EXPLOIT_ASSETS, [0]);
    const noclaimDelay = await coverPool.noclaimRedeemDelay();
    expect(noclaimDelay.toNumber()).to.deep.equal(3 * DAY);
  });
});