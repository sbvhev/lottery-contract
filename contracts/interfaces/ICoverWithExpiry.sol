// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICover.sol";
import "./ICoverERC20.sol";

/**
 * @title Cover with expiry contract interface. See {CoverWithExpiry}.
 * @author crypto-pumpkin
 */
interface ICoverWithExpiry is ICover {
  function expiry() external view returns (uint48);
  function duration() external view returns (uint256);
  function getCoverDetails()
    external view returns (
      string memory _name,
      uint48 _expiry,
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