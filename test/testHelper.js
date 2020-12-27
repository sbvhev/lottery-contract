module.exports = {
  consts: {
    ASSET_1: ethers.utils.formatBytes32String('Binance'),
    ASSET_2: ethers.utils.formatBytes32String('Curve'),
    ASSET_3: ethers.utils.formatBytes32String('AAVEAAVE'),
    ASSET_4: ethers.utils.formatBytes32String('Cream'),
    POOL_1: 'Pool1',
    POOL_2: 'Pool2',
    POOL_3: 'Pool3',
    DEPOSIT_RATIO: ethers.utils.parseEther('1'),
    ADDRESS_ZERO: ethers.constants.AddressZero,
    ALLOWED_EXPIRYS: [Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60, Math.floor(Date.now() / 1000) + 60 * 24 * 60 * 60, Math.floor(Date.now() / 1000) + 90 * 24 * 60 * 60],
    ALLOWED_EXPIRY_NAMES: ['2020_1_1', '2050_12_31', '2100_1_1'],
    CM_TIMESTAMPS: [Math.floor(Date.now())+ 300 * 24 * 60 * 60, 4105123200000, Math.floor(Date.now()) + 600 * 24 * 60 * 60, 4105123200000],
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
    const Cover = await ethers.getContractFactory('Cover');
    const CoverERC20 = await ethers.getContractFactory('CoverERC20');

    // deploy CoverPool contract
    const coverPoolImpl = await CoverPool.deploy();
    await coverPoolImpl.deployed();

    // deploy Cover contract
    const coverImpl = await Cover.deploy();
    await coverImpl.deployed();

    // deploy CoverERC20 contract
    const coverERC20Impl = await CoverERC20.deploy();
    await coverERC20Impl.deployed();
    return {CoverPoolFactory, CoverPool, Cover, CoverERC20, coverPoolImpl, coverImpl, coverERC20Impl};
  },
  deployCoin: async (ethers, symbol) => {
    const CoverERC20 = await ethers.getContractFactory('CoverERC20');
    const dai = await CoverERC20.deploy();
    await dai.deployed();
    await dai.initialize(symbol, 18);
    return dai;
  }
}