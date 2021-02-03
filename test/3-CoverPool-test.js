const { expect } = require('chai');
const { expectRevert, time, BN } = require("@openzeppelin/test-helpers");
const { deployCoin, consts, getAccounts, getImpls} = require('./testHelper');

describe('CoverPool', () => {
  const NEW_TIMESTAMP = 2556057500000;
  const NEW_TIMESTAMP_NAME = ethers.utils.formatBytes32String('2040_12_31');
  const INCIDENT_TIMESTAMP = 1580515200000;
  const ETHER_UINT_10 = ethers.utils.parseEther('10');
  const ETHER_UINT_1 = ethers.utils.parseEther('1');

  let ownerAddress, ownerAccount, userAAccount, userAAddress, userBAccount, userBAddress, treasuryAccount, treasuryAddress;
  let CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl;
  let COLLATERAL, NEW_COLLATERAL, coverPoolFactory, coverPool, dai, weth;

  before(async () => {
    ({ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, treasuryAccount, treasuryAddress} = await getAccounts());
    ({CoverPoolFactory, CoverPool, coverPoolImpl, coverImpl, coverERC20Impl} = await getImpls());

    // deploy stablecoins to local blockchain emulator
    dai = await deployCoin(ethers, 'dai');
    weth = await deployCoin(ethers, 'weth');

    // use deployed stablecoin address for collaterals
    COLLATERAL = dai.address;
    NEW_COLLATERAL = weth.address;
  }); 
  
  beforeEach(async () => {
    // deploy coverPool factory
    coverPoolFactory = await CoverPoolFactory.deploy(coverPoolImpl.address, coverImpl.address, coverERC20Impl.address, treasuryAddress);
    await coverPoolFactory.deployed();
    await coverPoolFactory.setClaimManager(ownerAddress);

    // add coverPool through coverPool factory
    const tx = await coverPoolFactory.connect(ownerAccount).createCoverPool(consts.POOL_2, true, [consts.ASSET_1, consts.ASSET_2], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0]);
    await tx;
    coverPool = CoverPool.attach(await coverPoolFactory.coverPools(consts.POOL_2));
    await coverPool.connect(ownerAccount).setExpiry(consts.ALLOWED_EXPIRYS[1], consts.ALLOWED_EXPIRY_NAMES[1], 1);
    await coverPool.deployCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    await coverPool.connect(ownerAccount).setExpiry(consts.ALLOWED_EXPIRYS[2], consts.ALLOWED_EXPIRY_NAMES[2], 1);
    await coverPool.deployCover(COLLATERAL, consts.ALLOWED_EXPIRYS[2]);

    // init test account balances
    dai.mint(userAAddress, ETHER_UINT_10);
    await dai.connect(userAAccount).approve(coverPool.address, ETHER_UINT_10);
    dai.mint(userBAddress, ETHER_UINT_10);
    await dai.connect(userBAccount).approve(coverPool.address, ETHER_UINT_10);
  });

  it('Should initialize correct state variables', async () => {
    const [name, extendablePool, active, claimNonce, noclaimRedeemDelay, collaterals, expiries, riskList, deletedRiskList, allCovers] = await coverPool.getCoverPoolDetails();

    expect(name).to.equal(consts.POOL_2);
    expect(extendablePool).to.equal(true);
    expect(active).to.equal(true);
    expect(claimNonce).to.equal(0);
    expect(noclaimRedeemDelay).to.equal(3 * 24 * 60 * 60);
    expect(riskList).to.deep.equal([consts.ASSET_1_BYTES32, consts.ASSET_2_BYTES32]);
    expect(deletedRiskList).to.deep.equal([]);
    expect(collaterals).to.deep.equal([COLLATERAL]);
    expect(expiries).to.deep.equal(consts.ALLOWED_EXPIRYS);
    expect(allCovers.length).to.equal(3);
  });

  it('Should update state variables by the correct authority', async () => {
    await expect(coverPool.connect(ownerAccount).setCollateral(NEW_COLLATERAL, consts.DEPOSIT_RATIO, 2))
      .to.emit(coverPool, 'CollateralUpdated');
    const [, status] = await coverPool.collateralStatusMap(NEW_COLLATERAL);
    expect(status).to.equal(2);
    
    await coverPool.connect(ownerAccount).setExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1);
    expect((await coverPool.expiryInfoMap(NEW_TIMESTAMP)).status).to.equal(1);

    await coverPool.connect(ownerAccount).setActive(false);
    const [,, active] = await coverPool.getCoverPoolDetails();
    expect(active).to.equal(false);

    const newDelay = 10 * 24 * 60 * 60;
    await expect(coverPool.connect(ownerAccount).setNoclaimRedeemDelay(newDelay))
      .to.emit(coverPool, 'NoclaimRedeemDelayUpdated');
    expect((await coverPool.noclaimRedeemDelay())).to.equal(newDelay);
  });

  it('Should NOT update state variables by the wrong authority', async () => {
    await expect(coverPool.connect(userAAccount).setCollateral(NEW_COLLATERAL, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).setExpiry(NEW_TIMESTAMP, NEW_TIMESTAMP_NAME, 1)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).setActive(false)).to.be.reverted;
    await expect(coverPool.connect(userAAccount).setNoclaimRedeemDelay(10 * 24 * 60 * 60, 0)).to.be.reverted;
  });

  it('Should add and delete risk for open pool', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, true, [consts.ASSET_1, consts.ASSET_2, consts.ASSET_3], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);  

    const coverPoolAddr = await coverPoolFactory.coverPools(consts.POOL_3);
    const coverPool = CoverPool.attach(coverPoolAddr);
    expect(await coverPool.name()).to.equal(consts.POOL_3);

    await coverPool.deleteRisk(consts.ASSET_2);
    const [,,,,,,,riskList, deletedRiskList] = await coverPool.getCoverPoolDetails();
    expect(riskList).to.deep.equal([consts.ASSET_1_BYTES32, consts.ASSET_3_BYTES32]);
    expect(deletedRiskList).to.deep.equal([consts.ASSET_2_BYTES32]);

    await expect(coverPool.addRisk(consts.ASSET_2)).to.be.reverted;
    await expect(coverPool.addRisk(consts.ASSET_4)).to.emit(coverPool, 'RiskUpdated');
    const [,,,,,,,riskListAfterAdd] = await coverPool.getCoverPoolDetails();
    expect(riskListAfterAdd).to.deep.equal([consts.ASSET_1_BYTES32, consts.ASSET_3_BYTES32, consts.ASSET_4_BYTES32]);

    await coverPool.deleteRisk(consts.ASSET_4);
  });

  it('Should ONLY delete, NOT add risk for close pool', async () => {
    expect(await coverPoolFactory
      .createCoverPool(consts.POOL_3, false, [consts.ASSET_1, consts.ASSET_2, consts.ASSET_3], COLLATERAL, consts.DEPOSIT_RATIO, consts.ALLOWED_EXPIRYS[0], consts.ALLOWED_EXPIRY_NAMES[0])
      ).to.not.equal(consts.ADDRESS_ZERO);  

    const coverPoolAddr = await coverPoolFactory.coverPools(consts.POOL_3);
    const coverPool = CoverPool.attach(coverPoolAddr);
    expect(await coverPool.name()).to.equal(consts.POOL_3);

    await coverPool.deleteRisk(consts.ASSET_2);
    const [,,,,,,,riskList, deletedRiskList] = await coverPool.getCoverPoolDetails();
    expect(riskList).to.deep.equal([consts.ASSET_1_BYTES32, consts.ASSET_3_BYTES32]);
    expect(deletedRiskList).to.deep.equal([consts.ASSET_2_BYTES32]);

    await expect(coverPool.addRisk(consts.ASSET_2)).to.be.reverted;
    await expect(coverPool.addRisk(consts.ASSET_4)).to.be.reverted;
    const [,,,,,,,riskListAfterAdd] = await coverPool.getCoverPoolDetails();
    expect(riskListAfterAdd).to.deep.equal([consts.ASSET_1_BYTES32, consts.ASSET_3_BYTES32]);
  });

  it('Should delete risk from pool correctly', async () => {
    await expect(coverPool.deleteRisk(consts.ASSET_1)).to.emit(coverPool, 'RiskUpdated');
    const [,,,,,,, riskList, deletedRiskList] = await coverPool.getCoverPoolDetails();
    expect(riskList).to.deep.equal([consts.ASSET_2_BYTES32]);
    expect(deletedRiskList).to.deep.equal([consts.ASSET_1_BYTES32]);

    await expectRevert(coverPool.deleteRisk(consts.ASSET_1), "CP: not active risk");
    await expectRevert(coverPool.deleteRisk(consts.ASSET_2), "CP: only 1 risk left");
  });

  it('Should add cover for userA and emit event', async () => {
    await expect(coverPool.connect(userAAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    )).to.emit(coverPool, 'CoverAdded');
  });

  it('Should match cover with computed cover address', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    );
    await txA.wait();
    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);

    const claimNonce = await coverPool.claimNonce();
    const computedAddress = await coverPoolFactory.getCoverAddress(consts.POOL_2, consts.ALLOWED_EXPIRYS[1], COLLATERAL, claimNonce)
    expect(computedAddress).to.equal(coverAddress);
  });

  it('Should add cover for userB on existing contract', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    );
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1_BYTES32], [ETHER_UINT_1], INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimEnacted');
    await expect(coverPool.deployCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1])).to.emit(coverPool, 'CoverCreated');
    
    const txB = await coverPool.connect(userBAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    );
    await txB.wait();

    const [,,,,,,,,, allCovers] = await coverPool.getCoverPoolDetails();
    const lastActiveCover = allCovers[0];
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);

    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.not.equal(0);
  });

  it('Should create new cover for userB on existing contract when accepted claim', async () => {
    const txA = await coverPool.connect(userAAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    );
    await txA.wait();

    await expect(coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1_BYTES32], [ETHER_UINT_1], INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimEnacted');
    await coverPool.deployCover(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);

    const txB = await coverPool.connect(userBAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    );
    await txB.wait();

    const [,,,,,,,,, allCovers] = await coverPool.getCoverPoolDetails();
    const lastActiveCover = allCovers[0];
    expect(lastActiveCover).to.not.equal(consts.ADDRESS_ZERO);

    const coverAddress = await coverPool.coverMap(COLLATERAL, consts.ALLOWED_EXPIRYS[1]);
    expect(coverAddress).to.not.equal(consts.ADDRESS_ZERO);
    expect(await dai.balanceOf(coverAddress)).to.not.equal(0);
  });

  it('Should emit event and enactClaim if called by claimManager', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1_BYTES32], [ETHER_UINT_1], INCIDENT_TIMESTAMP, 0))
      .to.emit(coverPool, 'ClaimEnacted');
    const [,, active] = await coverPool.getCoverPoolDetails();
    expect(await coverPool.name()).to.equal(consts.POOL_2);
    expect(active).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);
  });

  it('Should NOT enactClaim if coverPool nonce not match', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await coverPool.connect(ownerAccount).enactClaim([consts.ASSET_1_BYTES32], [ETHER_UINT_1], INCIDENT_TIMESTAMP, 0);
    const [,, active] = await coverPool.getCoverPoolDetails();
    expect(await coverPool.name()).to.equal(consts.POOL_2);
    expect(active).to.equal(true);
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce + 1);

    await expect(coverPool.connect(userAAccount).enactClaim([consts.ASSET_1_BYTES32], [ETHER_UINT_1], INCIDENT_TIMESTAMP, 0)).to.be.reverted;
  });

  it('Should NOT enactClaim if have non active risk', async () => {
    await expectRevert(coverPool.enactClaim([consts.ASSET_1_BYTES32, consts.ASSET_3_BYTES32], [ethers.utils.parseEther('0.2'), ethers.utils.parseEther('0.4')], INCIDENT_TIMESTAMP, 0), "CP: has disabled risk");
  });
  
  it('Should NOT enactClaim if called by non-claimManager', async () => {
    const oldClaimNonce = await coverPool.claimNonce();
    await expect(coverPool.connect(userAAccount).enactClaim([consts.ASSET_1_BYTES32], [ETHER_UINT_1], INCIDENT_TIMESTAMP, 0)).to.be.reverted;
    expect(await coverPool.claimNonce()).to.equal(oldClaimNonce);
  });


  it('Should NOT add cover for userA for expired timestamp', async () => {
    await time.increaseTo(consts.ALLOWED_EXPIRYS[1]);
    await time.advanceBlock();

    await expect(coverPool.connect(userAAccount).addCover(
      COLLATERAL, consts.ALLOWED_EXPIRYS[1], ETHER_UINT_10,
      ETHER_UINT_10, consts.ADDRESS_ZERO, '0x'
    )).to.be.reverted;
  });
});