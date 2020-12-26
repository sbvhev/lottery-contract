const { expect } = require("chai");
const { consts, getAccounts } = require('../testHelper');

describe("ClaimConfig", function () {
  let claimConfig;
  let ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress;
  let testCoverPool = "0x000000000000000000000000000000000000dEaD";
  let defaultCVC = "0x0000000000000000000000000000000000000001";
  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress} = await getAccounts());
  });

  it("Should deploy ClaimManagement correctly", async function () {
    const ClaimConfig = await ethers.getContractFactory("ClaimManagement");
    await expect(ClaimConfig.deploy(ownerAddress, treasuryAddress, userAAddress)).to.be.reverted;
    claimConfig = await ClaimConfig.deploy(
      governanceAddress,
      treasuryAddress,
      userAAddress,
      defaultCVC
    );
    await claimConfig.deployed();

    expect(await claimConfig.allowPartialClaim()).to.equal(true);
    expect(await claimConfig.governance()).to.equal(governanceAddress);
    expect(await claimConfig.treasury()).to.equal(treasuryAddress);
    expect(await claimConfig.defaultCVC()).to.equal(defaultCVC);
  });

  it("Should only set if authorized", async function () {
    await expect(claimConfig.connect(userAAccount).setGovernance(governanceAddress)).to.be.reverted;
    await expect(claimConfig.connect(governanceAccount).setGovernance(ownerAddress)).to.be.reverted;
    await expect(claimConfig.connect(governanceAccount).setGovernance(consts.ADDRESS_ZERO)).to.be.reverted;
    await claimConfig.connect(governanceAccount).setGovernance(userBAddress);
    expect(await claimConfig.governance()).to.equal(userBAddress);

    await expect(claimConfig.connect(userAAccount).setTreasury(auditorAddress)).to.be.reverted;
    await expect(claimConfig.connect(governanceAccount).setTreasury(consts.ADDRESS_ZERO)).to.be.reverted;
    await claimConfig.setTreasury(treasuryAddress);
    expect(await claimConfig.treasury()).to.equal(treasuryAddress);

    expect(await claimConfig.isCVCMember(testCoverPool, defaultCVC)).to.equal(true);
    await claimConfig.addCVCForPool(testCoverPool, auditorAddress);
    expect(await claimConfig.isCVCMember(testCoverPool, auditorAddress)).to.equal(true);
    expect(await claimConfig.isCVCMember(testCoverPool, defaultCVC)).to.equal(false);

    expect(await claimConfig.removeCVCForPool(testCoverPool, auditorAddress))
    expect(await claimConfig.isCVCMember(testCoverPool, auditorAddress)).to.equal(false);

    await expect(claimConfig.removeCVCForPool(testCoverPool, auditorAddress)).to.be.reverted;
    await expect(claimConfig.removeCVCForPool(testCoverPool, defaultCVC)).to.be.reverted;
  });
  
  it("Should set fees and currency", async function () {
    await claimConfig.connect(userBAccount).setFeeMultiplier(3);
    expect(await claimConfig.feeMultiplier()).to.equal(3);

    let baseClaimFee = ethers.utils.parseEther("20");
    let forceClaimFee = ethers.utils.parseEther("1000");
    let feeCurrency = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    await claimConfig
      .connect(userBAccount)
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
