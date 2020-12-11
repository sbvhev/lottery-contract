// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

/**
 * @dev CoverPoolFactory contract interface. See {CoverPoolFactory}.
 * @author crypto-pumpkin
 */
interface ICoverPoolFactory {
  event CoverPoolCreation(address coverPoolAddress);

  function getCoverPoolAddresses() external view returns (address[] memory);
  function coverPoolImpl() external view returns (address);
  function perpCoverImpl() external view returns (address);
  function coverImpl() external view returns (address);
  function coverERC20Impl() external view returns (address);
  function treasury() external view returns (address);
  function governance() external view returns (address);
  function claimManager() external view returns (address);
  function coverPools(bytes32 _coverPoolName) external view returns (address);

  /// @notice return contract address, the contract may not be deployed yet
  function getCoverPoolAddress(bytes32 _name) external view returns (address);
  function getCoverAddress(bytes32 _coverPoolName, uint48 _timestamp, address _collateral, uint256 _claimNonce) external view returns (address);
  function getPerpCoverAddress(bytes32 _coverPoolName, address _collateral, uint256 _claimNonce) external view returns (address);
  /// @notice _prefix example: "CLAIM_CURVE_POOL2" or "NOCLAIM_POOL2"
  function getCovTokenAddress(bytes32 _coverPoolName, uint48 _expiry, address _collateral, uint256 _claimNonce, string memory _prefix) external view returns (address);
  function getPerpCovTokenAddress(bytes32 _coverPoolName, uint256 _createdAt, address _collateral, uint256 _claimNonce, string memory _prefix) external view returns (address);

  // access restriction - owner (dev)
  /// @dev update Impl will only affect contracts deployed after
  function updateCoverPoolImpl(address _newImpl) external;
  function updatePerpCoverImpl(address _newImpl) external;
  function updateCoverImpl(address _newImpl) external;
  function updateCoverERC20Impl(address _newImpl) external;
  function createCoverPool(
    bytes32 _name,
    bytes32[] calldata _assetList,
    address _collateral,
    uint48[] calldata _timestamps,
    bytes32[] calldata _timestampNames
  ) external returns (address);
  function updateTreasury(address _address) external;
  function updateClaimManager(address _address) external;

  // access restriction - governance
  function updateGovernance(address _address) external;
}  