// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

/**
 * @dev CoverPool contract interface. See {CoverPool}.
 * @author crypto-pumpkin
 */
interface ICoverPool {
  event CoverCreated(address);
  event CoverAdded(address indexed _cover, address _acount, uint256 _amount);
  event ClaimEnacted(uint256 _enactedClaimNonce);
  event AssetUpdated(bytes32 _asset, bool _isAddAsset);

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
  function name() external view returns (string memory);
  function isAddingAsset() external view returns (bool);
  /// @notice only active (true) coverPool allows adding more covers (aka. minting more CLAIM and NOCLAIM tokens)
  function claimNonce() external view returns (uint256);
  function collateralStatusMap(address _collateral) external view returns (uint256 _depositRatio, uint8 _status);
  function expiryInfoMap(uint48 _expiry) external view returns (string memory _name, uint8 _status);
  function coverMap(address _collateral, uint48 _expiry) external view returns (address);

  // extra view
  function getAssetList() external view returns (bytes32[] memory _assetList);
  function getRedeemFees() external view returns (uint256 _numerator, uint256 _denominator);
  function getRedeemDelays() external view returns (uint256 _claimRedeemDelay, uint256 _noclaimRedeemDelay);
  function getClaimDetails(uint256 _claimNonce) external view returns (ClaimDetails memory);
  function getCoverPoolDetails()
    external view returns (
      bool _isOpenPool,
      bool _active,
      uint256 _claimNonce,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      bytes32[] memory _assetList,
      bytes32[] memory _deletedAssetList,
      address[] memory _allActiveCovers,
      address[] memory _allCovers
    );

  // user action
  /// @notice cover must be deployed first
  function addCover(address _collateral, uint48 _expiry, uint256 _amount) external;
  function deployCover(address _collateral, uint48 _expiry) external returns (address _coverAddress);

  // access restriction - claimManager
  function enactClaim(
    bytes32[] calldata _payoutAssetList,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator,
    uint48 _incidentTimestamp,
    uint256 _coverPoolNonce
  ) external;

  // access restriction - dev
  function addAsset(bytes32 _asset) external;
  function deleteAsset(bytes32 _asset) external;
  function updateExpiry(uint48 _expiry, string calldata _expiryName, uint8 _status) external;
  function updateCollateral(address _collateral, uint256 _depositRatio, uint8 _status) external;
  function setActive(bool _active) external;

  // access restriction - governance
  function updateFees(uint256 _feeNumerator, uint256 _feeDenominator) external;
  function updateRedeemDelays(uint256 _claimRedeemDelay, uint256 _noclaimRedeemDelay) external;
}