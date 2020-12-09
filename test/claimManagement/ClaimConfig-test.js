const { expect } = require("chai");

xdescribe("ClaimConfig", function () {
  var claimConfig;
  var ownerAccount,
    ownerAddress,
    auditorAccount,
    auditorAddress,
    treasuryAccount,
    treasuryAddress,
    bogeyAccount,
    bogeyAddress,
    governanceAccount,
    governanceAddress,
    governance2Account,
    governance2Address;

  const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

  before(async () => {
    const accounts = await ethers.getSigners();
    [
      ownerAccount,
      auditorAccount,
      treasuryAccount,
      bogeyAccount,
      governanceAccount,
      governance2Account,
    ] = accounts;
    ownerAddress = await ownerAccount.getAddress();
    auditorAddress = await auditorAccount.getAddress();
    treasuryAddress = await treasuryAccount.getAddress();
    governanceAddress = await governanceAccount.getAddress();
    governance2Address = await governance2Account.getAddress();
    bogeyAddress = await bogeyAccount.getAddress();
  });
  it("Should throw if deploy with owner as dev", async function () {
    const ClaimConfig = await ethers.getContractFactory("ClaimManagement");
    await expect(
      ClaimConfig.deploy(ownerAddress, treasuryAddress, bogeyAddress)
    ).to.be.reverted;
  });
  it("Should deploy ClaimManagement", async function () {
    const ClaimConfig = await ethers.getContractFactory("ClaimManagement");
    claimConfig = await ClaimConfig.deploy(
      governanceAddress,
      ZERO_ADDR,
      treasuryAddress,
      bogeyAddress
    );
    await claimConfig.deployed();
  });
  it("Should have correct default values on deploy", async function () {
    expect(await claimConfig.isAuditorVoting()).to.equal(false);
    expect(await claimConfig.allowPartialClaim()).to.equal(true);
    expect(await claimConfig.governance()).to.equal(governanceAddress);
    expect(await claimConfig.treasury()).to.equal(treasuryAddress);
    expect(await claimConfig.auditor()).to.equal(ZERO_ADDR);
  });
  it("Should only allow governance to set new governance", async function () {
    await expect(claimConfig.connect(bogeyAccount).setGovernance(governanceAddress)).to
      .be.reverted;
  });
  it("Should throw if set governance to owner", async function () {
    await expect(claimConfig.connect(governanceAccount).setGovernance(ownerAddress)).to
      .be.reverted;
  });
  it("Should throw if set governance to 0", async function () {
    await expect(claimConfig.connect(governanceAccount).setGovernance(ZERO_ADDR)).to.be
      .reverted;
  });
  it("Should set new governance", async function () {
    await claimConfig.connect(governanceAccount).setGovernance(governance2Address);
    expect(await claimConfig.governance()).to.equal(governance2Address);
  });
  it("Should only allow governance to set treasury", async function () {
    await expect(claimConfig.connect(bogeyAccount).setTreasury(auditorAddress))
      .to.be.reverted;
  });
  it("Should throw if set treasury to 0", async function () {
    await expect(claimConfig.connect(governanceAccount).setTreasury(ZERO_ADDR)).to.be
      .reverted;
  });
  it("Should set treasury", async function () {
    await claimConfig.setTreasury(treasuryAddress);
    expect(await claimConfig.treasury()).to.equal(treasuryAddress);
  });
  it("Should only allow owner to set auditor", async function () {
    await expect(claimConfig.connect(bogeyAccount).setAuditor(treasuryAddress))
      .to.be.reverted;
  });
  it("Should set auditor", async function () {
    await claimConfig.setAuditor(auditorAddress);
    expect(await claimConfig.auditor()).to.equal(auditorAddress);
    expect(await claimConfig.isAuditorVoting()).to.equal(true);
  });
  it("Should remove auditor", async function () {
    await claimConfig.setAuditor(ZERO_ADDR);
    expect(await claimConfig.auditor()).to.equal(ZERO_ADDR);
    expect(await claimConfig.isAuditorVoting()).to.equal(false);
  });
  it("Should set fee multiplier", async function () {
    await claimConfig.connect(governance2Account).setFeeMultiplier(3);
    expect(await claimConfig.feeMultiplier()).to.equal(3);
  });
  it("Should set fee and currency", async function () {
    let baseClaimFee = ethers.utils.parseEther("20");
    let forceClaimFee = ethers.utils.parseEther("1000");
    let feeCurrency = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    await claimConfig
      .connect(governance2Account)
      .setFeeAndCurrency(baseClaimFee, forceClaimFee, feeCurrency);
    expect(await claimConfig.baseClaimFee()).to.equal(
      ethers.utils.parseEther("20")
    );
    expect(await claimConfig.forceClaimFee()).to.equal(
      ethers.utils.parseEther("1000")
    );
    expect(await claimConfig.feeCurrency()).to.equal(
      "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    );
  });
});
