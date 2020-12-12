// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;
pragma abicoder v2;

/**
 * @dev CoverPool contract interface. See {CoverPool}.
 * @author crypto-pumpkin
 */
interface ICoverPool {
  /// @notice emit when a claim against the coverPool is accepted
  event ClaimAccepted(uint256 _claimNonce);
  event CoverAdded(address indexed _cover, uint256 _amount);

  struct ExpiryInfo {
    bytes32 name;
    uint8 status; // 0 never set; 1 active, 2 inactive
  }
  struct ClaimDetails {
    bytes32[] payoutAssetList;
    uint256[] payoutNumerators;
    uint256 payoutTotalNum;
    uint256 payoutDenominator;
    uint48 incidentTimestamp;
    uint48 claimEnactedTimestamp;
  }

  // state vars
  /// @notice only active (true) coverPool allows adding more covers (aka. minting more CLAIM and NOCLAIM tokens)
  function isActive() external view returns (bool);
  function name() external view returns (bytes32);
  function claimNonce() external view returns (uint256);
  /// @notice delay # of seconds for redeem with accepted claim, redeemCollateral is not affected
  function claimRedeemDelay() external view returns (uint256);
  /// @notice only used by cover with expiry, redeemCollateral is not affected
  function noclaimRedeemDelay() external view returns (uint256);
  function rolloverPeriod() external view returns (uint256);
  function assetList(uint256 _index) external view returns (bytes32);
  function activeCovers(uint256 _index) external view returns (address);
  function collaterals(uint256 _index) external view returns (address);
  function expiries(uint256 _index) external view returns (uint48);
  function collateralStatusMap(address _collateral) external view returns (uint8 _status);
  function expiryInfoMap(uint48 _expiry) external view returns (bytes32 _name, uint8 _status);
  function coverWithExpiryMap(address _collateral, uint48 _expiry) external view returns (address);
  function perpCoverMap(address _collateral) external view returns (address);

  // extra view
  function getCoverPoolDetails()
    external view returns (
      bytes32 _name,
      bool _active,
      bytes32[] memory _assetList,
      uint256 _claimNonce,
      uint256 _claimRedeemDelay,
      uint256 _noclaimRedeemDelay,
      uint256 _rolloverPeriod,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      address[] memory _allCovers,
      address[] memory _allActiveCovers
    );
  function getRedeemFees() external view returns (uint256 _perpNumerator, uint256 _numerator, uint256 _denominator, uint256 _feeUpdatedAt);
  function getClaimDetails(uint256 _claimNonce) external view returns (ClaimDetails memory);

  // user action
  function addCoverWithExpiry(address _collateral, uint48 _timestamp, uint256 _amount) external;
  function addPerpCover(address _collateral, uint256 _amount) external;

  // access restriction - claimManager
  function enactClaim(
    bytes32[] calldata _payoutAssetList,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator,
    uint48 _incidentTimestamp,
    uint256 _coverPoolNonce
  ) external;

  // access restriction - dev
  function setActive(bool _active) external;
  function updateExpiry(uint48 _expiry, bytes32 _expiryName, uint8 _status) external;
  function updateCollateral(address _collateral, uint8 _status) external;
  function updateRolloverPeriod(uint256 _rolloverPeriod) external;

  // access restriction - governance
  function updateClaimRedeemDelay(uint256 _claimRedeemDelay) external;
  function updateNoclaimRedeemDelay(uint256 _noclaimRedeemDelay) external;
  function updateFees(uint256 _perpFeeNum, uint256 _expiryFeeNum, uint256 _feeDenominator) external;
}