const { expect } = require("chai");
const { time } = require("@openzeppelin/test-helpers");

const testHelper = require('../testHelper');
const { ZERO_ADDRESS } = require("@openzeppelin/test-helpers/src/constants");

xdescribe("ClaimManagement", function () {
  const ZERO_ADDR = ethers.constants.AddressZero;
  const BINANCE_PROTOCOL = ethers.utils.formatBytes32String("Binance");
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
  let TIMESTAMP, TIMESTAMP_NAME, COLLATERAL;
  let CoverPool, coverPoolImpl, coverImpl, coverERC20Impl;
  var management, coverPool, dai, coverPoolFactory;
  var ownerAccount,
    ownerAddress,
    auditorAccount,
    auditorAddress,
    treasuryAccount,
    treasuryAddress,
    governanceAccount,
    governanceAddress;

  before(async () => {
    const accounts = await ethers.getSigners();
    [
      ownerAccount,
      auditorAccount,
      treasuryAccount,
      governanceAccount,
    ] = accounts;
    ownerAddress = await ownerAccount.getAddress();
    auditorAddress = await auditorAccount.getAddress();
    treasuryAddress = await treasuryAccount.getAddress();
    governanceAddress = await governanceAccount.getAddress();

    // get main contracts
    CoverPool = await ethers.getContractFactory('CoverPool');
    const Cover = await ethers.getContractFactory('Cover');
    const CoverERC20 = await ethers.getContractFactory('CoverERC20');

    // deploy CoverPool contract
    coverPoolImpl = await CoverPool.deploy();
    await coverPoolImpl.deployed();

    // deploy Cover contract
    coverImpl = await Cover.deploy();
    await coverImpl.deployed();

    // deploy CoverERC20 contract
    coverERC20Impl = await CoverERC20.deploy();
    await coverERC20Impl.deployed();

    const startTime = await time.latest();
    const startTimestamp = startTime.toNumber();
    TIMESTAMP = startTimestamp + 1 * 24 * 60 * 60;
    TIMESTAMP_NAME = '2020_12_31';

    // deploy coverPool factory
    const CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();

    // deploy stablecoins to local blockchain emulator
    dai = await testHelper.deployCoin(ethers, 'DAI');
    await dai.mint(ownerAddress, ethers.utils.parseEther("5000"));

    // use deployed stablecoin address for COVRT collateral
    COLLATERAL = dai.address;

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(BINANCE_PROTOCOL, [BINANCE_PROTOCOL], COLLATERAL, [TIMESTAMP], [ethers.utils.formatBytes32String(TIMESTAMP_NAME)]);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(BINANCE_PROTOCOL));

    const ClaimManagement = await ethers.getContractFactory("ClaimManagement");
    management = await ClaimManagement.deploy(
      governanceAddress,
      ZERO_ADDR,
      treasuryAddress,
      coverPoolFactory.address
    );
    await management.deployed();
    
    // set claim manager in coverPool Factory
    await coverPoolFactory.updateClaimManager(management.address);
  });

  it("Should deploy ClaimManagement and set governance, auditor(set to 0x0), treasury, and factory", async function () {
    expect(await management.governance()).to.equal(governanceAddress);
    expect(await management.auditor()).to.equal(ZERO_ADDR);
    expect(await management.treasury()).to.equal(treasuryAddress);
    expect(await management.coverPoolFactory()).to.equal(
      coverPoolFactory.address
    );
  });

  it("Should approve claim management for balance", async function () {
    await dai.approve(management.address, await dai.balanceOf(ownerAddress));
    expect(await dai.allowance(ownerAddress, management.address)).to.equal(
      await dai.balanceOf(ownerAddress)
    );
  });

  it("Should set feeCurrency to dai", async function () {
    let baseClaimFee = ethers.utils.parseEther("10");
    let forceClaimFee = ethers.utils.parseEther("500");
    let feeCurrency = dai.address;
    await management
      .connect(governanceAccount)
      .setFeeAndCurrency(baseClaimFee, forceClaimFee, feeCurrency);
    expect(await management.feeCurrency()).to.equal(dai.address);
  });
  it("Should not rely on auditor since address is set to 0x0", async function () {
    expect(await management.isAuditorVoting()).to.equal(false);
    expect(await management.auditor()).to.equal(ZERO_ADDR);
  });
  it("Should set auditor", async function () {
    await management.setAuditor(auditorAddress);
    expect(await management.isAuditorVoting()).to.equal(true);
    expect(await management.auditor()).to.equal(auditorAddress);
  });
  // fileClaim
  it("Should throw if filing a claim for incident in the future", async function () {
    await expect(
      management.fileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp + 5000)
    ).to.be.reverted;
  });
  it("Should throw if filing a claim for incident more than 14 days ago", async function () {
    await expect(
      management.fileClaim(
        coverPool.address,
        BINANCE_PROTOCOL,
        timestamp - 10000000
      )
    ).to.be.reverted;
  });
  it("Should throw if filing a claim for 0 address", async function () {
    await expect(management.fileClaim(ZERO_ADDR, BINANCE_PROTOCOL, timestamp))
      .to.be.reverted;
  });
  it("Should throw if coverPool name doesn't match address", async function () {
    await expect(
      management.fileClaim(coverPool.address, BOGEY_PROTOCOL, timestamp)
    ).to.be.reverted;
  });
  it("Should cost 10 dai to file claim", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(
      ethers.utils.parseEther("10")
    );
  });
  it("Should file a normal claim", async function () {
    await management.fileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp);
  });
  it("Should have correct claim values", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 0, 0);
    expect(claim.state).to.equal(state.filed);
    expect(claim.filedBy).to.equal(ownerAddress);
    expect(claim.feePaid).to.equal(ethers.utils.parseEther("10"));
    expect(claim.payoutNumerator).to.equal(0);
    expect(claim.payoutDenominator).to.equal(1);
  });
  it("Should be mapped under nonce = 0", async function () {
    expect(await management.coverPoolClaims(coverPool.address, 0, 0)).to.exist;
  });
  it("Should deduct 10 dai from claim filer", async function () {
    expect(await dai.balanceOf(ownerAddress)).to.equal(
      ethers.utils.parseEther("4990")
    );
  });
  it("Should cost 20 dai to file next claim", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(
      ethers.utils.parseEther("20")
    );
  });
  it("Should file another normal claim", async function () {
    await management.fileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp);
  });
  it("Should deduct 20 dai from claim filer", async function () {
    expect(await dai.balanceOf(ownerAddress)).to.equal(
      ethers.utils.parseEther("4970")
    );
  });
  it("Should have both claims under filed", async function () {
    let filedClaims = await management.getAllClaimsByState(
      coverPool.address,
      0,
      state.filed
    );
    expect(filedClaims.length).to.equal(2);
  });
  // forceFileClaim
  it("Should throw when forceFileClaim if !isAuditorVoting", async function () {
    await management.setAuditor(ZERO_ADDR);
    await expect(
      management.forceFileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp)
    ).to.be.reverted;
    await management.setAuditor(auditorAddress);
  });
  it("Should NOT allow force filing a claim for 0 address", async function () {
    await expect(
      management.forceFileClaim(ZERO_ADDR, BINANCE_PROTOCOL, timestamp)
    ).to.be.reverted;
  });
  it("Should file a forced claim", async function () {
    await management.forceFileClaim(
      coverPool.address,
      BINANCE_PROTOCOL,
      timestamp
    );
  });
  it("Should deduct 500 dai from claim filer", async function () {
    expect(await dai.balanceOf(ownerAddress)).to.equal(
      ethers.utils.parseEther("4470")
    );
  });
  it("Should have correct force claim values", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 0, 2);
    expect(claim.state).to.equal(state.forceFiled);
    expect(claim.filedBy).to.equal(ownerAddress);
    expect(claim.feePaid).to.equal(ethers.utils.parseEther("500"));
    expect(claim.payoutNumerator).to.equal(0);
    expect(claim.payoutDenominator).to.equal(1);
  });
  it("Should have 530(10 + 20 + 500) dai in management contract", async function () {
    expect(await dai.balanceOf(management.address)).to.equal(
      ethers.utils.parseEther("530")
    );
  });
  // validateClaim
  it("Should throw if try to validate when !isAuditorVoting", async function () {
    await management.setAuditor(ZERO_ADDR);
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 0, false)).to.be
      .reverted;
    await management.setAuditor(auditorAddress);
  });
  it("Should throw if try to validate zero address", async function () {
    await expect(management.connect(governanceAccount).validateClaim(ZERO_ADDR, 0, 0, true)).to.be
      .reverted;
  });
  it("Should throw if nonce != claimNonce()", async function () {
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 1, 0, true)).to.be
      .reverted;
  });
  it("Should throw if index >= coverPoolClaims length", async function () {
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 5, true)).to.be
      .reverted;
  });
  it("Should not allow validating a forcedClaim", async function () {
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 2, true)).to.be
      .reverted;
  });
  // invalidated
  it("Should invalidate claim", async function () {
    await management.connect(governanceAccount).connect(governanceAccount).validateClaim(coverPool.address, 0, 0, false);
  });
  it("Should be in invalidated state", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 0, 0);
    expect(claim.state).to.equal(state.invalidated);
  });
  it("Should have a decidedTimestamp", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 0, 0);
    expect(claim.decidedTimestamp).to.greaterThan(0);
  });
  it("Should send feePaid (10) to treasury", async function () {
    expect(await dai.balanceOf(treasuryAddress)).to.equal(
      ethers.utils.parseEther("10")
    );
  });
  it("Should throw if trying to validate claim that is already validated", async function () {
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 0, true)).to.be
      .reverted;
  });
  it("Should throw if claim is not pending for validateClaim", async function () {
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 0, 0, true)).to.be
      .reverted;
  });
  // validated
  it("Should validate claim", async function () {
    await management.connect(governanceAccount).validateClaim(coverPool.address, 0, 1, true);
    const claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.state).to.equal(state.validated);
  });
  it("Should resetClaimFee to baseClaimFee when claim is validated", async function () {
    expect(await management.getCoverPoolClaimFee(coverPool.address)).to.equal(
      await management.baseClaimFee()
    );
  });
  it("Should file and validate more claims for further testing", async function () {
    await management.fileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp);
    await management.connect(governanceAccount).validateClaim(coverPool.address, 0, 3, true);

    await management.fileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp);
    await management.connect(governanceAccount).validateClaim(coverPool.address, 0, 4, true);
  });
  // decideClaim
  it("Should throw if owner decideClaim when isAuditorVoting", async function () {
    await expect(
      management
        .connect(ownerAccount)
        .decideClaim(coverPool.address, 0, 1, true, 100, 100)
    ).to.be.reverted;
  });
  it("Should throw if auditor decideClaim when !isAuditorVoting", async function () {
    await management.setAuditor(ZERO_ADDR);
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 0, 1, true, 100, 100)
    ).to.be.reverted;
    await management.setAuditor(auditorAddress);
  });
  it("Should throw if deciding a claim for zero address", async function () {
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(ZERO_ADDR, 0, 1, true, 100, 100)
    ).to.be.reverted;
  });
  it("Should throw if input nonce != coverPool nonce", async function () {
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 1, 1, true, 100, 100)
    ).to.be.reverted;
  });
  it("Should throw if index >= length", async function () {
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 0, 10, true, 100, 100)
    ).to.be.reverted;
  });
  it("Should throw if claim is not pending for decideClaim", async function () {
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 0, 0, true, 100, 100)
    ).to.be.reverted;
  });
  it("Should throw if payoutNumerator != payoutDenominator when allowPartialClaim == false", async function () {
    await management.setPartialClaimStatus(false);
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 0, 1, true, 95, 100)
    ).to.be.reverted;
  });
  it("Should throw if payoutNumerator > payoutDenominator", async function () {
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 0, 1, true, 105, 100)
    ).to.be.reverted;
  });
  it("Should throw if payoutNumerator <= 0 when accepting", async function () {
    await expect(
      management
        .connect(auditorAccount)
        .decideClaim(coverPool.address, 0, 1, true, 0, 100)
    ).to.be.reverted;
  });
  // claim accepted
  it("Should accept claim", async function () {
    await management
      .connect(auditorAccount)
      .decideClaim(coverPool.address, 0, 1, true, 100, 100);
    let claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.payoutNumerator / claim.payoutDenominator).to.equal(1);
  });
  it("Should be in accepted state", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.state).to.equal(state.accepted);
  });
  it("Should have payoutNumerator/payoutDenominator = 1", async function () {
    var claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.payoutNumerator / claim.payoutDenominator).to.equal(1);
  });
  it("Should have decidedTimestamp", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 0, 1);
    expect(claim.decidedTimestamp).to.greaterThan(0);
  });
  it("Should refund feePaid to first claim filer", async function () {
    expect(await dai.balanceOf(ownerAddress)).to.equal(
      ethers.utils.parseEther("4470")
    );
  });
  it("Should remove auditor", async function () {
    await management.setAuditor(ZERO_ADDR);
    expect(await management.isAuditorVoting()).to.equal(false);
    expect(await management.auditor()).to.equal(ZERO_ADDR);
  });
  it("Should file new claims under nonce = 1", async function () {
    await management.fileClaim(coverPool.address, BINANCE_PROTOCOL, timestamp);
    expect(await management.coverPoolClaims(coverPool.address, 1, 0)).to.exist;
  });
  it("Should throw if owner tries to validateClaim when auditor is not voting", async function () {
    await expect(management.connect(governanceAccount).validateClaim(coverPool.address, 1, 0, true)).to.be
      .reverted;
  });
  it("Should throw if payoutNumerator != 0 when denying claim", async function () {
    await expect(
      management
        .connect(ownerAccount)
        .decideClaim(coverPool.address, 1, 0, false, 1, 100)
    ).to.be.reverted;
  });
  // claim denied
  it("Should deny claim", async function () {
    await management
      .connect(governanceAccount)
      .decideClaim(coverPool.address, 1, 0, false, 0, 100);
  });
  it("Should be in denied state", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 1, 0);
    expect(claim.state).to.equal(state.denied);
  });
  it("Should have payoutNumerator = 0 and payoutDenominator = 1", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 1, 0);
    expect(claim.payoutNumerator).to.equal(0);
    expect(claim.payoutDenominator).to.equal(1);
  });

  // edge cases
  it("Should file 2 new claims", async function () {
    await management.fileClaim(
      coverPool.address,
      BINANCE_PROTOCOL,
      timestamp
    );
    await management.fileClaim(
      coverPool.address,
      BINANCE_PROTOCOL,
      timestamp
    );
    await time.increaseTo(TIMESTAMPS[1]);
    await time.advanceBlock();
  });

  it("Should revert if try to validate claim with payoutNumerator > 0 after window passed", async function () {
    await expect(management.connect(governanceAccount).decideClaim(coverPool.address, 1, 1, true, 1, 1)).to.be.reverted;
  });
  it("Should deny claim if window passed and claimIsAccepted = false", async function () {
    await management.connect(governanceAccount).decideClaim(coverPool.address, 1, 1, false, 0, 1);
  });
  it("Should have correct claim values", async function () {
    const claim = await management.coverPoolClaims(coverPool.address, 1, 1);
    expect(claim.state).to.equal(state.denied);
    expect(claim.decidedTimestamp).to.greaterThan(0);
    expect(claim.payoutNumerator).to.equal(0);
  });
  it("Should deny claim if window passed even if pass in true for claimIsAccepted", async function () {
    await management.connect(governanceAccount).decideClaim(coverPool.address, 1, 2, true, 0, 1);
  });
});