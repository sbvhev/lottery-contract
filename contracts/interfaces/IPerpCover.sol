// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICover.sol";
import "./ICoverERC20.sol";

/**
 * @title Perpetual Cover contract interface. See {PerpCover}.
 * @author crypto-pumpkin
 */
interface IPerpCover is ICover {
  function createdAt() external view returns (uint256);
  function feeFactor() external view returns (uint256);
  function lastUpdatedAt() external view returns (uint256);
  function getCoverDetails()
    external view returns (
      string memory _name,
      uint256 _createdAt,
      address _collateral,
      uint256 _claimNonce,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken
    );
  
  // user action
  /// @notice redeem func when there is a claim on the cover, aka. the cover is affected
  function redeemClaim() external;
  /// @notice redeem func when the cover is not affected by any accepted claim, _amount is respected only when when no claim accepted before expiry (for cover with expiry)
  function redeemCollateral(uint256 _amount) external;
}