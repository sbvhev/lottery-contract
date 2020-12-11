// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;
pragma abicoder v2;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/SafeMath.sol";
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
 * @author crypto-pumpkin@github
 * When a claim is accepted, all PerpCover will payout based on the decision
 *
 * The contract
 *  - Holds collateral funds
 *  - Mints and burns CovTokens (CoverERC20)
 *  - Allows redeem from collateral pool with or without an accepted claim
 */
contract PerpCover is IPerpCover, Initializable, Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  bytes4 private constant COVERERC20_INIT_SIGNITURE = bytes4(keccak256("initialize(string)"));
  uint256 public override createdAt;
  address public override collateral;
  ICoverERC20 public override noclaimCovToken;
  string public override name;
  uint256 public override claimNonce;
  uint256 public override rolloverPeriod;
  uint256 public constant BASE = 10**18;
  uint256 private feeFactor;
  uint256 private baseFeeFactor;
  uint256 private feePeriodCounts;
  uint256 private lastFeeNum;
  uint256 private lastFeeDen;

  ICoverERC20[] public override claimCovTokens;
  mapping(bytes32 => ICoverERC20) public claimCovTokenMap;

  /// @dev Initialize, called once
  function initialize (
    string calldata _name,
    uint256 _rolloverPeriod,
    bytes32[] calldata _assetList,
    address _collateral,
    uint256 _claimNonce
  ) public initializer {
    name = _name;
    rolloverPeriod = _rolloverPeriod;
    createdAt = block.timestamp;
    collateral = _collateral;
    claimNonce = _claimNonce;

    initializeOwner();
    require(_rolloverPeriod > 0, "PerCover: _rolloverPeriod is 0");

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

    (lastFeeNum,, lastFeeDen,) = ICoverPool(owner()).getRedeemFees();
    baseFeeFactor = lastFeeDen.mul(BASE).div(lastFeeDen.sub(lastFeeNum)); // > 1
    feeFactor = BASE;
    feePeriodCounts = 1;
  }

  function getCoverDetails()
    external view override returns (string memory _name, uint256 _rolloverPeriod, uint256 _createdAt, address _collateral, uint256 _claimNonce, ICoverERC20[] memory _claimCovTokens, ICoverERC20 _noclaimCovToken)
  {
    return (name, rolloverPeriod, createdAt, collateral, claimNonce, claimCovTokens, noclaimCovToken);
  }
  
  /// @notice multiplier = 1 + math.floor(timepassed / rolloverPeriod)
  function getPassedPeriodCount(uint256 _timestamp) public view returns (uint256) {
    return uint256(_timestamp.add(rolloverPeriod).sub(createdAt)) / rolloverPeriod;
  }

  function viewClaimable() external view returns (uint256 totalAmount) {
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(msg.sender);
      totalAmount = totalAmount.add(amount.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
    }

    if(claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(msg.sender);
      uint256 payoutAmount = amount.mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      totalAmount = totalAmount.add(payoutAmount);
    }
  }

  function updateFeeFactor() public {
    (uint256 redeemFeePerpNumerator,, uint256 redeemFeeDenominator, uint256 _updatedAt) = ICoverPool(owner()).getRedeemFees();

    // update factor till last updatedAt with last fee rates    
    uint256 updatePassed = getPassedPeriodCount(_updatedAt);
    uint256 netUpdatePassed = updatePassed <= feePeriodCounts ? 0 : updatePassed.sub(feePeriodCounts);
    for (uint256 i = 0; i < netUpdatePassed; i++) {
      feeFactor = feeFactor.mul(lastFeeDen).div(lastFeeDen.sub(lastFeeNum));
    }

    // update fee rates to new rate
    if (redeemFeePerpNumerator != lastFeeNum || redeemFeeDenominator != lastFeeDen) {
      lastFeeNum = redeemFeePerpNumerator;
      lastFeeDen = redeemFeeDenominator;
      if (netUpdatePassed == 0 && feePeriodCounts == 1) {
        // when fees changed before even 1 rollover Period passed, update base fee factor
        baseFeeFactor = lastFeeDen.mul(BASE).div(lastFeeDen.sub(lastFeeNum));
      }
    }

    // update factor till now with latest fee rates   
    uint256 currentPassed = getPassedPeriodCount(block.timestamp);
    uint256 netCurrentPassed = currentPassed.sub(feePeriodCounts.add(netUpdatePassed));
    for (uint256 j = 0; j < netCurrentPassed; j++) {
      feeFactor = feeFactor.mul(lastFeeDen).div(lastFeeDen.sub(lastFeeNum));
    }
    feePeriodCounts = currentPassed;
  }

  /// @notice only owner (covered coverPool) can mint, collateral is transfered in CoverPool
  function mint(uint256 _amount, address _receiver) external override onlyOwner {
    _noClaimAcceptedCheck(); // save gas than modifier
    ICoverERC20[] memory claimCovTokensCopy = claimCovTokens;
    updateFeeFactor();
    // every passed rolloverPeriod, the amount mint for each collateral will = (1 - fee%) / (1 - mulitplier * fee%)
    // this is to compensate the later minters as if they redeem, they will have to pay (1 - mulitplier * fee%) fees
    uint256 adjustedAmount = _amount.mul(feeFactor).div(BASE);

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

    ICoverERC20[] memory claimCovTokensCopy = claimCovTokens; // save gas
    for (uint i = 0; i < claimCovTokensCopy.length; i++) {
      require(_amount <= claimCovTokensCopy[i].balanceOf(msg.sender), "PerpCover: low CLAIM balance");
      claimCovTokensCopy[i].burnByCover(msg.sender, _amount);
    }
    updateFeeFactor();
    _payShare(msg.sender, _amount);
    _sendAccuFeesToTreasury(_noclaimCovToken.totalSupply());
  }

  /// @notice redeem claimable account with covTokens, only if there is a claim accepted and delayWithClaim period passed
  function redeemClaim() external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    require(coverPool.claimNonce() > claimNonce, "PerpCover: no claim accepted");

    ICoverPool.ClaimDetails memory claim = _claimDetails();
    require(block.timestamp >= uint256(claim.claimEnactedTimestamp) + coverPool.claimRedeemDelay(), "PerpCover: not ready");

    uint256 totalAmount;
    uint256 totalDebt;
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(msg.sender);
      totalAmount = totalAmount.add(amount.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
      covToken.burnByCover(msg.sender, amount);
      uint256 remSupply = covToken.totalSupply();
      totalDebt = totalDebt.add(remSupply.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
    }

    if(claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(msg.sender);
      uint256 payoutAmount = amount.mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      noclaimCovToken.burnByCover(msg.sender, amount);
      totalAmount = totalAmount.add(payoutAmount);
      uint256 totalNoclaimDebt = noclaimCovToken.totalSupply().mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      totalDebt = totalDebt.add(totalNoclaimDebt);
    }
    require(totalAmount > 0, "PerpCover: amount is 0");

    updateFeeFactor();
    _payShare(msg.sender, totalAmount);
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

  function _payShare(address _receiver, uint256 _amount) private {
    IERC20 collateralToken = IERC20(collateral);
    collateralToken.safeTransfer(_receiver, _amount.mul(BASE).div(baseFeeFactor).mul(BASE).div(feeFactor));
  }

  function _sendAccuFeesToTreasury(uint256 _debtTotal) private {
    IERC20 collateralToken = IERC20(collateral);
    ICoverPoolFactory factory = ICoverPoolFactory(_factory());
    address treasury = factory.treasury();
    
    if (_debtTotal == 0) {
      collateralToken.safeTransfer(treasury, collateralToken.balanceOf(address(this)));
    } else {
      uint256 accuFees = collateralToken.balanceOf(address(this)).sub(_debtTotal.mul(BASE).div(baseFeeFactor).mul(BASE).div(feeFactor));
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