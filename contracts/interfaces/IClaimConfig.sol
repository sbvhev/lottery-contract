// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../ERC20/IERC20.sol";

/**
 * @dev ClaimConfg contract interface. See {ClaimConfig}.
 * @author Alan + crypto-pumpkin
 */
interface IClaimConfig {
  function allowPartialClaim() external view returns (bool);
  function auditor() external view returns (address);
  function governance() external view returns (address);
  function treasury() external view returns (address);
  function coverPoolFactory() external view returns (address);
  function maxClaimDecisionWindow() external view returns (uint256);
  function baseClaimFee() external view returns (uint256);
  function forceClaimFee() external view returns (uint256);
  function feeMultiplier() external view returns (uint256);
  function feeCurrency() external view returns (IERC20);
  function getFileClaimWindow(address _coverPool) external view returns (uint256);
  function isAuditorVoting() external view returns (bool);
  function getCoverPoolClaimFee(address _coverPool) external view returns (uint256);
  
  // @notice only dev
  function setMaxClaimDecisionWindow(uint256 _newTimeWindow) external;
  function setTreasury(address _treasury) external;
  function setAuditor(address _auditor) external;
  function setPartialClaimStatus(bool _allowPartialClaim) external;

  // @dev Only callable by governance
  function setGovernance(address _governance) external;
  function setFeeAndCurrency(uint256 _baseClaimFee, uint256 _forceClaimFee, address _currency) external;
  function setFeeMultiplier(uint256 _multiplier) external;
}