module.exports = {
  deployCoin: async (ethers, symbol) => {
    const CoverERC20 = await ethers.getContractFactory('CoverERC20');
    const dai = await CoverERC20.deploy();
    await dai.deployed();
    await dai.initialize(symbol);
    return dai;
  }
}