const { expect } = require('chai');
const { fromRpcSig } = require('ethereumjs-util');
const ethSigUtil = require('eth-sig-util');
const { expectRevert, time, constants, BN } = require("@openzeppelin/test-helpers");
const Wallet = require('ethereumjs-wallet').default;

const testHelper = require('./testHelper');
const { EIP712Domain, domainSeparator } = require('./eip712');

xdescribe('CoverERC20', function() {
  const COV_TOKEN_SYMBOL = 'C_cDai_CURVE_0_DAI_210131';
  const TRANSFER_AMOUNT = ethers.utils.parseEther("42");
  const A_BALANCE = ethers.utils.parseEther("100");
  const B_BALANCE = ethers.utils.parseEther("190001");
  const { ZERO_ADDRESS } = constants;

  let ownerAddress, userAAddress, userBAddress, ownerAccount, userAAccount, userBAccount;
  let deadline, chainId, coverERC20;

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
    chainId = (await coverERC20.getChainId()).toNumber();
    const latest = await time.latest();
    deadline = latest + 60 * 60 * 5;
  });

  it('Should deploy with correct name, symbol, decimals, totalSupply, balanceOf, permit nonce and domainSeparator', async function() {
    expect(await coverERC20.name()).to.equal('Cover Protocol covToken');
    expect(await coverERC20.decimals()).to.equal(8);
    expect(await coverERC20.symbol()).to.equal(COV_TOKEN_SYMBOL);
    expect(await coverERC20.totalSupply()).to.equal(A_BALANCE.add(B_BALANCE));
    expect(await coverERC20.balanceOf(ownerAddress)).to.equal(0);

    // permit related check
    expect(await coverERC20.nonces(ownerAddress)).to.equal(0);
    const domainSeparatorInToken = await coverERC20.DOMAIN_SEPARATOR();
    const computedDomainSeparator = await domainSeparator(COV_TOKEN_SYMBOL, '1', chainId, coverERC20.address);
    expect(computedDomainSeparator).to.equal(domainSeparatorInToken);
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
      .withArgs(userAAddress, ZERO_ADDRESS, TRANSFER_AMOUNT);
    expect(await coverERC20.balanceOf(userAAddress)).to.equal(A_BALANCE.sub(TRANSFER_AMOUNT));
  });  

  describe('permit', function () {
    const wallet = Wallet.generate();
    const walletAddress = wallet.getAddressString();

    const Permit = [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
      { name: 'value', type: 'uint256' },
      { name: 'nonce', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ];
    const value = 42000000000;
    const name = COV_TOKEN_SYMBOL;
    const nonce = 0;
    const version = '1';

    const buildData = (chainId, verifyingContract) => ({
      primaryType: 'Permit',
      types: { EIP712Domain, Permit },
      domain: { name, version, chainId, verifyingContract },
      message: { owner: walletAddress, spender: userAAddress, value, nonce, deadline },
    });

    it('accepts walletAddress signature', async function () {
      const data = buildData(chainId, coverERC20.address);
      const signature = ethSigUtil.signTypedMessage(wallet.getPrivateKey(), { data });
      const { v, r, s } = fromRpcSig(signature);

      await coverERC20.permit(walletAddress, userAAddress, value, deadline, v, r, s);

      expect(await coverERC20.nonces(walletAddress)).to.equal(1);
      expect(await coverERC20.allowance(walletAddress, userAAddress)).to.equal(value);
    });

    it('rejects reused signature', async function () {
      const data = buildData(chainId, coverERC20.address);
      const signature = ethSigUtil.signTypedMessage(wallet.getPrivateKey(), { data });
      const { v, r, s } = fromRpcSig(signature);

      await coverERC20.permit(walletAddress, userAAddress, value, deadline, v, r, s);

      await expectRevert(
        coverERC20.permit(walletAddress, userAAddress, value, deadline, v, r, s),
        'ERC20Permit: invalid signature',
      );
    });

    it('rejects other signature', async function () {
      const otherWallet = Wallet.generate();
      const data = buildData(chainId, coverERC20.address);
      const signature = ethSigUtil.signTypedMessage(otherWallet.getPrivateKey(), { data });
      const { v, r, s } = fromRpcSig(signature);

      await expectRevert(
        coverERC20.permit(walletAddress, userAAddress, value, deadline, v, r, s),
        'ERC20Permit: invalid signature',
      );
    });

    it('rejects expired permit', async function () {
      const deadline = (await time.latest()) - time.duration.weeks(1);

      const data = buildData(chainId, coverERC20.address, deadline);
      const signature = ethSigUtil.signTypedMessage(wallet.getPrivateKey(), { data });
      const { v, r, s } = fromRpcSig(signature);

      await expectRevert(
        coverERC20.permit(walletAddress, userAAddress, value, deadline, v, r, s),
        'ERC20Permit: expired deadline',
      );
    });
  });  
});