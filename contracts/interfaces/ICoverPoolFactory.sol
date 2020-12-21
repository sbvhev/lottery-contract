// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

/**
 * @dev CoverPoolFactory contract interface. See {CoverPoolFactory}.
 * @author crypto-pumpkin
 */
interface ICoverPoolFactory {
  event CoverPoolCreation(address coverPoolAddress);

  function getCoverPoolAddresses() external view returns (address[] memory);
  function coverPoolImpl() external view returns (address);
  function coverImpl() external view returns (address);
  function coverERC20Impl() external view returns (address);
  function treasury() external view returns (address);
  function governance() external view returns (address);
  function claimManager() external view returns (address);
  function coverPools(string calldata _coverPoolName) external view returns (address);

  /// @notice return contract address, the contract may not be deployed yet
  function getCoverPoolAddress(string calldata _name) external view returns (address);
  function getCoverAddress(string calldata _coverPoolName, uint48 _timestamp, address _collateral, uint256 _claimNonce) external view returns (address);
  /// @notice _prefix example: "CLAIM_CURVE_POOL2" or "NOCLAIM_POOL2"
  function getCovTokenAddress(string calldata _coverPoolName, uint48 _expiry, address _collateral, uint256 _claimNonce, string memory _prefix) external view returns (address);

  // access restriction - owner (dev)
  /// @dev update Impl will only affect contracts deployed after
  function updateCoverPoolImpl(address _newImpl) external;
  function updateCoverImpl(address _newImpl) external;
  function updateCoverERC20Impl(address _newImpl) external;
  /**
   * @notice Create a new Cover Pool
   * @param _name all caps, name for pool, e.g. YEARN
   * @param _assetList risk assets that are covered in this pool
   * @param _collateral the collateral of the pool
   * @param _depositRatio e18, in (0, + infinity) the deposit ratio for the collateral the pool, 1.5 means =  1 collateral mints 1.5 CLAIM/NOCLAIM tokens
   * @param _expiry expiration date supported for the pool
   * @param _expiryString YEAR_MONTH_DATE, used to create covToken symbols only
   * 
   * Emits CoverPoolCreation, add a supported coverPool in COVER
   */
  function createCoverPool(
    string calldata _name,
    bytes32[] calldata _assetList,
    address _collateral,
    uint256 _depositRatio,
    uint48 _expiry,
    string calldata _expiryString
  ) external returns (address);
  function updateTreasury(address _address) external;
  function updateClaimManager(address _address) external;

  // access restriction - governance
  function updateGovernance(address _address) external;
}  