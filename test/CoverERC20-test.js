const { expect } = require('chai');
const testHelper = require('./testHelper');

describe('CoverERC20', function() {
  const COV_TOKEN_SYMBOL = 'COVER_CURVE_2020_12_31_DAI_0_CLAIM';
  const TRANSFER_AMOUNT = ethers.utils.parseEther("5");
  const A_BALANCE = ethers.utils.parseEther("10");
  const B_BALANCE = ethers.utils.parseEther("190001") ;
  const ADDRESS_ZERO = ethers.constants.AddressZero;
  
  let coverERC20, ownerAddress, userAAddress, userBAddress, ownerAccount, userAAccount, userBAccount;

  before(async () => {
    const accounts = await ethers.getSigners();
    [ ownerAccount, userAAccount, userBAccount ] = accounts;
    ownerAddress = await ownerAccount.getAddress();
    userAAddress = await userAAccount.getAddress();
    userBAddress = await userBAccount.getAddress();
  });

  beforeEach(async () => {
    coverERC20 = await testHelper.deployCoin(ethers, COV_TOKEN_SYMBOL);

    await coverERC20.mint(userAAddress, A_BALANCE);
    await coverERC20.mint(userBAddress, B_BALANCE);
  });

  it('Should deploy with correct name, symbol, decimals, totalSupply, balanceOf', async function() {
    expect(await coverERC20.name()).to.equal('covToken');
    expect(await coverERC20.symbol()).to.equal(COV_TOKEN_SYMBOL);
    expect(await coverERC20.totalSupply()).to.equal(A_BALANCE.add(B_BALANCE));
    expect(await coverERC20.balanceOf(ownerAddress)).to.equal(0);
  });

  it('Should mint tokens to userA and userB', async function() {
    expect(await coverERC20.balanceOf(userAAddress)).to.equal(A_BALANCE);
    expect(await coverERC20.balanceOf(userBAddress)).to.equal(B_BALANCE);
  });

  it('Should update totalSupply after mint', async function() {
    expect(await coverERC20.totalSupply()).to.equal(A_BALANCE.add(B_BALANCE));
  });

  it('Should NOT mint tokens signed by non-owner', async function() {
    await expect(coverERC20.connect(userAAccount).mint(userBAddress, B_BALANCE)).to.be.reverted;
  });

  it('Should allow transfer from userA to userB', async function() {
    await expect(coverERC20.connect(userAAccount).transfer(userBAddress, TRANSFER_AMOUNT))
      .to.emit(coverERC20, 'Transfer')
      .withArgs(userAAddress, userBAddress, TRANSFER_AMOUNT);
    expect(await coverERC20.balanceOf(userAAddress)).to.equal(A_BALANCE.sub(TRANSFER_AMOUNT));
    expect(await coverERC20.balanceOf(userBAddress)).to.equal(B_BALANCE.add(TRANSFER_AMOUNT));
  });

  it('Should approve', async function() {
    await expect(coverERC20.connect(userAAccount).approve(userBAddress, TRANSFER_AMOUNT))
      .to.emit(coverERC20, 'Approval')
      .withArgs(userAAddress, userBAddress, TRANSFER_AMOUNT);
    expect(await coverERC20.allowance(userAAddress, userBAddress)).to.equal(TRANSFER_AMOUNT);
  });

  it('Should transferFrom within allowance', async function() {
    await coverERC20.connect(userAAccount).approve(userBAddress, TRANSFER_AMOUNT);
    await expect(coverERC20.connect(userBAccount).transferFrom(userAAddress, userBAddress, TRANSFER_AMOUNT))
      .to.emit(coverERC20, 'Transfer')
      .withArgs(userAAddress, userBAddress, TRANSFER_AMOUNT);
  });

  it('Should NOT transferFrom when amount > allowance', async function() {
    await coverERC20.connect(userAAccount).approve(userBAddress, TRANSFER_AMOUNT);
    await expect(coverERC20
      .connect(userBAccount)
      .transferFrom(userAAddress, userBAddress, TRANSFER_AMOUNT.add(1))
      ).to.be.reverted;
  });

  it('Should NOT burn by non-owner', async function() {
    await expect(coverERC20.connect(userAAccount).burnByCover(userBAddress, B_BALANCE)).to.be.reverted;
  });

  it('Should burn userB balance by owner', async function() {
    await expect(coverERC20.burnByCover(userBAddress, B_BALANCE))
      .to.emit(coverERC20, 'Transfer')
      .withArgs(userBAddress, ethers.constants.AddressZero, B_BALANCE);

    expect(await coverERC20.totalSupply()).to.equal(A_BALANCE);
  });

  it('Should burn', async function() {
    await expect(coverERC20.connect(userAAccount).burn(TRANSFER_AMOUNT))
      .to.emit(coverERC20, 'Transfer')
      .withArgs(userAAddress, ADDRESS_ZERO, TRANSFER_AMOUNT);
    expect(await coverERC20.balanceOf(userAAddress)).to.equal(A_BALANCE.sub(TRANSFER_AMOUNT));
  });  
});