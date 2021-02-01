// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./ERC20/SafeERC20.sol";
import "./ERC20/IERC20.sol";
import "./proxy/Clones.sol";
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
  string private name; // Yearn_0_DAI_210131
  uint256 public override feeRate; // 1e18, cannot be changed
  uint256 private mintRatio; // 1e18, cannot be changed, 1 collateral mint mintRatio * 1 covTokens
  uint256 private totalCoverage; // in covTokens
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
    uint256 yearlyFeeRate = _factory().yearlyFeeRate();
    feeRate = yearlyFeeRate * (uint256(_expiry) - block.timestamp) / 365 days;

    noclaimCovToken = _createCovToken("NC_");
    futureCovTokens.push(_createCovToken("C_FUT0_"));
    deploy();
  }

  /// @notice only CoverPool can mint, collateral is transfered in CoverPool
  function mint(uint256 _receivedColAmt, address _receiver) external override onlyOwner {
    ICoverPool coverPool = _coverPool();
    require(deployComplete, "Cover: deploy incomplete");
    require(coverPool.claimNonce() == claimNonce, "Cover: claim accepted");
    IERC20(collateral).safeTransfer(_factory().treasury(), _receivedColAmt * feeRate / 1e18);

    uint256 mintAmount = _receivedColAmt * mintRatio / 1e18;
    totalCoverage = totalCoverage + mintAmount;

    (bytes32[] memory _riskList) = coverPool.getRiskList();
    for (uint i = 0; i < _riskList.length; i++) {
      claimCovTokenMap[_riskList[i]].mint(_receiver, mintAmount);
    }
    noclaimCovToken.mint(_receiver, mintAmount);
    _handleLatestFutureToken(_receiver, mintAmount, true); // mint
  }

  /// @notice redeem collateral always allow redeem back collateral with all covTokens
  function redeemCollateral(uint256 _amount) external override nonReentrant {
    ICoverPool coverPool = _coverPool();
    uint256 noclaimRedeemDelay = coverPool.noclaimRedeemDelay();
    uint256 defaultRedeemDelay = _factory().defaultRedeemDelay();

    if (coverPool.claimNonce() > claimNonce) { // accepted claim
      ICoverPool.ClaimDetails memory claim = _claimDetails();
      if (claim.incidentTimestamp > expiry && block.timestamp >= uint256(expiry) + defaultRedeemDelay) {
        // not affected cover, redeem with noclaim tokens only
        _burnNoclaimAndPay(noclaimCovToken, 1e18);
        return;
      }
    } else if (block.timestamp >= uint256(expiry) + noclaimRedeemDelay) {
      // expired and noclaim delay passed, no accepted claim, redeem with noclaim tokens only
      _burnNoclaimAndPay(noclaimCovToken, 1e18);
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

    ICoverERC20[] memory futureCovTokensCopy = futureCovTokens;
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
    ICoverPool coverPool = _coverPool();
    require(coverPool.claimNonce() > claimNonce, "Cover: no claim accepted");
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    require(claim.incidentTimestamp <= expiry, "Cover: not eligible, redeem collateral instead");
    uint256 defaultRedeemDelay = _factory().defaultRedeemDelay();
    require(block.timestamp >= uint256(claim.claimEnactedTimestamp) + defaultRedeemDelay, "Cover: not ready");

    // get all claim tokens eligible amount
    uint256 eligibleAmount;
    for (uint256 i = 0; i < claim.payoutRiskList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutRiskList[i]];
      uint256 amount = covToken.balanceOf(msg.sender);
      eligibleAmount = eligibleAmount + amount * claim.payoutRates[i] / 1e18;
      covToken.burnByCover(msg.sender, amount);
    }
    // get noclaim token eligible amount
    if (claim.payoutTotalRate < 1e18) {
      uint256 amount = noclaimCovToken.balanceOf(msg.sender);
      uint256 payoutAmount = amount * (1e18 - claim.payoutTotalRate) / 1e18;
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
      eligibleAmount = eligibleAmount + amount * claim.payoutRates[i] / 1e18;
    }
    if (claim.payoutTotalRate < 1e18) {
      uint256 amount = noclaimCovToken.balanceOf(_account);
      uint256 payoutAmount = amount * (1e18 - claim.payoutTotalRate) / 1e18;
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
    (bytes32[] memory _riskList) = _coverPool().getRiskList();
    ICoverERC20[] memory claimCovTokens = new ICoverERC20[](_riskList.length);
    for (uint256 i = 0; i < _riskList.length; i++) {
      claimCovTokens[i] = ICoverERC20(claimCovTokenMap[_riskList[i]]);
    }
    return (name, expiry, collateral, mintRatio, feeRate, claimNonce, noclaimCovToken, claimCovTokens, futureCovTokens);
  }

  /// @notice convert the future token to claim token and mint next future token
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

  /// @notice multi-tx/block deployment solution. Only called (1+ times depend on size of pool) at creation. Deploy covTokens as many as possible in one tx till not enough gas left.
  function deploy() public override {
    require(!deployComplete, "Cover: deploy completed");
    (bytes32[] memory _riskList) = _coverPool().getRiskList();
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

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() private view returns (ICoverPool.ClaimDetails memory) {
    return _coverPool().getClaimDetails(claimNonce);
  }

  function _redeemWithAllCovTokens(ICoverPool coverPool, uint256 _amount) private {
    noclaimCovToken.burnByCover(msg.sender, _amount);
    _handleLatestFutureToken(msg.sender, _amount, false); // burn

    (bytes32[] memory riskList) = coverPool.getRiskList();
    for (uint i = 0; i < riskList.length; i++) {
      claimCovTokenMap[riskList[i]].burnByCover(msg.sender, _amount);
    }
    _payCollateral(msg.sender, _amount);
  }

  function _handleLatestFutureToken(address _receiver, uint256 _amount, bool _isMint) private {
    ICoverERC20[] memory futureCovTokensCopy = futureCovTokens;
    uint256 len = futureCovTokensCopy.length;
    if (len == 0) return;
    ICoverERC20 futureCovToken = futureCovTokensCopy[len - 1];
    _isMint ? futureCovToken.mint(_receiver, _amount) : futureCovToken.burnByCover(_receiver, _amount);
  }

  // transfer collateral (amount - fee) from this contract to recevier
  function _payCollateral(address _receiver, uint256 _covarageAmt) private {
    IERC20 colToken = IERC20(collateral);
    uint256 colBal = colToken.balanceOf(address(this));
    uint256 payoutColAmount = _covarageAmt * colBal / totalCoverage;
    totalCoverage = totalCoverage - _covarageAmt;
    if (colBal > payoutColAmount) {
      colToken.safeTransfer(_receiver, payoutColAmount);
    } else {
      colToken.safeTransfer(_receiver, colBal);
    }
  }

  // burn covToken and pay sender
  function _burnNoclaimAndPay(ICoverERC20 _covToken, uint256 _payoutRate) private {
    uint256 amount = _covToken.balanceOf(msg.sender);
    require(amount > 0, "Cover: low covToken balance");

    _covToken.burnByCover(msg.sender, amount);
    uint256 payoutAmount = amount * _payoutRate / 1e18;
    _payCollateral(msg.sender, payoutAmount);
  }

  /// @dev Emits CovTokenCreated
  function _createCovToken(string memory _prefix) private returns (ICoverERC20) {
    uint8 decimals = uint8(IERC20(collateral).decimals());
    if (decimals == 0) {
      decimals = 18;
    }
    address coverERC20Impl = _factory().coverERC20Impl();
    bytes32 salt = keccak256(abi.encodePacked(_coverPool().name(), expiry, collateral, claimNonce, _prefix));
    address proxyAddr = Clones.cloneDeterministic(coverERC20Impl, salt);
    ICovTokenProxy(proxyAddr).initialize(string(abi.encodePacked(_prefix, name)), decimals);

    emit CovTokenCreated(proxyAddr);
    return ICoverERC20(proxyAddr);
  }

  function _coverPool() private view returns (ICoverPool) {
    return ICoverPool(owner());
  }

  // the owner of this contract is CoverPool, the owner of CoverPool is CoverPoolFactory contract
  function _factory() private view returns (ICoverPoolFactory) {
    return ICoverPoolFactory(IOwnable(owner()).owner());
  }
}