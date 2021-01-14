// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./ERC20/SafeERC20.sol";
import "./ERC20/IERC20.sol";
import "./proxy/BasicProxyLib.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/StringHelper.sol";
import "./interfaces/ICover.sol";
import "./interfaces/ICoverERC20.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";
import "./interfaces/ICovTokenProxy.sol";

/**
 * @title Cover contract
 * @author crypto-pumpkin
 *
 * The contract
 *  - Holds collateral funds
 *  - Mints and burns CovTokens (CoverERC20)
 *  - Handles redeem with or without an accepted claim
 */
contract Cover is ICover, Initializable, ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;

  bool public override deployComplete; // once true, never false
  uint48 private expiry;
  address private collateral;
  ICoverERC20 private noclaimCovToken;
  // Yearn_0_DAI_210131
  string private name;
  // e18 created as initialization, cannot be changed, used to decided the collateral to covToken ratio
  uint256 private depositRatio;
  uint256 private duration;
  uint256 private feeNumerator;
  uint256 private feeDenominator;
  uint256 private totalDebt;
  uint256 public override claimNonce;

  ICoverERC20[] private futureCovTokens;
  ICoverERC20[] private claimCovTokens;
  mapping(bytes32 => ICoverERC20) public override claimCovTokenMap;
  // future token => CLAIM Token
  mapping(ICoverERC20 => ICoverERC20) public override futureCovTokenMap;

  /// @dev Initialize, called once
  function initialize (
    string calldata _name,
    uint48 _expiry,
    address _collateral,
    uint256 _depositRatio,
    uint256 _claimNonce
  ) public initializer {
    initializeOwner();
    (uint256 _feeNumerator, uint256 _feeDenominator) = ICoverPool(owner()).getRedeemFees();
    feeNumerator = _feeNumerator;
    feeDenominator = _feeDenominator;
    name = _name;
    expiry = _expiry;
    collateral = _collateral;
    depositRatio = _depositRatio;
    claimNonce = _claimNonce;
    duration = uint256(_expiry) - block.timestamp;

    noclaimCovToken = _createCovToken("NC_");
    futureCovTokens.push(_createCovToken("C_FUT0_"));
    deployComplete = false;
    deploy();
  }

  function viewClaimable(address _account) external view override returns (uint256 eligibleAmount) {
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(_account);
      eligibleAmount = eligibleAmount + amount * claim.payoutNumerators[i] / claim.payoutDenominator;
    }
    if (claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(_account);
      uint256 payoutAmount = amount * (claim.payoutDenominator - claim.payoutTotalNum) / claim.payoutDenominator;
      eligibleAmount = eligibleAmount + payoutAmount;
    }
  }

  function getCoverDetails()
    external view override
    returns (
      string memory _name,
      uint48 _expiry,
      address _collateral,
      uint256 _depositRatio,
      uint256 _claimNonce,
      uint256 _duration,
      ICoverERC20 _noclaimCovToken,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20[] memory _futureCovTokens)
  {
    return (name, expiry, collateral, depositRatio, claimNonce, duration, noclaimCovToken, claimCovTokens, futureCovTokens);
  }

  function getRedeemFees() external view override returns (uint256 _numerator, uint256 _denominator) {
    return (feeNumerator, feeDenominator);
  }

  function collectFees() public override {
    IERC20 collateralToken = IERC20(collateral);
    if (totalDebt == 0) {
      _sendFees(collateralToken.balanceOf(address(this)));
      return;
    }
    uint256 feeToCollect = collateralToken.balanceOf(address(this)) - _afterFees(totalDebt);
    if (feeToCollect > 10) {
      // minus 1 to avoid dust caused inBalance
      _sendFees(feeToCollect - 1);
    }
  }

  /// @notice only owner (covered coverPool) can mint, collateral is transfered in CoverPool
  function mint(uint256 _amount, address _receiver) external override onlyOwner {
    require(deployComplete, "Cover: deploy incomplete");
    require(ICoverPool(owner()).claimNonce() == claimNonce, "Cover: claim accepted");

    uint256 adjustedAmount = _amount * depositRatio / 1e18;
    (bytes32[] memory _assetList) = ICoverPool(owner()).getAssetList();
    for (uint i = 0; i < _assetList.length; i++) {
      claimCovTokenMap[_assetList[i]].mint(_receiver, adjustedAmount);
    }
    noclaimCovToken.mint(_receiver, adjustedAmount);
    _handleLatestFutureToken(_receiver, adjustedAmount, true); // mint
    totalDebt = totalDebt + adjustedAmount;
  }

  /**
   * @notice redeem collateral
   * - if there is an accepted claim, but incident time > expiry, redeem with noclaim tokens only if default delay passed
   * - if expired and noclaim delay passed, no accepted claim, redeem with noclaim tokens only
   * - otherwise, always allow redeem back collateral with all covToken at any give moment
   */
  function redeemCollateral(uint256 _amount) external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    (uint256 defaultRedeemDelay, uint256 noclaimRedeemDelay) = coverPool.getRedeemDelays();

    if (coverPool.claimNonce() > claimNonce) {
      ICoverPool.ClaimDetails memory claim = _claimDetails();
      if (claim.incidentTimestamp > expiry && block.timestamp >= uint256(expiry) + defaultRedeemDelay) {
        // expired, redeem with noclaim tokens only
        _burnNoclaimAndPay(noclaimCovToken, 1, 1);
        return;
      }
    } else if (block.timestamp >= uint256(expiry) + noclaimRedeemDelay) {
      // expired and noclaim delay passed, no accepted claim, redeem with noclaim tokens only
      _burnNoclaimAndPay(noclaimCovToken, 1, 1);
      return;
    }
    _redeemWithAllCovTokens(coverPool, _amount);
  }

  /// @notice convert last future token to claim token and lastest future token
  function convert(ICoverERC20 _futureToken) public override {
    ICoverERC20 claimCovToken = futureCovTokenMap[_futureToken];
    require(address(claimCovToken) != address(0), "Cover: nothing to convert");
    uint256 amount = _futureToken.balanceOf(msg.sender);
    require(amount > 0, "Cover: insufficient balance");
    _futureToken.burnByCover(msg.sender, amount);
    claimCovToken.mint(msg.sender, amount);
    _handleLatestFutureToken(msg.sender, amount, true);
  }

  function convertAll(ICoverERC20[] calldata _futureTokens) external override {
    for (uint256 i = 0; i < _futureTokens.length; i++) {
      convert(_futureTokens[i]);
    }
  }

  /**
   * @notice called by owner (CoverPool) only, when a new asset is added to pool the first time
   * - create a new claim token for asset
   * - point the current latest (last one in futureCovTokens) to newly created claim token
   * - create a new future token and push to futureCovTokens
   */
  function addAsset(bytes32 _asset) external override onlyOwner {
    if (block.timestamp >= expiry) return;
    // make sure new asset has not already been added
    if (address(claimCovTokenMap[_asset]) != address(0)) return;

    ICoverERC20[] memory futureCovTokensCopy = futureCovTokens; // save gas
    uint256 len = futureCovTokensCopy.length;
    ICoverERC20 futureCovToken = futureCovTokensCopy[len - 1];

    string memory assetName = StringHelper.bytes32ToString(_asset);
    ICoverERC20 claimToken = _createCovToken(string(abi.encodePacked("C_", assetName, "_")));
    claimCovTokens.push(claimToken);
    claimCovTokenMap[_asset] = claimToken;
    futureCovTokenMap[futureCovToken] = claimToken;

    string memory nextFutureTokenName = string(abi.encodePacked("C_FUT", StringHelper.uintToString(len), "_"));
    futureCovTokens.push(_createCovToken(nextFutureTokenName));
  }

  /**
   * @dev multi-tx/block deployment solution. Only called (1+ times depend on size of pool) at creation.
   * Deploy covTokens as many as possible till not enough gas left. 
   */
  function deploy() public override {
    require(!deployComplete, "Cover: deploy completed");
    (bytes32[] memory _assetList) = ICoverPool(owner()).getAssetList();
    uint256 startGas = gasleft();
    for (uint256 i = 0; i < _assetList.length; i++) {
      if (startGas < _factory().deployGasMin()) return;
      ICoverERC20 claimToken = claimCovTokenMap[_assetList[i]];
      if (address(claimToken) == address(0)) {
        string memory assetName = StringHelper.bytes32ToString(_assetList[i]);
        claimToken = _createCovToken(string(abi.encodePacked("C_", assetName, "_")));
        claimCovTokens.push(claimToken);
        claimCovTokenMap[_assetList[i]] = claimToken;
        startGas = gasleft();
      }
    }
    deployComplete = true;
    emit CoverDeployCompleted();
  }

  /// @notice redeem when there is an accepted claim
  function redeemClaim() external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    require(coverPool.claimNonce() > claimNonce, "Cover: no claim accepted");

    ICoverPool.ClaimDetails memory claim = _claimDetails();
    require(claim.incidentTimestamp <= expiry, "Cover: not eligible, redeem collateral instead");
    (uint256 defaultRedeemDelay, ) = coverPool.getRedeemDelays();
    require(block.timestamp >= uint256(claim.claimEnactedTimestamp) + defaultRedeemDelay, "Cover: not ready");

    uint256 eligibleAmount;
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(msg.sender);
      eligibleAmount = eligibleAmount + amount * claim.payoutNumerators[i] / claim.payoutDenominator;
      covToken.burnByCover(msg.sender, amount);
    }

    if (claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(msg.sender);
      uint256 payoutAmount = amount * (claim.payoutDenominator - claim.payoutTotalNum) / claim.payoutDenominator;
      eligibleAmount = eligibleAmount + payoutAmount;
      noclaimCovToken.burnByCover(msg.sender, amount);
    }

    require(eligibleAmount > 0, "Cover: low covToken balance");
    _payCollateral(msg.sender, eligibleAmount);
  }

  /// @notice the owner of this contract is CoverPool contract, the owner of CoverPool is CoverPoolFactory contract
  function _factory() internal view returns (ICoverPoolFactory) {
    return ICoverPoolFactory(IOwnable(owner()).owner());
  }

  function _redeemWithAllCovTokens(ICoverPool coverPool, uint256 _amount) private {
    noclaimCovToken.burnByCover(msg.sender, _amount);
    _handleLatestFutureToken(msg.sender, _amount, false); // burn

    (bytes32[] memory assetList) = coverPool.getAssetList();
    for (uint i = 0; i < assetList.length; i++) {
      ICoverERC20 claimToken = claimCovTokenMap[assetList[i]];
      claimToken.burnByCover(msg.sender, _amount);
    }
    _payCollateral(msg.sender, _amount);
  }

  function _afterFees(uint256 _amount) private view returns (uint256 afterFees) {
    uint256 adjustedAmount = _amount * 1e18 / depositRatio;
    uint256 fees = adjustedAmount * feeNumerator * duration / (feeDenominator * 365 days);
    afterFees = adjustedAmount - fees;
  }

  function _sendFees(uint256 _amount) private {
    IERC20 collateralToken = IERC20(collateral);
    uint256 toTreasury = _amount * 9 / 10;
    collateralToken.safeTransfer(_factory().treasury(), toTreasury);
    // owner of this is Pool, owner of pool is Factory, owner of factory is dev
    address dev = IOwnable(IOwnable(owner()).owner()).owner();
    collateralToken.safeTransfer(dev, _amount - toTreasury);
  }

  function _handleLatestFutureToken(address _receiver, uint256 _amount, bool _isMint) private {
    ICoverERC20[] memory futureCovTokensCopy = futureCovTokens; // save gas
    uint256 len = futureCovTokensCopy.length;
    if (len > 0) {
      // mint or burn latest future token
      ICoverERC20 futureCovToken = futureCovTokensCopy[len - 1];
      _isMint ? futureCovToken.mint(_receiver, _amount) : futureCovToken.burnByCover(_receiver, _amount);
    }
  }

  /// @notice transfer collateral (amount - fee) from this contract to recevier, transfer fee to COVER treasury
  function _payCollateral(address _receiver, uint256 _amount) private {
    totalDebt = totalDebt - _amount;
    IERC20(collateral).safeTransfer(_receiver, _afterFees(_amount));
    collectFees();
  }

  /// @notice burn covToken and pay sender
  function _burnNoclaimAndPay(
    ICoverERC20 _covToken,
    uint256 _payoutNumerator,
    uint256 _payoutDenominator
  ) private {
    uint256 amount = _covToken.balanceOf(msg.sender);
    require(amount > 0, "Cover: low covToken balance");

    _covToken.burnByCover(msg.sender, amount);
    uint256 payoutAmount = amount * _payoutNumerator / _payoutDenominator;
    _payCollateral(msg.sender, payoutAmount);
  }

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() internal view returns (ICoverPool.ClaimDetails memory) {
    return ICoverPool(owner()).getClaimDetails(claimNonce);
  }

  /// @dev Emits CovTokenCreated
  function _createCovToken(string memory _prefix) private returns (ICoverERC20) {
    uint8 decimals = uint8(IERC20(collateral).decimals());
    if (decimals == 0) {
      decimals = 18;
    }
    address coverERC20Impl = _factory().coverERC20Impl();
    bytes32 salt = keccak256(abi.encodePacked(ICoverPool(owner()).name(), expiry, collateral, claimNonce, _prefix));
    address proxyAddr = BasicProxyLib.deployProxy(coverERC20Impl, salt);
    ICovTokenProxy(proxyAddr).initialize(string(abi.encodePacked(_prefix, name)), decimals);

    emit CovTokenCreated(proxyAddr);
    return ICoverERC20(proxyAddr);
  }
}