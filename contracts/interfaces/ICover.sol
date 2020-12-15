// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICoverERC20.sol";

/**
 * @title Cover interface. See {PerpCover} or {CoverWithExpiry}.
 * @author crypto-pumpkin
 */
interface ICover {
  event NewCovTokenCreation(address);

  function isDeployed() external view returns (bool);
  function collateral() external view returns (address);
  function claimCovTokens(uint256 _index) external view returns (ICoverERC20);
  function noclaimCovToken() external view returns (ICoverERC20);
  function name() external view returns (string memory);
  function claimNonce() external view returns (uint256);
  function viewClaimable(address _account) external view returns (uint256 _eligibleAmount);

  // access restriction - owner (CoverPool)
  function mint(uint256 _amount, address _receiver) external;
}