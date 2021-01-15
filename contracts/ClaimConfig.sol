// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./utils/Ownable.sol";
import "./interfaces/IClaimConfig.sol";
import "./interfaces/ICoverPool.sol";

/**
 * @title Config for ClaimManagement contract
 * @author Alan + crypto-pumpkin
 */
contract ClaimConfig is IClaimConfig, Ownable {

  IERC20 public override feeCurrency = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // Dai
  address public override governance;
  address public override treasury;
  address public override coverPoolFactory;
  address public override defaultCVC; // if not specified, default to this
  
  // The max time allowed from filing a claim to a decision made
  uint256 public override maxClaimDecisionWindow = 7 days;
  uint256 public override baseClaimFee = 50e18;
  uint256 public override forceClaimFee = 500e18;
  uint256 public override feeMultiplier = 2;

  // coverPool => claim fee
  mapping(address => uint256) private coverPoolClaimFee;

  // coverPool => cvc addresses
  mapping(address => address[]) public override cvcMap;
  
  modifier onlyGov() {
    require(msg.sender == governance, "COVER_CC: !governance");
    _;
  }

  function setGovernance(address _governance) external override onlyGov {
    require(_governance != address(0), "COVER_CC: governance cannot be 0");
    require(_governance != owner(), "COVER_CC: governance cannot be owner");
    governance = _governance;
  }

  function setTreasury(address _treasury) external override onlyOwner {
    require(_treasury != address(0), "COVER_CC: treasury cannot be 0");
    treasury = _treasury;
  }

  /// @notice Set max time window allowed to decide a claim after filed, requires at least 3 days for voting
  function setMaxClaimDecisionWindow(uint256 _newTimeWindow) external override onlyOwner {
    require(_newTimeWindow < 3 days, "COVER_CC: window too short");
    maxClaimDecisionWindow = _newTimeWindow;
  }

  function setDefaultCVC(address _cvc) external override onlyOwner {
    require(_cvc != address(0), "COVER_CC: default CVC cannot be 0");
    defaultCVC = _cvc;
  }

  /// @notice Add CVC groups for multiple coverPools
  function addCVCForPools(address[] calldata _coverPools, address[] calldata _cvcs) external override onlyOwner {
    require(_coverPools.length == _cvcs.length, "COVER_CC: lengths don't match");
    for (uint i = 0; i < _coverPools.length; i++) {
      addCVCForPool(_coverPools[i], _cvcs[i]);
    }
  }

  /// @notice Remove CVC groups for multiple coverPools
  function removeCVCForPools(address[] calldata _coverPools, address[] calldata _cvcs) external override onlyOwner {
    require(_coverPools.length == _cvcs.length, "COVER_CC: lengths don't match");
    for (uint i = 0; i < _coverPools.length; i++) {
      removeCVCForPool(_coverPools[i], _cvcs[i]);
    }
  }

  function setFeeAndCurrency(uint256 _baseClaimFee, uint256 _forceClaimFee, address _currency) external override onlyGov {
    require(_baseClaimFee > 0, "COVER_CC: baseClaimFee <= 0");
    require(_forceClaimFee > _baseClaimFee, "COVER_CC: forceClaimFee <= baseClaimFee");
    require(_currency != address(0), "COVER_CC: feeCurrency cannot be 0");
    baseClaimFee = _baseClaimFee;
    forceClaimFee = _forceClaimFee;
    feeCurrency = IERC20(_currency);
  }

  /// @notice Set the fee multiplier to `_multiplier`
  function setFeeMultiplier(uint256 _multiplier) external override onlyGov {
    require(_multiplier >= 1, "COVER_CC: multiplier < 1");
    feeMultiplier = _multiplier;
  }

  /// @notice Get the CVC list for a pool
  function getCVCList(address _coverPool) external view override returns (address[] memory) {
    return cvcMap[_coverPool];
  }

  /// @notice Add CVC group for a coverPool if `_cvc` isn't already added
  function addCVCForPool(address _coverPool, address _cvc) public override onlyOwner {
    address[] memory cvcCopy = cvcMap[_coverPool];
    for (uint i = 0; i < cvcCopy.length; i++) {
      require(cvcCopy[i] != _cvc, "COVER_CC: cvc exists");
    }
    cvcMap[_coverPool].push(_cvc);
  }

  function removeCVCForPool(address _coverPool, address _cvc) public override onlyOwner {
    address[] memory cvcCopy = cvcMap[_coverPool];
    require(cvcCopy.length > 0, "COVER_CC: cvc is empty");
    address[] memory newCVC = new address[](cvcCopy.length - 1);
    uint256 newListInd = 0;
    for (uint i = 0; i < cvcCopy.length; i++) {
      if (_cvc != cvcCopy[i]) {
        newCVC[newListInd] = cvcCopy[i];
        newListInd++;
      }
    }
    cvcMap[_coverPool] = newCVC;
  }

  /// @notice Get whether input address is a member of the CVC group for a pool
  function isCVCMember(address _coverPool, address _address) public view override returns (bool) {
    address[] memory cvcCopy = cvcMap[_coverPool];
    if (cvcCopy.length == 0 && _address == defaultCVC) return true;
    for (uint i = 0; i < cvcCopy.length; i++) {
      if (_address == cvcCopy[i]) {
        return true;
      }
    }
    return false;
  }

  /// @notice Get the current claim fee for coverPool `_coverPool`
  function getCoverPoolClaimFee(address _coverPool) public view override returns (uint256) {
    return coverPoolClaimFee[_coverPool] < baseClaimFee ? baseClaimFee : coverPoolClaimFee[_coverPool];
  }

  /// @notice Get the time window allowed to file after an incident happened, based on the defaultRedeemDelay of the coverPool - 1hour
  function getFileClaimWindow(address _coverPool) public view override returns (uint256) {
    (uint256 defaultRedeemDelay, ) = ICoverPool(_coverPool).getRedeemDelays();
    return defaultRedeemDelay - 1 hours;
  }

  /// @notice Updates fee for coverPool `_coverPool` by multiplying current fee by `feeMultiplier`, capped at `forceClaimFee`
  function _updateCoverPoolClaimFee(address _coverPool) internal {
    uint256 newFee = getCoverPoolClaimFee(_coverPool) * feeMultiplier;
    if (newFee <= forceClaimFee) {
      coverPoolClaimFee[_coverPool] = newFee;
    }
  }

  /// @notice Resets fee for coverPool `_coverPool` to `baseClaimFee`
  function _resetCoverPoolClaimFee(address _coverPool) internal {
    coverPoolClaimFee[_coverPool] = baseClaimFee;
  }
}