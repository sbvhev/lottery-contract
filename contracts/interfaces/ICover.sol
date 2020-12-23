// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./ICoverERC20.sol";

/**
 * @title Cover interface
 * @author crypto-pumpkin
 */
interface ICover {
  event CovTokenCreated(address);
  event CoverDeployCompleted();

  function deployComplete() external view returns (bool);
  /// @notice created as initialization, cannot be changed
  function claimNonce() external view returns (uint256);
  function viewClaimable(address _account) external view returns (uint256 _eligibleAmount);
  function getCoverDetails()
    external view returns (
      string memory _name, // Yearn_0_DAI_210131
      uint48 _expiry,
      address _collateral,
      uint256 _depositRatio,
      uint256 _claimNonce,
      ICoverERC20[] memory _futureCovTokens,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken,
      uint256 _duration
    );

  // user action
  function deploy() external;
  /// @notice convert futureToken to claimToken
  function convert(ICoverERC20 _futureToken) external;
  /// @notice convert futureTokens to claimTokens
  function convertAll(ICoverERC20[] calldata _futureTokens) external;
  /// @notice redeem func when there is a claim on the cover, aka. the cover is affected
  function redeemClaim() external;
  /// @notice redeem func when the cover is not affected by any accepted claim, _amount is respected only when when no claim accepted before expiry (for cover with expiry)
  function redeemCollateral(uint256 _amount) external;

  // access restriction - owner (CoverPool)
  function mint(uint256 _amount, address _receiver) external;
  function addAsset(bytes32 _asset) external;
}