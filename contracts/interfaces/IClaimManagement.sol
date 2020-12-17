// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev ClaimManagement contract interface. See {ClaimManagement}.
 * @author Alan + crypto-pumpkin
 */
interface IClaimManagement {
  event ClaimUpdate(address indexed coverPool, ClaimState state, uint256 nonce, uint256 index);

  enum ClaimState { Filed, ForceFiled, Validated, Invalidated, Accepted, Denied }
  struct Claim {
    ClaimState state; // Current state of claim
    address filedBy; // Address of user who filed claim
    bytes32[] payoutAssetList;
    uint256[] payoutNumerators; // Numerators of percent to payout
    uint256 payoutDenominator; // Denominator of percent to payout
    uint48 filedTimestamp; // Timestamp of submitted claim
    uint48 incidentTimestamp; // Timestamp of the incident the claim is filed for
    uint48 decidedTimestamp; // Timestamp when claim outcome is decided
    uint256 feePaid; // Fee paid to file the claim
    string description;
  }

  function getCoverPoolClaims(address _coverPool, uint256 _nonce, uint256 _index) external view returns (Claim memory);
  
  function fileClaim(
    address _coverPool,
    string calldata _coverPoolName,
    bytes32[] calldata _exploitAssets,
    uint48 _incidentTimestamp,
    string calldata _description
  ) external;
  function forceFileClaim(
    address _coverPool,
    string calldata _coverPoolName,
    bytes32[] calldata _exploitAssets,
    uint48 _incidentTimestamp,
    string calldata _description
  ) external;
  
  // @dev Only callable by owner when auditor is voting
  function validateClaim(address _coverPool, uint256 _nonce, uint256 _index, bool _claimIsValid) external;

  // @dev Only callable by approved decider, governance or auditor (isAuditorVoting == true)
  function decideClaim(
    address _coverPool,
    uint256 _nonce,
    uint256 _index,
    bool _claimIsAccepted,
    bytes32[] calldata _exploitAssets,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator
  ) external;

  function getAllClaimsByState(address _coverPool, uint256 _nonce, ClaimState _state) external view returns (Claim[] memory);
  function getAllClaimsByNonce(address _coverPool, uint256 _nonce) external view returns (Claim[] memory);
  function getAddressFromFactory(string calldata _coverPoolName) external view returns (address);
  function getCoverPoolNonce(address _coverPool) external view returns (uint256);
 }