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
  // 1e18 cover feeRate, based on yearly feeRate on CoverPool, cannot be changed
  uint256 public override feeRate;
  // 1e18 created as initialization, cannot be changed, used to decided the collateral to covToken ratio
  uint256 private mintRatio;
  uint256 private totalCoverage;
  uint256 public override claimNonce;

  ICoverERC20[] private futureCovTokens;
  mapping(bytes32 => ICoverERC20) public override claimCovTokenMap;
  // future token => CLAIM Token
  mapping(ICoverERC20 => ICoverERC20) public override futureCovTokenMap;

  /// @dev Initialize, called once
  function initialize (
    string calldata _name,
    uint48 _expiry,
    address _collateral,
    uint256 _mintRatio,
    uint256 _claimNonce
  ) public initializer {
    initializeOwner();
    name = _name;
    expiry = _expiry;
    collateral = _collateral;
    mintRatio = _mintRatio;
    claimNonce = _claimNonce;
    uint256 yearlyFeeRate = ICoverPool(owner()).yearlyFeeRate();
    feeRate = yearlyFeeRate * (uint256(_expiry) - block.timestamp) / 365 days;

    noclaimCovToken = _createCovToken("NC_");
    futureCovTokens.push(_createCovToken("C_FUT0_"));
    deploy();
  }

  /// @notice only owner (covered coverPool) can mint, collateral is transfered in CoverPool
  function mint(uint256 _amount, address _receiver) external override onlyOwner {
    require(deployComplete, "Cover: deploy incomplete");
    require(ICoverPool(owner()).claimNonce() == claimNonce, "Cover: claim accepted");

    uint256 adjustedAmount = _amount * mintRatio / 1e18;
    (bytes32[] memory _riskList) = ICoverPool(owner()).getRiskList();
    for (uint i = 0; i < _riskList.length; i++) {
      claimCovTokenMap[_riskList[i]].mint(_receiver, adjustedAmount);
    }
    noclaimCovToken.mint(_receiver, adjustedAmount);
    _handleLatestFutureToken(_receiver, adjustedAmount, true); // mint
    totalCoverage = totalCoverage + adjustedAmount;
    collectFees();
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

  function convertAll(ICoverERC20[] calldata _futureTokens) external override {
    for (uint256 i = 0; i < _futureTokens.length; i++) {
      convert(_futureTokens[i]);
    }
  }

  /**
   * @notice called by owner (CoverPool) only, when a new risk is added to pool the first time
   * - create a new claim token for risk
   * - point the current latest (last one in futureCovTokens) to newly created claim token
   * - create a new future token and push to futureCovTokens
   */
  function addRisk(bytes32 _risk) external override onlyOwner {
    if (block.timestamp >= expiry) return;
    // make sure new risk has not already been added
    if (address(claimCovTokenMap[_risk]) != address(0)) return;

    ICoverERC20[] memory futureCovTokensCopy = futureCovTokens; // save gas
    uint256 len = futureCovTokensCopy.length;
    ICoverERC20 futureCovToken = futureCovTokensCopy[len - 1];

    string memory riskName = StringHelper.bytes32ToString(_risk);
    ICoverERC20 claimToken = _createCovToken(string(abi.encodePacked("C_", riskName, "_")));
    claimCovTokenMap[_risk] = claimToken;
    futureCovTokenMap[futureCovToken] = claimToken;

    string memory nextFutureTokenName = string(abi.encodePacked("C_FUT", StringHelper.uintToString(len), "_"));
    futureCovTokens.push(_createCovToken(nextFutureTokenName));
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
    for (uint256 i = 0; i < claim.payoutRiskList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutRiskList[i]];
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

  function viewClaimable(address _account) external view override returns (uint256 eligibleAmount) {
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    for (uint256 i = 0; i < claim.payoutRiskList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutRiskList[i]];
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
      uint256 _mintRatio,
      uint256 _feeRate,
      uint256 _claimNonce,
      ICoverERC20 _noclaimCovToken,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20[] memory _futureCovTokens)
  {
    (bytes32[] memory _riskList) = ICoverPool(owner()).getRiskList();
    ICoverERC20[] memory claimCovTokens = new ICoverERC20[](_riskList.length);
    for (uint256 i = 0; i < _riskList.length; i++) {
      claimCovTokens[i] = ICoverERC20(claimCovTokenMap[_riskList[i]]);
    }
    return (name, expiry, collateral, mintRatio, feeRate, claimNonce, noclaimCovToken, claimCovTokens, futureCovTokens);
  }

  function collectFees() public override {
    IERC20 collateralToken = IERC20(collateral);
    if (totalCoverage == 0) {
      _sendFees(collateralToken.balanceOf(address(this)));
      return;
    }
    uint256 feeToCollect = collateralToken.balanceOf(address(this)) - _getAmountAfterFees(totalCoverage);
    if (feeToCollect > 10) {
      // minus 1 to avoid dust caused inBalance
      _sendFees(feeToCollect - 1);
    }
  }

  /// @notice convert last future token to claim token and lastest future token
  function convert(ICoverERC20 _futureToken) public override {
    ICoverERC20 claimCovToken = futureCovTokenMap[_futureToken];
    require(address(claimCovToken) != address(0), "Cover: nothing to convert");
    uint256 amount = _futureToken.balanceOf(msg.sender);
    require(amount > 0, "Cover: insufficient balance");
    _futureToken.burnByCover(msg.sender, amount);
    claimCovToken.mint(msg.sender, amount);

    // mint next future covTokens
    ICoverERC20[] memory futureCovTokensCopy = futureCovTokens;
    for (uint256 i = 0; i < futureCovTokensCopy.length; i++) {
      if (futureCovTokensCopy[i] == _futureToken) {
        ICoverERC20 futureCovToken = futureCovTokensCopy[i + 1];
        futureCovToken.mint(msg.sender, amount);
        return;
      }
    }
  }

  /**
   * @dev multi-tx/block deployment solution. Only called (1+ times depend on size of pool) at creation.
   * Deploy covTokens as many as possible till not enough gas left. 
   */
  function deploy() public override {
    require(!deployComplete, "Cover: deploy completed");
    (bytes32[] memory _riskList) = ICoverPool(owner()).getRiskList();
    uint256 startGas = gasleft();
    for (uint256 i = 0; i < _riskList.length; i++) {
      if (startGas < _factory().deployGasMin()) return;
      ICoverERC20 claimToken = claimCovTokenMap[_riskList[i]];
      if (address(claimToken) == address(0)) {
        string memory riskName = StringHelper.bytes32ToString(_riskList[i]);
        claimToken = _createCovToken(string(abi.encodePacked("C_", riskName, "_")));
        claimCovTokenMap[_riskList[i]] = claimToken;
        startGas = gasleft();
      }
    }
    deployComplete = true;
    emit CoverDeployCompleted();
  }

  /// @notice the owner of this contract is CoverPool contract, the owner of CoverPool is CoverPoolFactory contract
  function _factory() internal view returns (ICoverPoolFactory) {
    return ICoverPoolFactory(IOwnable(owner()).owner());
  }

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() internal view returns (ICoverPool.ClaimDetails memory) {
    return ICoverPool(owner()).getClaimDetails(claimNonce);
  }

  function _redeemWithAllCovTokens(ICoverPool coverPool, uint256 _amount) private {
    noclaimCovToken.burnByCover(msg.sender, _amount);
    _handleLatestFutureToken(msg.sender, _amount, false); // burn

    (bytes32[] memory riskList) = coverPool.getRiskList();
    for (uint i = 0; i < riskList.length; i++) {
      ICoverERC20 claimToken = claimCovTokenMap[riskList[i]];
      claimToken.burnByCover(msg.sender, _amount);
    }
    _payCollateral(msg.sender, _amount);
  }

  function _sendFees(uint256 _totalFees) private {
    IERC20 collateralToken = IERC20(collateral);
    uint256 feesToTreasury = _totalFees * 9 / 10;
    collateralToken.safeTransfer(_factory().treasury(), feesToTreasury);
    // owner of this is Pool, owner of pool is Factory, owner of factory is dev
    address dev = IOwnable(IOwnable(owner()).owner()).owner();
    collateralToken.safeTransfer(dev, _totalFees - feesToTreasury);
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
    totalCoverage = totalCoverage - _amount;
    IERC20(collateral).safeTransfer(_receiver, _getAmountAfterFees(_amount));
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

  function _getAmountAfterFees(uint256 _amount) private view returns (uint256 amountAfterFees) {
    // mintRatio & feeRate are both 1e18
    uint256 adjustedAmount = _amount * 1e18 / mintRatio;
    uint256 fees = adjustedAmount * feeRate / 1e18;
    amountAfterFees = adjustedAmount - fees;
  }
}