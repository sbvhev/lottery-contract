// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;
pragma abicoder v2;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/SafeMath.sol";
import "./utils/WadRayMath.sol";
import "./utils/SafeERC20.sol";
import "./utils/StringHelper.sol";
import "./interfaces/IPerpCover.sol";
import "./interfaces/ICoverERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";

/**
 * @title Cover contract
 * @author crypto-pumpkin
 * @notice When a claim is accepted, all PerpCover will payout based on the decision
 */
contract PerpCover is IPerpCover, Initializable, Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using SafeERC20 for IERC20;

  bytes4 private constant COVERERC20_INIT_SIGNITURE = bytes4(keccak256("initialize(string)"));
  uint256 public override createdAt;
  address public override collateral;
  ICoverERC20 public override noclaimCovToken;
  string public override name;
  uint256 public override claimNonce;
  uint256 public override feeFactor; // 18 decimal
  uint256 public override lastUpdatedAt;
  uint256 private lastFeeNum;
  uint256 private lastFeeDen;

  ICoverERC20[] public override claimCovTokens;
  mapping(bytes32 => ICoverERC20) public claimCovTokenMap;

  /// @dev Initialize, called once
  function initialize (
    string calldata _name,
    bytes32[] calldata _assetList,
    address _collateral,
    uint256 _claimNonce
  ) public initializer {
    initializeOwner();
    name = _name;
    createdAt = block.timestamp;
    collateral = _collateral;
    claimNonce = _claimNonce;

    for (uint i = 0; i < _assetList.length; i++) {
      ICoverERC20 claimToken;
      if (_assetList.length > 1) {
        string memory assetName = StringHelper.bytes32ToString(_assetList[i]);
        claimToken = _createCovToken(string(abi.encodePacked("CLAIM_", assetName)));
      } else {
        claimToken = _createCovToken("CLAIM");
      }
      claimCovTokens.push(claimToken);
      claimCovTokenMap[_assetList[i]] = claimToken;
    }
    noclaimCovToken = _createCovToken("NOCLAIM");

    uint256 updatedAt;
    (lastFeeNum,, lastFeeDen, updatedAt) = ICoverPool(owner()).getRedeemFees();
    feeFactor = 1e18;
    lastUpdatedAt = block.timestamp;
  }

  function getCoverDetails()
    external view override
    returns (
      string memory _name,
      uint256 _createdAt,
      address _collateral,
      uint256 _claimNonce,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken)
  {
    return (name, createdAt, collateral, claimNonce, claimCovTokens, noclaimCovToken);
  }

  function viewClaimable(address _account) external view override returns (uint256 eligibleAmount) {
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(_account);
      eligibleAmount = eligibleAmount.add(amount.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
    }
    if (claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(_account);
      uint256 payoutAmount = amount.mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      eligibleAmount = eligibleAmount.add(payoutAmount);
    }
  }

  /*******************************************************************************************
  // @notice Fee factor is the compounding fee multiplier for any given time period.        //
  // e.g. if fee never change (f), feeFactor = 1 / (1 - f)^M                                //
  //                   __                                                                   //
  //                   ||              /      fee numerator at i     \                      //
  //   feeFactor = 1 / ||             | 1 - ------------------------  |                     //
  //                   ||(i in [0-M])  \      fee denominator at i   /                      //
  //                   --                                                                   //
  // M = seconds passed since creation                                                      //
  *******************************************************************************************/
  function updateFeeFactor() public {
    (uint256 feeNumerator,, uint256 poolFeeDenominator, uint256 _poolUpdatedAt) = ICoverPool(owner()).getRedeemFees();

    uint256 _lastUpdatedAt = lastUpdatedAt; // save gas
    uint256 _feeFactor = feeFactor.wadToRay(); // save gas
    uint256 _lastFeeDen = lastFeeDen; // save gas
    uint256 _lastFeeNum = lastFeeNum; // save gas
    // update factor till last updatedAt with last fee rates
    if (_poolUpdatedAt > _lastUpdatedAt) {
      _feeFactor = _getNewFactor(_feeFactor, _lastFeeNum, _lastFeeDen, _poolUpdatedAt.sub(_lastUpdatedAt));
      _lastUpdatedAt = _poolUpdatedAt;
    }

    // update factor till now with latest fee rates
    if (block.timestamp > _lastUpdatedAt) {
      _feeFactor = _getNewFactor(_feeFactor, feeNumerator, poolFeeDenominator, block.timestamp.sub(_lastUpdatedAt));
      lastUpdatedAt = block.timestamp;
    }
    _updateFees(feeNumerator, poolFeeDenominator);
    feeFactor = _feeFactor.rayToWad();
  }

  function _getNewFactor(uint256 _feeFactor, uint256 _feeNumerator, uint256 _feeDenominator, uint256 _secondsPassed) private pure returns (uint256) {
    uint256 year = 365 days;
    uint256 ratePerSecondInRay = _feeNumerator.mul(WadRayMath.ray()).div(year);
    uint256 denominatorInRay = _feeDenominator.mul(WadRayMath.ray());
    uint256 newFactorBase = denominatorInRay.rayDiv(denominatorInRay.sub(ratePerSecondInRay));
    return _feeFactor.rayMul(newFactorBase.rayPow(_secondsPassed));
  }

  function _updateFees(uint256 _feeNumerator, uint256 _feeDenominator) private {
    if (_feeNumerator != lastFeeNum) {
      lastFeeNum = _feeNumerator;
    }
    if (_feeDenominator != lastFeeDen) {
      lastFeeDen = _feeDenominator;
    }
  }

  /// @notice only owner (covered coverPool) can mint, collateral is transfered in CoverPool
  function mint(uint256 _amount, address _receiver) external override onlyOwner {
    _noClaimAcceptedCheck(); // save gas than modifier
    updateFeeFactor();
    uint256 adjustedAmount = _amount.mul(feeFactor).div(1e18);

    ICoverERC20[] memory claimCovTokensCopy = claimCovTokens;
    for (uint i = 0; i < claimCovTokensCopy.length; i++) {
      claimCovTokensCopy[i].mint(_receiver, adjustedAmount);
    }
    noclaimCovToken.mint(_receiver, adjustedAmount);
  }

  /// @notice redeem collateral, only when no claim accepted
  function redeemCollateral(uint256 _amount) external override nonReentrant {
    require(_amount > 0, "PerpCover: amount is 0");
    _noClaimAcceptedCheck(); // save gas than modifier
    ICoverERC20 _noclaimCovToken = noclaimCovToken; // save gas
    require(_amount <= _noclaimCovToken.balanceOf(msg.sender), "PerpCover: low NOCLAIM balance");
    _noclaimCovToken.burnByCover(msg.sender, _amount);

    ICoverPool coverPool = ICoverPool(owner());
    bytes32[] memory assetList = coverPool.getAssetList();
    for (uint i = 0; i < assetList.length; i++) {
      require(_amount <= claimCovTokenMap[assetList[i]].balanceOf(msg.sender), "PerpCover: low CLAIM balance");
      claimCovTokenMap[assetList[i]].burnByCover(msg.sender, _amount);
    }
    updateFeeFactor();
    _payAmount(msg.sender, _amount);
    _sendAccuFeesToTreasury(_noclaimCovToken.totalSupply());
  }

  /// @notice redeem claimable account with covTokens, only if there is a claim accepted and delayWithClaim period passed
  function redeemClaim() external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    require(coverPool.claimNonce() > claimNonce, "PerpCover: no claim accepted");
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    require(block.timestamp >= uint256(claim.claimEnactedTimestamp).add(coverPool.claimRedeemDelay()), "PerpCover: not ready");

    uint256 eligibleAmount;
    uint256 totalDebt;
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(msg.sender);
      eligibleAmount = eligibleAmount.add(amount.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
      covToken.burnByCover(msg.sender, amount);
      uint256 remSupply = covToken.totalSupply();
      totalDebt = totalDebt.add(remSupply.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
    }

    if (claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(msg.sender);
      uint256 payoutAmount = amount.mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      noclaimCovToken.burnByCover(msg.sender, amount);
      eligibleAmount = eligibleAmount.add(payoutAmount);
      uint256 totalNoclaimDebt = noclaimCovToken.totalSupply().mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      totalDebt = totalDebt.add(totalNoclaimDebt);
    }
    require(eligibleAmount > 0, "PerpCover: amount is 0");

    updateFeeFactor();
    _payAmount(msg.sender, eligibleAmount);
    _sendAccuFeesToTreasury(totalDebt);
  }

  /// @notice the owner of this contract is CoverPool contract, the owner of CoverPool is CoverPoolFactory contract
  function _factory() private view returns (address) {
    return IOwnable(owner()).owner();
  }

  /// @notice make sure no claim is accepted
  function _noClaimAcceptedCheck() private view {
    require(ICoverPool(owner()).claimNonce() == claimNonce, "PerpCover: claim accepted");
  }

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() private view returns (ICoverPool.ClaimDetails memory) {
    return ICoverPool(owner()).getClaimDetails(claimNonce);
  }

  /// @notice Payable amount is discounted based on the current feeFactor
  function _payAmount(address _receiver, uint256 _amount) private {
    IERC20 collateralToken = IERC20(collateral);
    collateralToken.safeTransfer(_receiver, _amount.mul(1e18).div(feeFactor));
  }

  /// @notice 99.9% of (vault Value - debt owed) is send to treasury if > 0.001 ether unit
  function _sendAccuFeesToTreasury(uint256 _debtTotal) private {
    IERC20 collateralToken = IERC20(collateral);
    ICoverPoolFactory factory = ICoverPoolFactory(_factory());
    address treasury = factory.treasury();
    
    if (_debtTotal == 0) {
      collateralToken.safeTransfer(treasury, collateralToken.balanceOf(address(this)));
    } else {
      uint256 accuFees = collateralToken.balanceOf(address(this)).sub(_debtTotal.mul(1e18).div(feeFactor));
      if (accuFees > 0.001 ether) {
        // add a buffer to avoid error caused by + dust to users
        collateralToken.safeTransfer(treasury, accuFees.mul(999).div(1000));
      }
    }
  }

  /// @dev Emits NewCovTokenCreation
  function _createCovToken(string memory _prefix) private returns (ICoverERC20) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    bytes32 salt = keccak256(abi.encodePacked(ICoverPool(owner()).name(), createdAt, collateral, claimNonce, _prefix));
    address payable proxyAddr = Create2.deploy(0, salt, bytecode);

    bytes memory initData = abi.encodeWithSelector(COVERERC20_INIT_SIGNITURE, string(abi.encodePacked(_prefix, "_", name)));
    address coverERC20Impl = ICoverPoolFactory(_factory()).coverERC20Impl();
    InitializableAdminUpgradeabilityProxy(proxyAddr).initialize(
      coverERC20Impl,
      IOwnable(_factory()).owner(),
      initData
    );

    emit NewCovTokenCreation(proxyAddr);
    return ICoverERC20(proxyAddr);
  }
}