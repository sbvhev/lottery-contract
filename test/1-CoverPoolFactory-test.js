const { expect } = require('chai');
const { expectRevert } = require("@openzeppelin/test-helpers");
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('CoverPoolFactory', () => {
  let ownerAccount, ownerAddress, userAAccount, userAAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, perpCoverImpl, coverImpl, coverERC20Impl;
  let coverPoolFactory, dai, COLLATERAL;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, perpCoverImpl, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    // use deployed stablecoin address for collaterals
    COLLATERAL = dai.address;
  });

  beforeEach(async () => {
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, perpCoverImpl.address, coverImpl.address, coverERC20Impl.address, governanceAddress, treasuryAddress);
    await coverPoolFactory.deployed();
  });

  it('Should deploy with correct state variable values', async () => {
    expect(await coverPoolFactory.coverPoolImpl()).to.equal(coverPoolImpl.address);
    expect(await coverPoolFactory.coverImpl()).to.equal(coverImpl.address);
    expect(await coverPoolFactory.coverERC20Impl()).to.equal(coverERC20Impl.address);
    expect(await coverPoolFactory.governance()).to.equal(governanceAddress);
    expect(await coverPoolFactory.treasury()).to.equal(treasuryAddress);
  });

  it('Should emit CoverPoolCreation event', async () => {
    await expect(coverPoolFactory.connect(ownerAccount)
      .createCoverPool(consts.PROTOCOL_NAME, [consts.PROTOCOL_NAME], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES)
      ).to.emit(coverPoolFactory, 'CoverPoolCreation');
  });

  // test functions with governance access restriction
  it('Should NOT update governance to address(0) by governance', async () => {
    await expectRevert(coverPoolFactory.connect(governanceAccount).updateGovernance(consts.ADDRESS_ZERO), 'CoverPoolFactory: address cannot be 0');
  });

  it('Should NOT update governance to owner by governance', async () => {
    await expectRevert(coverPoolFactory.connect(governanceAccount).updateGovernance(ownerAddress), 'CoverPoolFactory: governance cannot be owner');
  });

  // test functions with owner access restriction
  it('Should update claimManager by owner', async () => {
    await coverPoolFactory.connect(ownerAccount).updateClaimManager(userAAddress);
    expect(await coverPoolFactory.claimManager()).to.equal(userAAddress);
  });

  it('Should NOT update claimManager by non-owner', async () => {
    await expect(coverPoolFactory.connect(userAAccount).updateClaimManager(userAAddress)).to.be.reverted;
  });

  it('Should add 2 new coverPools by owner', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.PROTOCOL_NAME, [consts.PROTOCOL_NAME], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES)
      ).to.not.equal(consts.ADDRESS_ZERO);  
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_2, [consts.PROTOCOL_NAME, consts.PROTOCOL_NAME_2], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES)
      ).to.not.equal(consts.ADDRESS_ZERO);
    expect((await coverPoolFactory.getCoverPoolAddresses()).length).to.equal(2);

    const coverPoolAddr1 = await coverPoolFactory.coverPools(consts.PROTOCOL_NAME);
    expect(await CoverPool.attach(coverPoolAddr1).name()).to.equal(consts.PROTOCOL_NAME);

    const coverPoolAddr2 = await coverPoolFactory.coverPools(consts.POOL_2);
    expect(await CoverPool.attach(coverPoolAddr2).name()).to.equal(consts.POOL_2);
    expect(await CoverPool.attach(coverPoolAddr2).assetList(0)).to.deep.equal(consts.PROTOCOL_NAME);
    expect(await CoverPool.attach(coverPoolAddr2).assetList(1)).to.deep.equal(consts.PROTOCOL_NAME_2);
  });

  it('Should compute the same coverPool addresses', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.PROTOCOL_NAME, [consts.PROTOCOL_NAME], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES)
      ).to.not.equal(consts.ADDRESS_ZERO);  

    const coverPoolAddr1 = await coverPoolFactory.coverPools(consts.PROTOCOL_NAME);
    expect(await CoverPool.attach(coverPoolAddr1).name()).to.equal(consts.PROTOCOL_NAME);

    const computedAddr1 = await coverPoolFactory.getCoverPoolAddress(consts.PROTOCOL_NAME);
    expect(computedAddr1).to.equal(coverPoolAddr1);
  });

  it('Should NOT add new coverPool by userA', async () => {
    await expect(coverPoolFactory
      .connect(userAAccount)
      .createCoverPool(consts.PROTOCOL_NAME, [consts.PROTOCOL_NAME], COLLATERAL, consts.ALLOWED_EXPIRYS, consts.ALLOWED_EXPIRY_NAMES)
      ).to.be.reverted;
  });
});