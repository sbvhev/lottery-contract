module.exports = {
  consts: {
    PROTOCOL_NAME: ethers.utils.formatBytes32String('Binance'),
    PROTOCOL_NAME_2: ethers.utils.formatBytes32String('Curve'),
    POOL_2: ethers.utils.formatBytes32String('Pool2'),
    ADDRESS_ZERO: ethers.constants.AddressZero,
    ALLOWED_EXPIRYS: [Math.floor(Date.now()) + 30 * 24 * 60 * 60, Math.floor(Date.now()) + 60 * 24 * 60 * 60, Math.floor(Date.now()) + 90 * 24 * 60 * 60],
    CM_TIMESTAMPS: [Math.floor(Date.now()), Math.floor(Date.now()) + 600 * 24 * 60 * 60, 4105123200000],
    ALLOWED_EXPIRY_NAMES: ['2020_1_1', '2050_12_31', '2100_1_1'].map(s => ethers.utils.formatBytes32String(s)),
  },
  getAccounts: async() => {
    const accounts = await ethers.getSigners();
    const [ ownerAccount, userAAccount, userBAccount, governanceAccount, treasuryAccount, auditorAccount ] = accounts;
    const ownerAddress = await ownerAccount.getAddress();
    const userAAddress = await userAAccount.getAddress();
    const userBAddress = await userBAccount.getAddress();
    const governanceAddress = await governanceAccount.getAddress();
    const treasuryAddress = await treasuryAccount.getAddress();
    const auditorAddress = await auditorAccount.getAddress();
    return {ownerAccount, ownerAddress, userAAccount, userAAddress, userBAccount, userBAddress, governanceAccount, governanceAddress, treasuryAccount, treasuryAddress, auditorAccount, auditorAddress};
  },
  getImpls: async() =>{
    // get main contracts
    const CoverPoolFactory = await ethers.getContractFactory('CoverPoolFactory');
    const CoverPool = await ethers.getContractFactory('CoverPool');
    const CoverWithExpiry = await ethers.getContractFactory('CoverWithExpiry');
    const PerpCover = await ethers.getContractFactory('PerpCover');
    const CoverERC20 = await ethers.getContractFactory('CoverERC20');

    // deploy CoverPool contract
    const coverPoolImpl = await CoverPool.deploy();
    await coverPoolImpl.deployed();

    // deploy Cover contract
    const coverImpl = await CoverWithExpiry.deploy();
    await coverImpl.deployed();

    // deploy Cover contract
    const perpCoverImpl = await PerpCover.deploy();
    await perpCoverImpl.deployed();

    // deploy CoverERC20 contract
    const coverERC20Impl = await CoverERC20.deploy();
    await coverERC20Impl.deployed();
    return {CoverPoolFactory, CoverPool, PerpCover, CoverWithExpiry, CoverERC20, coverPoolImpl, coverImpl, perpCoverImpl, coverERC20Impl};
  },
  deployCoin: async (ethers, symbol) => {
    const CoverERC20 = await ethers.getContractFactory('CoverERC20');
    const dai = await CoverERC20.deploy();
    await dai.deployed();
    await dai.initialize(symbol);
    return dai;
  }
}