// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

/**
 * @dev CoverPool contract interface. See {CoverPool}.
 * @author crypto-pumpkin@github
 */
interface ICoverPool {
  /// @notice emit when a claim against the coverPool is accepted
  event ClaimAccepted(uint256 _claimNonce);

  struct ClaimDetails {
    bytes32[] payoutAssetList;
    uint256[] payoutNumerators;
    uint256 payoutTotalNum;
    uint256 payoutDenominator;
    uint48 incidentTimestamp;
    uint48 claimEnactedTimestamp;
  }

  function getCoverPoolDetails()
    external view returns (
      bytes32 _name,
      bool _active,
      bytes32[] memory _assetList,
      uint256 _claimNonce,
      uint256 _claimRedeemDelay,
      uint256 _noclaimRedeemDelay,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      address[] memory _allCovers,
      address[] memory _allActiveCovers
    );
  function active() external view returns (bool);
  function name() external view returns (bytes32);
  function claimNonce() external view returns (uint256);
  /// @notice delay # of seconds for redeem with accepted claim, redeemCollateral is not affected
  function claimRedeemDelay() external view returns (uint256);
  /// @notice delay # of seconds for redeem without accepted claim, redeemCollateral is not affected
  function noclaimRedeemDelay() external view returns (uint256);
  function getRedeemFees() external view returns (uint16 _numerator, uint16 _denominator);
  function assetList(uint256 _index) external view returns (bytes32);
  function activeCovers(uint256 _index) external view returns (address);
  function getClaimDetails(uint256 _claimNonce) external view returns (
    bytes32[] memory _payoutAssetList,
    uint256[] memory _payoutNumerators,
    uint256 payoutTotalNum,
    uint256 _payoutDenominator,
    uint48 incidentTimestamp,
    uint48 claimEnactedTimestamp
  );
  function collateralStatusMap(address _collateral) external view returns (uint8 _status);
  function expiryMap(uint48 _expiry) external view returns (bytes32 _name, uint8 _status);
  function coverMap(address _collateral, uint48 _expiry) external view returns (address);
  function perpCoverMap(address _collateral) external view returns (address);

  function collaterals(uint256 _index) external view returns (address);
  function collateralsLength() external view returns (uint256);
  function expiries(uint256 _index) external view returns (uint48);
  function expiriesLength() external view returns (uint256);
  function activeCoversLength() external view returns (uint256);
  function claimsLength() external view returns (uint256);
  function addCoverWithExpiry(address _collateral, uint48 _timestamp, uint256 _amount)
    external returns (bool);
  function addPerpCover(address _collateral, uint256 _amount) external returns (bool);

  /// @notice access restriction - claimManager
  function enactClaim(
    bytes32[] calldata _payoutAssetList,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator,
    uint48 _incidentTimestamp,
    uint256 _coverPoolNonce
  ) external returns (bool);

  /// @notice access restriction - dev
  function setActive(bool _active) external returns (bool);
  function updateExpiry(uint48 _expiry, bytes32 _expiryName, uint8 _status) external returns (bool);
  function updateCollateral(address _collateral, uint8 _status) external returns (bool);

  /// @notice access restriction - governance
  function updateClaimRedeemDelay(uint256 _claimRedeemDelay) external returns (bool);
  function updateNoclaimRedeemDelay(uint256 _noclaimRedeemDelay) external returns (bool);
  function updateFees(uint16 _redeemFeeNumerator, uint16 _redeemFeeDenominator) external returns (bool);
}