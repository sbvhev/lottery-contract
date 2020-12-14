// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;
pragma abicoder v2;

import "./proxy/BasicProxyLib.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/SafeMath.sol";
import "./utils/SafeERC20.sol";
import "./utils/StringHelper.sol";
import "./interfaces/ICoverWithExpiry.sol";
import "./interfaces/ICoverERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";
import "./interfaces/ICovTokenProxy.sol";

/**
 * @title CoverWithExpiry contract
 * @author crypto-pumpkin
 *
 * The contract
 *  - Holds collateral funds
 *  - Mints and burns CovTokens (CoverERC20)
 *  - Allows redeem from collateral pool with or without an accepted claim
 */
contract CoverWithExpiry is ICoverWithExpiry, Initializable, Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  bytes4 private constant COVERERC20_INIT_SIGNITURE = bytes4(keccak256("initialize(string)"));
  string public override name;
  uint48 public override expiry;
  address public override collateral;
  ICoverERC20 public override noclaimCovToken;
  uint256 public override claimNonce;
  uint256 public override duration;
  ICoverERC20[] public override claimCovTokens;
  mapping(bytes32 => ICoverERC20) public claimCovTokenMap;

  /// @dev Initialize, called once
  function initialize (
    string calldata _name,
    bytes32[] calldata _assetList,
    uint48 _expiry,
    address _collateral,
    uint256 _claimNonce
  ) public initializer {
    initializeOwner();
    name = _name;
    expiry = _expiry;
    collateral = _collateral;
    claimNonce = _claimNonce;
    duration = uint256(_expiry).sub(block.timestamp);

    for (uint i = 0; i < _assetList.length; i++) {
      ICoverERC20 claimToken;
      string memory assetName = StringHelper.bytes32ToString(_assetList[i]);
      claimToken = _createCovToken(string(abi.encodePacked("CLAIM_", assetName)));
      claimCovTokens.push(claimToken);
      claimCovTokenMap[_assetList[i]] = claimToken;
    }
    noclaimCovToken = _createCovToken("NOCLAIM");
  }

  function getCoverDetails()
    external view override
    returns (
      string memory _name,
      uint48 _expiry,
      address _collateral,
      uint256 _claimNonce,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken)
  {
    return (name, expiry, collateral, claimNonce, claimCovTokens, noclaimCovToken);
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

  /// @notice only owner (covered coverPool) can mint, collateral is transfered in CoverPool
  function mint(uint256 _amount, address _receiver) external override onlyOwner {
    _noClaimAcceptedCheck(); // save gas than modifier
    ICoverERC20[] memory claimCovTokensCopy = claimCovTokens;
    for (uint i = 0; i < claimCovTokensCopy.length; i++) {
      claimCovTokensCopy[i].mint(_receiver, _amount);
    }
    noclaimCovToken.mint(_receiver, _amount);
  }

  /// @notice redeem when there is an accepted claim
  function redeemClaim() external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    require(coverPool.claimNonce() > claimNonce, "CoverWithExpiry: no claim accepted");

    ICoverPool.ClaimDetails memory claim = _claimDetails();
    require(claim.incidentTimestamp <= expiry, "CoverWithExpiry: not eligible, redeem collateral instead");
    require(block.timestamp >= uint256(claim.claimEnactedTimestamp).add(coverPool.claimRedeemDelay()), "CoverWithExpiry: not ready");

    uint256 eligibleAmount;
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(msg.sender);
      eligibleAmount = eligibleAmount.add(amount.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
      covToken.burnByCover(msg.sender, amount);
    }

    if (claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(msg.sender);
      uint256 payoutAmount = amount.mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      eligibleAmount = eligibleAmount.add(payoutAmount);
      noclaimCovToken.burnByCover(msg.sender, amount);
    }

    require(eligibleAmount > 0, "CoverWithExpiry: low covToken balance");
    _payCollateral(msg.sender, eligibleAmount);
  }

  /// @notice redeem collateral, only when no claim accepted. If expired (with or withour claim), _amount is not respected
  function redeemCollateral(uint256 _amount) external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    if (coverPool.claimNonce() > claimNonce) {
      // there is an accepted claim, redeem back all if incident time must > expiry to redeem collateral
      ICoverPool.ClaimDetails memory claim = _claimDetails();
      require(claim.incidentTimestamp > expiry, "CoverWithExpiry: claimable covTokens cannot redeem collateral");
      require(block.timestamp >= uint256(claim.claimEnactedTimestamp).add(coverPool.noclaimRedeemDelay()), "CoverWithExpiry: not ready");
      _burnCovTokenAndPay(noclaimCovToken, 1, 1);
    } else {
      require(_amount > 0, "CoverWithExpiry: amount is 0");
      
      if (block.timestamp < expiry) {
        // there is NO accepted claim, not expired
        ICoverERC20 _noclaimCovToken = noclaimCovToken; // save gas
        _noclaimCovToken.burnByCover(msg.sender, _amount);

        (bytes32[] memory assetList,) = coverPool.getAssetLists();
        for (uint i = 0; i < assetList.length; i++) {
          ICoverERC20 claimToken = claimCovTokenMap[assetList[i]];
          claimToken.burnByCover(msg.sender, _amount);
        }
        _payCollateral(msg.sender, _amount);
      } else {
        // there is NO accepted claim, expired, redeem back all
        require(block.timestamp >= uint256(expiry).add(coverPool.noclaimRedeemDelay()), "CoverWithExpiry: not ready");
        _burnCovTokenAndPay(noclaimCovToken, 1, 1);
      }
    }
  }

  /// @notice the owner of this contract is CoverPool contract, the owner of CoverPool is CoverPoolFactory contract
  function _factory() private view returns (address) {
    return IOwnable(owner()).owner();
  }

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() private view returns (ICoverPool.ClaimDetails memory) {
    return ICoverPool(owner()).getClaimDetails(claimNonce);
  }

  /// @notice make sure no claim is accepted
  function _noClaimAcceptedCheck() private view {
    require(ICoverPool(owner()).claimNonce() == claimNonce, "CoverWithExpiry: claim accepted");
  }

  /// @notice transfer collateral (amount - fee) from this contract to recevier, transfer fee to COVER treasury
  function _payCollateral(address _receiver, uint256 _amount) private {
    ICoverPoolFactory factory = ICoverPoolFactory(_factory());
    (,uint256 expiryFeeNum, uint256 feeDenominator,) = ICoverPool(owner()).getRedeemFees();
    uint256 fee = _amount.mul(expiryFeeNum).div(feeDenominator).mul(duration).div(365 days);
    address treasury = factory.treasury();
    IERC20 collateralToken = IERC20(collateral);

    collateralToken.safeTransfer(_receiver, _amount.sub(fee));
    collateralToken.safeTransfer(treasury, fee);
  }

  /// @notice burn covToken and pay sender
  function _burnCovTokenAndPay(
    ICoverERC20 _covToken,
    uint256 _payoutNumerator,
    uint256 _payoutDenominator
  ) private {
    require(_payoutNumerator <= _payoutDenominator, "CoverWithExpiry: payout % is > 100%");
    require(_payoutNumerator > 0, "CoverWithExpiry: payout % < 0%");
    uint256 amount = _covToken.balanceOf(msg.sender);
    require(amount > 0, "CoverWithExpiry: low covToken balance");

    _covToken.burnByCover(msg.sender, amount);
    uint256 payoutAmount = amount.mul(_payoutNumerator).div(_payoutDenominator);
    _payCollateral(msg.sender, payoutAmount);
  }

  /// @dev Emits NewCovTokenCreation
  function _createCovToken(string memory _prefix) private returns (ICoverERC20) {
    address coverERC20Impl = ICoverPoolFactory(_factory()).coverERC20Impl();
    bytes32 salt = keccak256(abi.encodePacked(ICoverPool(owner()).name(), expiry, collateral, claimNonce, _prefix));
    address proxyAddr = BasicProxyLib.deployProxy(coverERC20Impl, salt);
    ICovTokenProxy(proxyAddr).initialize(string(abi.encodePacked(_prefix, "_", name)));

    emit NewCovTokenCreation(proxyAddr);
    return ICoverERC20(proxyAddr);
  }
}