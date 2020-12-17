// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./proxy/BasicProxyLib.sol";
import "./utils/Address.sol";
import "./utils/Create2.sol";
import "./utils/Ownable.sol";
import "./interfaces/ICoverPoolFactory.sol";

/**
 * @title CoverPoolFactory contract
 * @author crypto-pumpkin
 */
contract CoverPoolFactory is ICoverPoolFactory, Ownable {

  bytes4 private constant COVER_POOL_INIT_SIGNITURE = bytes4(keccak256("initialize(bytes32,bytes32[],address,uint48[],bytes32[])"));

  address public override coverPoolImpl;
  address public override coverImpl;
  address public override coverERC20Impl;

  address public override treasury;
  address public override governance;
  address public override claimManager;

  // not all coverPools are active
  bytes32[] private coverPoolNames;

  mapping(bytes32 => address) public override coverPools;

  modifier onlyGov() {
    require(msg.sender == governance, "CoverPoolFactory: caller not governance");
    _;
  }

  constructor (
    address _coverPoolImpl,
    address _coverImpl,
    address _coverERC20Impl,
    address _governance,
    address _treasury
  ) {
    coverPoolImpl = _coverPoolImpl;
    coverImpl = _coverImpl;
    coverERC20Impl = _coverERC20Impl;
    governance = _governance;
    treasury = _treasury;

    initializeOwner();
  }

  function getCoverPoolAddresses() external view override returns (address[] memory) {
    bytes32[] memory coverPoolNamesCopy = coverPoolNames;
    address[] memory coverPoolAddresses = new address[](coverPoolNamesCopy.length);
    for (uint i = 0; i < coverPoolNamesCopy.length; i++) {
      coverPoolAddresses[i] = coverPools[coverPoolNamesCopy[i]];
    }
    return coverPoolAddresses;
  }

  /// @notice return coverPool contract address, the contract may not be deployed yet
  function getCoverPoolAddress(bytes32 _name) public view override returns (address) {
    return _computeAddress(keccak256(abi.encodePacked(_name)), address(this));
  }

  /// @notice return cover contract address, the contract may not be deployed yet
  function getCoverAddress(
    bytes32 _coverPoolName,
    uint48 _timestamp,
    address _collateral,
    uint256 _claimNonce
  ) public view override returns (address) {
    return _computeAddress(
      keccak256(abi.encodePacked(_coverPoolName, _timestamp, _collateral, _claimNonce)),
      getCoverPoolAddress(_coverPoolName)
    );
  }

  /// @notice return covToken contract address, the contract may not be deployed yet
  // TODO to be updated for each asset
  function getCovTokenAddress(
    bytes32 _coverPoolName,
    uint48 _timestamp,
    address _collateral,
    uint256 _claimNonce,
    string memory _prefix // "CLAIM_CURVE_POOL2" or "NOCLAIM_POOL2"
  ) external view override returns (address) {
    bytes32 salt = keccak256(abi.encodePacked(_coverPoolName, _timestamp, _collateral, _claimNonce, _prefix));
    address deployer = getCoverAddress(_coverPoolName, _timestamp, _collateral, _claimNonce);
    return BasicProxyLib.computeProxyAddress(coverERC20Impl, salt, deployer);
  }

  /// @dev Emits CoverPoolCreation, add a supported coverPool in COVER
  function createCoverPool(
    bytes32 _name,
    bytes32[] calldata _assetList,
    address _collateral,
    uint48[] calldata _timestamps,
    bytes32[] calldata _timestampNames
  ) external override onlyOwner returns (address) {
    require(coverPools[_name] == address(0), "CoverPoolFactory: coverPool exists");
    require(_assetList.length > 0, "CoverPoolFactory: no asset passed for pool");
    require(_timestamps.length == _timestampNames.length, "CoverPoolFactory: timestamp lengths don't match");
    coverPoolNames.push(_name);

    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    // unique salt required for each coverPool, salt + deployer decides contract address
    address payable proxyAddr = Create2.deploy(0, keccak256(abi.encodePacked(_name)), bytecode);
    emit CoverPoolCreation(proxyAddr);

    bytes memory initData = abi.encodeWithSelector(COVER_POOL_INIT_SIGNITURE, _name, _assetList, _collateral, _timestamps, _timestampNames);
    InitializableAdminUpgradeabilityProxy(proxyAddr).initialize(coverPoolImpl, owner(), initData);

    coverPools[_name] = proxyAddr;

    return proxyAddr;
  }

  /// @dev update this will only affect coverPools deployed after
  function updateCoverPoolImpl(address _newImpl) external override onlyOwner {
    require(Address.isContract(_newImpl), "CoverPoolFactory: new implementation is not a contract");
    coverPoolImpl = _newImpl;
  }

  /// @dev update this will only affect covers of coverPools deployed after
  function updateCoverImpl(address _newImpl) external override onlyOwner {
    require(Address.isContract(_newImpl), "CoverPoolFactory: new implementation is not a contract");
    coverImpl = _newImpl;
  }

  /// @dev update this will only affect covTokens of covers of coverPools deployed after
  function updateCoverERC20Impl(address _newImpl) external override onlyOwner {
    require(Address.isContract(_newImpl), "CoverPoolFactory: new implementation is not a contract");
    coverERC20Impl = _newImpl;
  }

  function updateClaimManager(address _address) external override onlyOwner {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    claimManager = _address;
  }

  function updateGovernance(address _address) external override onlyGov {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    require(_address != owner(), "CoverPoolFactory: governance cannot be owner");
    governance = _address;
  }

  function updateTreasury(address _address) external override onlyOwner {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    treasury = _address;
  }

  function _computeAddress(bytes32 salt, address deployer) private pure returns (address) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    return Create2.computeAddress(salt, keccak256(bytecode), deployer);
  }
}