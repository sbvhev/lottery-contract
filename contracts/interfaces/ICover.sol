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
  event Redeemed(string _type, address indexed _account, uint256 _amount);
  event FutureTokenConverted(address _futureToken, address claimCovToken, uint256 _amount);

  // state vars
  function deployComplete() external view returns (bool);
  /// @notice created as initialization, cannot be changed
  function claimNonce() external view returns (uint256);
  function feeRate() external view returns (uint256);
  function claimCovTokenMap(bytes32 _risk) external view returns (ICoverERC20 _claimCovToken);
  function futureCovTokenMap(ICoverERC20 _futureCovToken) external view returns (ICoverERC20 _claimCovToken);

  // extra view
  function viewClaimable(address _account) external view returns (uint256 _eligibleCovTokenAmount);
  function getCoverDetails()
    external view
    returns (
      string memory _name, // Yearn_0_DAI_210131
      uint48 _expiry,
      address _collateral,
      uint256 _mintRatio,
      uint256 _feeRate,
      uint256 _claimNonce,
      ICoverERC20 _noclaimCovToken,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20[] memory _futureCovTokens);

  // user action
  function deploy() external;
  /// @notice convert futureTokens to claimTokens
  function convert(ICoverERC20[] calldata _futureTokens) external;
  /// @notice redeem func when there is a claim on the cover, aka. the cover is affected
  function redeemClaim() external;
  /// @notice redeem func when the cover is not affected by any accepted claim, _amount is respected only when when no claim accepted before expiry (for cover with expiry)
  function redeem(uint256 _amount) external;
  function collectFees() external;

  // access restriction - owner (CoverPool)
  function mint(uint256 _amount, address _receiver) external;
  function addRisk(bytes32 _risk) external;
}