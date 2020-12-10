// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./utils/Address.sol";
import "./utils/Create2.sol";
import "./utils/Ownable.sol";
import "./interfaces/ICoverPoolFactory.sol";

/**
 * @title CoverPoolFactory contract
 * @author crypto-pumpkin@github
 */
contract CoverPoolFactory is ICoverPoolFactory, Ownable {

  bytes4 private constant COVER_POOL_INIT_SIGNITURE = bytes4(keccak256("initialize(bytes32,bytes32[],address,uint48[],bytes32[])"));

  address public override coverPoolImplementation;
  address public override coverImplementation;
  address public override coverERC20Implementation;

  address public override treasury;
  address public override governance;
  address public override claimManager;

  // not all coverPools are active
  bytes32[] private coverPoolNames;

  mapping(bytes32 => address) public override coverPools;

  modifier onlyGovernance() {
    require(msg.sender == governance, "CoverPoolFactory: caller not governance");
    _;
  }

  constructor (
    address _coverPoolImplementation,
    address _coverImplementation,
    address _coverERC20Implementation,
    address _governance,
    address _treasury
  ) {
    coverPoolImplementation = _coverPoolImplementation;
    coverImplementation = _coverImplementation;
    coverERC20Implementation = _coverERC20Implementation;
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

  function getCoverPoolsLength() external view override returns (uint256) {
    return coverPoolNames.length;
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
  )
   public view override returns (address)
  {
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
    bool _isClaimCovToken
  )
   external view override returns (address) 
  {
    return _computeAddress(
      keccak256(abi.encodePacked(
        _coverPoolName,
        _timestamp,
        _collateral,
        _claimNonce,
        _isClaimCovToken ? "CLAIM" : "NOCLAIM")
      ),
      getCoverAddress(_coverPoolName, _timestamp, _collateral, _claimNonce)
    );
  }

  /// @dev Emits CoverPoolCreation, add a supported coverPool in COVER
  function createCoverPool(
    bytes32 _name,
    bytes32[] calldata _assetList,
    address _collateral,
    uint48[] calldata _timestamps,
    bytes32[] calldata _timestampNames
  )
    external override onlyOwner returns (address)
  {
    require(coverPools[_name] == address(0), "CoverPoolFactory: coverPool exists");
    require(_assetList.length > 0, "CoverPoolFactory: no asset passed for pool");
    require(_timestamps.length == _timestampNames.length, "CoverPoolFactory: timestamp lengths don't match");
    coverPoolNames.push(_name);

    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    // unique salt required for each coverPool, salt + deployer decides contract address
    address payable proxyAddr = Create2.deploy(0, keccak256(abi.encodePacked(_name)), bytecode);
    emit CoverPoolCreation(proxyAddr);

    bytes memory initData = abi.encodeWithSelector(COVER_POOL_INIT_SIGNITURE, _name, _assetList, _collateral, _timestamps, _timestampNames);
    InitializableAdminUpgradeabilityProxy(proxyAddr).initialize(coverPoolImplementation, owner(), initData);

    coverPools[_name] = proxyAddr;

    return proxyAddr;
  }

  /// @dev update this will only affect coverPools deployed after
  function updateCoverPoolImplementation(address _newImplementation)
   external override onlyOwner returns (bool)
  {
    require(Address.isContract(_newImplementation), "CoverPoolFactory: new implementation is not a contract");
    coverPoolImplementation = _newImplementation;
    return true;
  }

  /// @dev update this will only affect covers of coverPools deployed after
  function updateCoverImplementation(address _newImplementation)
   external override onlyOwner returns (bool)
  {
    require(Address.isContract(_newImplementation), "CoverPoolFactory: new implementation is not a contract");
    coverImplementation = _newImplementation;
    return true;
  }

  /// @dev update this will only affect covTokens of covers of coverPools deployed after
  function updateCoverERC20Implementation(address _newImplementation)
   external override onlyOwner returns (bool)
  {
    require(Address.isContract(_newImplementation), "CoverPoolFactory: new implementation is not a contract");
    coverERC20Implementation = _newImplementation;
    return true;
  }

  function updateClaimManager(address _address)
   external override onlyOwner returns (bool)
  {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    claimManager = _address;
    return true;
  }

  function updateGovernance(address _address)
   external override onlyGovernance returns (bool)
  {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    require(_address != owner(), "CoverPoolFactory: governance cannot be owner");
    governance = _address;
    return true;
  }

  function updateTreasury(address _address)
   external override onlyOwner returns (bool)
  {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    treasury = _address;
    return true;
  }

  function _computeAddress(bytes32 salt, address deployer) private pure returns (address) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    return Create2.computeAddress(salt, keccak256(bytecode), deployer);
  }
}