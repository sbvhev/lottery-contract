// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

/**
 * @dev CoverPool contract interface. See {CoverPool}.
 * @author crypto-pumpkin
 */
interface ICoverPool {
  /// @notice emit when a claim against the coverPool is accepted
  event ClaimAccepted(uint256 _claimNonce);
  event CoverAdded(address indexed _cover, uint256 _amount);
  /// @notice either delete or add asset
  event AssetUpdated(bytes32 _asset, bool _isAdd);

  struct ExpiryInfo {
    string name;
    uint8 status; // 0 never set; 1 active, 2 inactive
  }
  struct CollateralInfo {
    uint256 depositRatio;
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
  function name() external view returns (string memory);
  function category() external view returns (string memory);
  function claimNonce() external view returns (uint256);
  /// @notice delay # of seconds for redeem with accepted claim, redeemCollateral is not affected
  function claimRedeemDelay() external view returns (uint256);
  /// @notice only used by cover with expiry, redeemCollateral is not affected
  function noclaimRedeemDelay() external view returns (uint256);
  function assetList(uint256 _index) external view returns (bytes32);
  function deletedAssetList(uint256 _index) external view returns (bytes32);
  function activeCovers(uint256 _index) external view returns (address);
  function collaterals(uint256 _index) external view returns (address);
  function expiries(uint256 _index) external view returns (uint48);
  function collateralStatusMap(address _collateral) external view returns (uint256 _depositRatio, uint8 _status);
  function expiryInfoMap(uint48 _expiry) external view returns (string memory _name, uint8 _status);
  function coverMap(address _collateral, uint48 _expiry) external view returns (address);

  // extra view
  function getAssetList() external view returns (bytes32[] memory _assetList);
  function getCoverPoolDetails()
    external view returns (
      string memory _name,
      string memory _category,
      bool _active,
      bytes32[] memory _assetList,
      bytes32[] memory _deletedAssetList,
      uint256 _claimNonce,
      uint256 _claimRedeemDelay,
      uint256 _noclaimRedeemDelay,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      address[] memory _allCovers,
      address[] memory _allActiveCovers
    );
  function getRedeemFees() external view returns (uint256 _numerator, uint256 _denominator);
  function getClaimDetails(uint256 _claimNonce) external view returns (ClaimDetails memory);

  // user action
  /// @notice Will only deploy or complete existing deployment if necessary, safe to call
  function deployCover(address _collateral, uint48 _expiry) external returns (address _coverAddress);
  /// @notice cover must be deployed first
  function addCover(address _collateral, uint48 _expiry, uint256 _amount) external;

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
  function updateExpiry(uint48 _expiry, string calldata _expiryName, uint8 _status) external;
  function updateCollateral(address _collateral, uint256 _depositRatio, uint8 _status) external;
  function deleteAsset(bytes32 _asset) external;

  // access restriction - governance
  function updateClaimRedeemDelay(uint256 _claimRedeemDelay) external;
  function updateNoclaimRedeemDelay(uint256 _noclaimRedeemDelay) external;
  function updateFees(uint256 _feeNumerator, uint256 _feeDenominator) external;
}