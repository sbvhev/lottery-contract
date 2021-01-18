// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../ERC20/IERC20.sol";
import "./ICoverPoolFactory.sol";

/**
 * @dev ClaimConfg contract interface. See {ClaimConfig}.
 * @author Alan + crypto-pumpkin
 */
interface IClaimConfig {
  function governance() external view returns (address);
  function treasury() external view returns (address);
  function coverPoolFactory() external view returns (ICoverPoolFactory);
  function defaultCVC() external view returns (address);
  function maxClaimDecisionWindow() external view returns (uint256);
  function baseClaimFee() external view returns (uint256);
  function forceClaimFee() external view returns (uint256);
  function feeMultiplier() external view returns (uint256);
  function feeCurrency() external view returns (IERC20);
  function cvcMap(address _coverPool, uint256 _idx) external view returns (address);
  function isCVCMember(address _coverPool, address _address) external view returns (bool);
  function getCoverPoolClaimFee(address _coverPool) external view returns (uint256);
  function getCVCList(address _coverPool) external view returns (address[] memory);
  
  // @notice only dev
  function setMaxClaimDecisionWindow(uint256 _newTimeWindow) external;
  function setTreasury(address _treasury) external;
  function addCVCForPool(address _coverPool, address _cvc) external;
  function addCVCForPools(address[] calldata _coverPools, address[] calldata _cvcs) external;
  function removeCVCForPool(address _coverPool, address _cvc) external;
  function removeCVCForPools(address[] calldata _coverPools, address[] calldata _cvcs) external;
  function setDefaultCVC(address _cvc) external;

  // @dev Only callable by governance
  function setGovernance(address _governance) external;
  function setFeeAndCurrency(uint256 _baseClaimFee, uint256 _forceClaimFee, address _currency) external;
  function setFeeMultiplier(uint256 _multiplier) external;
}