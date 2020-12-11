// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICoverERC20.sol";

/**
 * @title Cover interface. See {PerpCover} or {CoverWithExpiry}.
 * @author crypto-pumpkin
 */
interface ICover {
  event NewCovTokenCreation(address);

  function collateral() external view returns (address);
  function claimCovTokens(uint256 _index) external view returns (ICoverERC20);
  function noclaimCovToken() external view returns (ICoverERC20);
  function name() external view returns (string memory);
  function claimNonce() external view returns (uint256);

  // user action
  /// @notice redeem func when there is a claim on the cover, aka. the cover is affected
  function redeemClaim() external;
  /// @notice redeem func when the cover is not affected by any accepted claim, _amount is respected only when when no claim accepted before expiry (for cover with expiry)
  function redeemCollateral(uint256 _amount) external;

  // access restriction - owner (CoverPool)
  function mint(uint256 _amount, address _receiver) external;
}