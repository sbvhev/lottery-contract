// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

/**
 * @dev CoverPoolFactory contract interface. See {CoverPoolFactory}.
 * @author crypto-pumpkin@github
 */
interface ICoverPoolFactory {
  /// @notice emit when a new coverPool is supported in COVER
  event CoverPoolCreation(address coverPoolAddress);

  function getCoverPoolAddresses() external view returns (address[] memory);
  function coverPoolImpl() external view returns (address);
  function coverImpl() external view returns (address);
  function coverERC20Impl() external view returns (address);
  function treasury() external view returns (address);
  function governance() external view returns (address);
  function claimManager() external view returns (address);
  function coverPools(bytes32 _coverPoolName) external view returns (address);

  function getCoverPoolsLength() external view returns (uint256);
  /// @notice return contract address, the contract may not be deployed yet
  function getCoverPoolAddress(bytes32 _name) external view returns (address);
  /// @notice return contract address, the contract may not be deployed yet
  function getCoverAddress(bytes32 _coverPoolName, uint48 _timestamp, address _collateral, uint256 _claimNonce) external view returns (address);
  /// @notice return contract address, the contract may not be deployed yet
  function getCovTokenAddress(bytes32 _coverPoolName, uint48 _timestamp, address _collateral, uint256 _claimNonce, bool _isClaimCovToken) external view returns (address);

  /// @notice access restriction - owner (dev)
  /// @dev update this will only affect contracts deployed after
  function updateCoverPoolImpl(address _newImpl) external;
  /// @dev update this will only affect contracts deployed after
  function updateCoverImpl(address _newImpl) external;
  /// @dev update this will only affect contracts deployed after
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

  /// @notice access restriction - governance
  function updateGovernance(address _address) external;
}  