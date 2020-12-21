// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./proxy/BasicProxyLib.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/SafeERC20.sol";
import "./utils/StringHelper.sol";
import "./interfaces/ICover.sol";
import "./interfaces/ICoverERC20.sol";
import "./interfaces/IERC20.sol";
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
 *  - Allows redeem from collateral pool with or without an accepted claim
 */
contract Cover is ICover, Initializable, ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;

  bytes4 private constant COVERERC20_INIT_SIGNITURE = bytes4(keccak256("initialize(string,uint8)"));
  bool public override deployComplete;
  uint48 public override expiry;
  address public override collateral;
  /// @notice e18 created as initialization, cannot be changed, used to decided the collateral to covToken ratio
  uint256 public override depositRatio;
  ICoverERC20 public override noclaimCovToken;
  string public override name;
  uint256 public override claimNonce;
  uint256 public override duration;

  ICoverERC20[] public override claimCovTokens;
  mapping(bytes32 => ICoverERC20) public claimCovTokenMap;

  /// @dev Initialize, called once
  function initialize (
    string calldata _name,
    uint48 _expiry,
    address _collateral,
    uint256 _depositRatio,
    uint256 _claimNonce
  ) public initializer {
    initializeOwner();
    name = _name;
    expiry = _expiry;
    collateral = _collateral;
    depositRatio = _depositRatio;
    claimNonce = _claimNonce;
    duration = uint256(_expiry) - block.timestamp;

    noclaimCovToken = _createCovToken("NOCLAIM");
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
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken)
  {
    return (name, expiry, collateral, depositRatio, claimNonce, claimCovTokens, noclaimCovToken);
  }

  /// @notice only owner (covered coverPool) can mint, collateral is transfered in CoverPool
  function mint(uint256 _amount, address _receiver) external override onlyOwner {
    require(deployComplete, "Cover: deploy incomplete");
    _noClaimAcceptedCheck(); // save gas than modifier

    (bytes32[] memory _assetList) = ICoverPool(owner()).getAssetList();
    uint256 adjustedAmount = _amount * depositRatio / 1e18;
    for (uint i = 0; i < _assetList.length; i++) {
      claimCovTokenMap[_assetList[i]].mint(_receiver, adjustedAmount);
    }
    noclaimCovToken.mint(_receiver, adjustedAmount);
  }

  /// @notice redeem collateral, only when no claim accepted. If expired (with or withour claim), _amount is not respected
  function redeemCollateral(uint256 _amount) external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    if (coverPool.claimNonce() > claimNonce) {
      // there is an accepted claim, redeem back all if incident time must > expiry to redeem collateral
      ICoverPool.ClaimDetails memory claim = _claimDetails();
      require(claim.incidentTimestamp > expiry, "Cover: claimable covTokens cannot redeem collateral");
      require(block.timestamp >= uint256(claim.claimEnactedTimestamp) + coverPool.noclaimRedeemDelay(), "Cover: not ready");
      _burnCovTokenAndPay(noclaimCovToken, 1, 1);
    } else {
      require(_amount > 0, "Cover: amount is 0");
      
      if (block.timestamp < expiry) {
        // there is NO accepted claim, not expired
        ICoverERC20 _noclaimCovToken = noclaimCovToken; // save gas
        _noclaimCovToken.burnByCover(msg.sender, _amount);

        (bytes32[] memory assetList) = coverPool.getAssetList();
        for (uint i = 0; i < assetList.length; i++) {
          ICoverERC20 claimToken = claimCovTokenMap[assetList[i]];
          claimToken.burnByCover(msg.sender, _amount);
        }
        _payCollateral(msg.sender, _amount);
      } else {
        // there is NO accepted claim, expired, redeem back all
        require(block.timestamp >= uint256(expiry) + coverPool.noclaimRedeemDelay(), "Cover: not ready");
        _burnCovTokenAndPay(noclaimCovToken, 1, 1);
      }
    }
  }

  /**
   * @dev multi-tx/block deployment solution. Only called (1+ times depend on size of pool) at creation.
   * Deploy covTokens as many as possible till not enough gas left. 
   */
  function deploy() public override {
    require(!deployComplete, "Cover: deploy complete");
    (bytes32[] memory _assetList) = ICoverPool(owner()).getAssetList();
    uint256 startGas = gasleft();
    for (uint256 i = 0; i < _assetList.length; i++) {
      // with tests costs ~285k to deploy one, leave some space to update vars
      if (startGas < 500000) return;
      ICoverERC20 claimToken = claimCovTokenMap[_assetList[i]];
      if (address(claimToken) == address(0)) {
        string memory assetName = StringHelper.bytes32ToString(_assetList[i]);
        claimToken = _createCovToken(string(abi.encodePacked("CLAIM_", assetName)));
        claimCovTokens.push(claimToken);
        claimCovTokenMap[_assetList[i]] = claimToken;
        startGas = gasleft();
      }
    }
    deployComplete = true;
  }

  /// @notice redeem when there is an accepted claim
  function redeemClaim() external override nonReentrant {
    ICoverPool coverPool = ICoverPool(owner());
    require(coverPool.claimNonce() > claimNonce, "Cover: no claim accepted");

    ICoverPool.ClaimDetails memory claim = _claimDetails();
    require(claim.incidentTimestamp <= expiry, "Cover: not eligible, redeem collateral instead");
    require(block.timestamp >= uint256(claim.claimEnactedTimestamp) + coverPool.claimRedeemDelay(), "Cover: not ready");

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

  /// @notice make sure no claim is accepted
  function _noClaimAcceptedCheck() internal view {
    require(ICoverPool(owner()).claimNonce() == claimNonce, "Cover: claim accepted");
  }

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() internal view returns (ICoverPool.ClaimDetails memory) {
    return ICoverPool(owner()).getClaimDetails(claimNonce);
  }

  /// @notice the owner of this contract is CoverPool contract, the owner of CoverPool is CoverPoolFactory contract
  function _factory() internal view returns (address) {
    return IOwnable(owner()).owner();
  }

  /// @notice transfer collateral (amount - fee) from this contract to recevier, transfer fee to COVER treasury
  function _payCollateral(address _receiver, uint256 _amount) private {
    uint256 adjustedAmount = _amount * 1e18 / depositRatio;

    ICoverPoolFactory factory = ICoverPoolFactory(_factory());
    (uint256 feeNumerator, uint256 feeDenominator) = ICoverPool(owner()).getRedeemFees();
    uint256 fee = adjustedAmount * feeNumerator * duration / (feeDenominator * 365 days);
    address treasury = factory.treasury();
    IERC20 collateralToken = IERC20(collateral);

    collateralToken.safeTransfer(_receiver, adjustedAmount - fee);
    collateralToken.safeTransfer(treasury, fee);
  }

  /// @notice burn covToken and pay sender
  function _burnCovTokenAndPay(
    ICoverERC20 _covToken,
    uint256 _payoutNumerator,
    uint256 _payoutDenominator
  ) private {
    require(_payoutNumerator <= _payoutDenominator, "Cover: payout % is > 100%");
    require(_payoutNumerator > 0, "Cover: payout % < 0%");
    uint256 amount = _covToken.balanceOf(msg.sender);
    require(amount > 0, "Cover: low covToken balance");

    _covToken.burnByCover(msg.sender, amount);
    uint256 payoutAmount = amount * _payoutNumerator / _payoutDenominator;
    _payCollateral(msg.sender, payoutAmount);
  }

  /// @dev Emits NewCovTokenCreation
  function _createCovToken(string memory _prefix) private returns (ICoverERC20) {
    uint8 decimals = uint8(IERC20(collateral).decimals());
    if (decimals == 0) {
      decimals = 18;
    }
    address coverERC20Impl = ICoverPoolFactory(_factory()).coverERC20Impl();
    bytes32 salt = keccak256(abi.encodePacked(ICoverPool(owner()).name(), expiry, collateral, claimNonce, _prefix));
    address proxyAddr = BasicProxyLib.deployProxy(coverERC20Impl, salt);
    ICovTokenProxy(proxyAddr).initialize(string(abi.encodePacked(_prefix, "_", name)), decimals);

    emit NewCovTokenCreation(proxyAddr);
    return ICoverERC20(proxyAddr);
  }
}