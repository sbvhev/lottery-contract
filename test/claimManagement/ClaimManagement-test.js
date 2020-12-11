const { expect } = require("chai");
const { time } = require("@openzeppelin/test-helpers");

const { deployCoin, consts, getAccounts, getImpls} = require('../testHelper');

describe("ClaimManagement", function () {
  const BOGEY_PROTOCOL = ethers.utils.formatBytes32String("BOGEY");

  const timestamp = Math.round(new Date().getTime() / 1000);
  // allowed timestamps: [1/1/2020, 31/12/2050, 1/1/2100] UTC
  const TIMESTAMPS = [1580515200000, 2556057600000, 4105123200000];
  const state = {
    filed: 0,
    forceFiled: 1,
    validated: 2,
    invalidated: 3,
    accepted: 4,
    denied: 5,
  };
  let COLLATERAL;
  let ownerAccount, ownerAddress, auditorAccount, auditorAddress, treasuryAccount, treasuryAddress, governanceAccount, governanceAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl;
  let management, coverPool, dai, coverPoolFactory;

  before(async () => {
    ({ownerAccount, ownerAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, perpCoverImpl, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, perpCoverImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    await dai.mint(ownerAddress, ethers.utils.parseEther('5000'));
    COLLATERAL = dai.address;

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(consts.POOL_2, [consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], COLLATERAL, TIMESTAMPS, consts.ALLOWED_EXPIRY_NAMES);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));

    const ClaimManagement = await ethers.getContractFactory("ClaimManagement");
    management = await ClaimManagement.deploy(
      governanceAddress,
      consts.ADDRESS_ZERO,
      treasuryAddress,
      coverPoolFactory.address
    );
    await management.deployed();
    
    // set claim manager in coverPool Factory
    await coverPoolFactory.updateClaimManager(management.address);
    await dai.approve(management.address, await dai.balanceOf(ownerAddress));
  });

  it("Should deploy ClaimManagement correctly", async function () {
    expect(await management.governance()).to.equal(governanceAddress);
    expect(await management.auditor()).to.equal(consts.ADDRESS_ZERO);
    expect(await management.treasury()).to.equal(treasuryAddress);
    expect(await management.coverPoolFactory()).to.equal(coverPoolFactory.address);
    expect(await management.isAuditorVoting()).to.equal(false);
  });

  it("Should set vars correctly", async function () {
    let baseClaimFee = ethers.utils.parseEther("40");
    let forceClaimFee = ethers.utils.parseEther("500");
    let feeCurrency = dai.address;
    await management.connect(governanceAccount).setFeeAndCurrency(baseClaimFee, forceClaimFee, feeCurrency);
    expect(await management.feeCurrency()).to.equal(dai.address);
    
    await management.setAuditor(auditorAddress);
    expect(await management.isAuditorVoting()).to.equal(true);
    expect(await management.auditor()).to.equal(auditorAddress);
  });

  // fileClaim
  it("Should file a claim for incident correctly", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(ethers.utils.parseEther("40"));
    await expect(management.fileClaim(coverPool.address, consts.POOL_2, timestamp + 5000)).to.be.reverted;
    await expect(management.fileClaim(coverPool.address,consts.POOL_2,timestamp - 10000000)).to.be.reverted;
    await expect(management.fileClaim(consts.ADDRESS_ZERO, consts.POOL_2, timestamp)).to.be.reverted;
    await expect(management.fileClaim(coverPool.address, BOGEY_PROTOCOL, timestamp)).to.be.reverted;

    await management.fileClaim(coverPool.address, consts.POOL_2, timestamp);
    const claim = await management.coverPoolClaims(coverPool.address, 0, 0);
    expect(claim.state).to.equal(state.filed);
    expect(claim.filedBy).to.equal(ownerAddress);
    expect(claim.feePaid).to.equal(ethers.utils.parseEther("40"));
    expect(claim.payoutNumerator).to.equal(0);
    expect(claim.payoutDenominator).to.equal(1);
    expect(await management.coverPoolClaims(coverPool.address, 0, 0)).to.exist;
    expect(await dai.balanceOf(ownerAddress)).to.equal(ethers.utils.parseEther("4960"));
  });

  it("Should cost 80 dai to file next claim", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(ethers.utils.parseEther("80"));
    await management.fileClaim(coverPool.address, consts.POOL_2, timestamp);
    expect(await dai.balanceOf(ownerAddress)).to.equal(ethers.utils.parseEther("4880"));
    let filedClaims = await management.getAllClaimsByState(coverPool.address, 0, state.filed);
    expect(filedClaims.length).to.equal(2);
  });

  // forceFileClaim
  it("Should NOT allow force filing when condition not right", async function () {
    await management.setAuditor(consts.ADDRESS_ZERO);
    await expect(management.forceFileClaim(coverPool.address, consts.POOL_2, timestamp)).to.be.reverted;
    await management.setAuditor(auditorAddress);
    await expect(management.forceFileClaim(consts.ADDRESS_ZERO, consts.POOL_2, timestamp)).to.be.reverted;
  });

  it("Should file a forced claim", async function () {
    const userBal = await dai.balanceOf(ownerAddress);
    await management.forceFileClaim(coverPool.address,consts.POOL_2,timestamp);
    expect(await dai.balanceOf(ownerAddress)).to.equal(userBal.sub(ethers.utils.parseEther("500")));
    const claim = await management.coverPoolClaims(coverPool.address, 0, 2);
    expect(claim.state).to.equal(state.forceFiled);
    expect(claim.filedBy).to.equal(ownerAddress);
    expect(claim.feePaid).to.equal(ethers.utils.parseEther("500"));
    expect(claim.payoutNumerator).to.equal(0);
    expect(claim.payoutDenominator).to.equal(1);

    // Should have (40 + 80 + 500) dai in management contract
    expect(await dai.balanceOf(management.address)).to.equal(ethers.utils.parseEther("620"));
  });

  // validateClaim
  it("Should NOT validate if condition is wrong", async function () {
    // error to validate when !isAuditorVoting
    await management.setAuditor(consts.ADDRESS_ZERO);
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 0, false)).to.be.reverted;
    await management.setAuditor(auditorAddress);

    // validate zero address
    await expect(management.connect(governanceAccount).validateClaim(consts.ADDRESS_ZERO, 0, 0, true)).to.be.reverted;
    // nonce != claimNonce()
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 1, 0, true)).to.be.reverted;
    // index >= coverPoolClaims length
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 5, true)).to.be.reverted;
    // validating a forcedClaim
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 2, true)).to.be.reverted;
  });

  // invalidated
  it("Should invalidate claim once", async function () {
    await management.connect(governanceAccount).connect(governanceAccount).validateClaim(coverPool.address, 0, 0, false);
    const claim = await management.coverPoolClaims(coverPool.address, 0, 0);
    expect(claim.state).to.equal(state.invalidated);
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(await dai.balanceOf(treasuryAddress)).to.equal(ethers.utils.parseEther("40"));

    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 0, true)).to.be.reverted;
  });

  // validated
  it("Should validate claim", async function () {
    await management.connect(governanceAccount).validateClaim(coverPool.address, 0, 1, true);
    const claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.state).to.equal(state.validated);
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(await management.baseClaimFee());
  });

  it("Should file and validate more claims for further testing", async function () {
    await management.fileClaim(coverPool.address, consts.POOL_2, timestamp);
    await management.connect(governanceAccount).validateClaim(coverPool.address, 0, 3, true);

    await management.fileClaim(coverPool.address, consts.POOL_2, timestamp);
    await management.connect(governanceAccount).validateClaim(coverPool.address, 0, 4, true);
  });
  // decideClaim
  it("Should NOT decideClaim if condition is wrong", async function () {
    // owner decideClaim when isAuditorVoting
    await expect(management.connect(ownerAccount).decideClaim(coverPool.address, 0, 1, true, 100, 100)).to.be.reverted;
    // if auditor decideClaim when !isAuditorVoting
    await management.setAuditor(consts.ADDRESS_ZERO);
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, true, 100, 100)).to.be.reverted;
    await management.setAuditor(auditorAddress);
    // if deciding a claim for zero address
    await expect(management.connect(auditorAccount).decideClaim(consts.ADDRESS_ZERO, 0, 1, true, 100, 100)).to.be.reverted;
    // if input nonce != coverPool nonce
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 1, 1, true, 100, 100)).to.be.reverted;
    // if index >= length
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 10, true, 100, 100)).to.be.reverted;
    // Should throw if claim is not pending for decideClaim
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 0, true, 100, 100)).to.be.reverted;
    // if payoutNumerator != payoutDenominator when allowPartialClaim == false
    await management.setPartialClaimStatus(false);
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, true, 95, 100)).to.be.reverted;
    // if payoutNumerator > payoutDenominator
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, true, 105, 100)).to.be.reverted;
    // if payoutNumerator <= 0 when accepting
    await expect(management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, true, 0, 100)).to.be.reverted;
  });

  // claim accepted
  it("Should accept claim", async function () {
    const ownerBal = await dai.balanceOf(ownerAddress);
    await management.connect(auditorAccount).decideClaim(coverPool.address, 0, 1, true, 100, 100);
    const claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.state).to.equal(state.accepted);
    expect(claim.payoutNumerator / claim.payoutDenominator).to.equal(1);
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(await dai.balanceOf(ownerAddress)).to.equal(ownerBal.add(ethers.utils.parseEther("80")));
  });

  it("Should file new claims under nonce = 1", async function () {
    await management.fileClaim(coverPool.address, consts.POOL_2, timestamp);
    expect(await management.coverPoolClaims(coverPool.address, 1, 0)).to.exist;
  });
  
  it("Should NOT validateClaim when auditor is not voting", async function () {
    await management.setAuditor(consts.ADDRESS_ZERO);
    expect(await management.isAuditorVoting()).to.equal(false);
    expect(await management.auditor()).to.equal(consts.ADDRESS_ZERO);
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 1, 0, true)).to.be.reverted;
  });

  it("Should NOT decideClaim throw if payoutNumerator != 0 when denying claim", async function () {
    await expect(management.connect(ownerAccount).decideClaim(coverPool.address, 1, 0, false, 1, 100)).to.be.reverted;
  });

  // claim denied
  it("Should deny claim", async function () {
    await management.connect(governanceAccount).decideClaim(coverPool.address, 1, 0, false, 0, 100);
    const claim = await management.coverPoolClaims(coverPool.address, 1, 0);
    expect(claim.state).to.equal(state.denied);
    expect(claim.payoutNumerator).to.equal(0);
    expect(claim.payoutDenominator).to.equal(1);
  });

  // edge cases
  it("Should file 2 new claims", async function () {
    await management.fileClaim(coverPool.address,consts.POOL_2,timestamp);
    await management.fileClaim(coverPool.address,consts.POOL_2,timestamp);
    await time.increaseTo(consts.TIMESTAMPS[1]);
    await time.advanceBlock();
  });

  it("Should revert if try to validate claim with payoutNumerator > 0 after window passed", async function () {
    await expect(management.connect(governanceAccount).decideClaim(coverPool.address, 1, 1, true, 1, 1)).to.be.reverted;
  });

  it("Should deny claim if window passed and claimIsAccepted = false", async function () {
    await management.connect(governanceAccount).decideClaim(coverPool.address, 1, 1, false, 0, 1);
    const claim = await management.coverPoolClaims(coverPool.address, 1, 1);
    expect(claim.state).to.equal(state.denied);
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(claim.payoutNumerator).to.equal(0);
  });

  it("Should deny claim if window passed even if pass in true for claimIsAccepted", async function () {
    await management.connect(governanceAccount).decideClaim(coverPool.address, 1, 2, true, 0, 1);
  });
});