const { expect } = require("chai");
const { consts, getAccounts } = require('./testHelper');

describe("ClaimConfig", function () {
  let claimConfig;
  let ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress;
  let testCoverPool = "0x000000000000000000000000000000000000dEaD";
  let defaultCVC = "0x0000000000000000000000000000000000000001";
  const feeCurrency = "0x0000000000000000000000000000000000000002";

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress} = await getAccounts());
  });

  it("Should deploy ClaimManagement correctly", async function () {
    const ClaimConfig = await ethers.getContractFactory("ClaimManagement");
    await expect(ClaimConfig.deploy(ownerAddress, treasuryAddress, userAAddress)).to.be.reverted;
    claimConfig = await ClaimConfig.deploy(
      feeCurrency,
      treasuryAddress,
      userAAddress,
      defaultCVC
    );
    await claimConfig.deployed();

    expect(await claimConfig.treasury()).to.equal(treasuryAddress);
    expect(await claimConfig.defaultCVC()).to.equal(defaultCVC);
  });

  it("Should only set if authorized", async function () {
    await expect(claimConfig.connect(userAAccount).setTreasury(auditorAddress)).to.be.reverted;
    await expect(claimConfig.connect(ownerAccount).setTreasury(consts.ADDRESS_ZERO)).to.be.reverted;
    await claimConfig.setTreasury(treasuryAddress);
    expect(await claimConfig.treasury()).to.equal(treasuryAddress);

    expect(await claimConfig.isCVCMember(testCoverPool, defaultCVC)).to.equal(true);
    await claimConfig.addCVCForPools([testCoverPool], [auditorAddress]);
    expect(await claimConfig.isCVCMember(testCoverPool, auditorAddress)).to.equal(true);
    expect(await claimConfig.isCVCMember(testCoverPool, defaultCVC)).to.equal(false);

    expect(await claimConfig.removeCVCForPools([testCoverPool], [auditorAddress]))
    expect(await claimConfig.isCVCMember(testCoverPool, auditorAddress)).to.equal(false);
  });
  
  it("Should set fees and currency", async function () {
    await claimConfig.connect(ownerAccount).setFeeMultiplier(3);
    expect(await claimConfig.feeMultiplier()).to.equal(3);

    let baseClaimFee = ethers.utils.parseEther("20");
    let forceClaimFee = ethers.utils.parseEther("1000");
    let feeCurrency = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    await claimConfig
      .connect(ownerAccount)
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
