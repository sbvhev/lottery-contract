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

  bytes4 private constant COVER_POOL_INIT_SIGNITURE = bytes4(keccak256("initialize(string,string,bytes32[],address,uint256,uint48,string)"));

  address public override coverPoolImpl;
  address public override coverImpl;
  address public override coverERC20Impl;

  address public override treasury;
  address public override governance;
  address public override claimManager;

  // not all coverPools are active
  string[] private coverPoolNames;

  mapping(string => address) public override coverPools;

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
    string[] memory coverPoolNamesCopy = coverPoolNames;
    address[] memory coverPoolAddresses = new address[](coverPoolNamesCopy.length);
    for (uint i = 0; i < coverPoolNamesCopy.length; i++) {
      coverPoolAddresses[i] = coverPools[coverPoolNamesCopy[i]];
    }
    return coverPoolAddresses;
  }

  /// @notice return coverPool contract address, the contract may not be deployed yet
  function getCoverPoolAddress(string calldata _name) public view override returns (address) {
    return _computeAddress(keccak256(abi.encodePacked(_name)), address(this));
  }

  /// @notice return cover contract address, the contract may not be deployed yet
  function getCoverAddress(
    string calldata _coverPoolName,
    uint48 _timestamp,
    address _collateral,
    uint256 _claimNonce
  ) public view override returns (address) {
    return _computeAddress(
      keccak256(abi.encodePacked(_coverPoolName, _timestamp, _collateral, _claimNonce)),
      getCoverPoolAddress(_coverPoolName)
    );
  }

  /// @notice return covToken contract address, the contract may not be deployed yet, prefix should be "CLAIM_CURVE_POOL2" or "NOCLAIM_POOL2"
  function getCovTokenAddress(
    string calldata _coverPoolName,
    uint48 _timestamp,
    address _collateral,
    uint256 _claimNonce,
    string memory _prefix
  ) external view override returns (address) {
    bytes32 salt = keccak256(abi.encodePacked(_coverPoolName, _timestamp, _collateral, _claimNonce, _prefix));
    address deployer = getCoverAddress(_coverPoolName, _timestamp, _collateral, _claimNonce);
    return BasicProxyLib.computeProxyAddress(coverERC20Impl, salt, deployer);
  }

  /**
   * @notice Create a new Cover Pool
   * @param _name all caps, name for pool, e.g. YEARN
   * @param _category all caps, used identify the type of pool, DeFi, natural disaster
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
    string calldata _category,
    bytes32[] calldata _assetList,
    address _collateral,
    uint256 _depositRatio,
    uint48 _expiry,
    string calldata _expiryString
  ) external override onlyOwner returns (address _addr) {
    require(coverPools[_name] == address(0), "CoverPoolFactory: coverPool exists");
    require(_assetList.length > 0, "CoverPoolFactory: no asset passed for pool");
    require(_expiry > block.timestamp, "CoverPoolFactory: expiry in the past");

    coverPoolNames.push(_name);
    bytes memory initData = abi.encodeWithSelector(COVER_POOL_INIT_SIGNITURE, _name, _category, _assetList, _collateral, _depositRatio, _expiry, _expiryString);
    _addr =  address(_deployCoverPool(_name, initData));
    coverPools[_name] = _addr;
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

  function _deployCoverPool(string calldata _name, bytes memory _initData) private returns (address payable _proxyAddr) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    // unique salt required for each coverPool, salt + deployer decides contract address
    _proxyAddr = Create2.deploy(0, keccak256(abi.encodePacked(_name)), bytecode);
    emit CoverPoolCreation(_proxyAddr);
    InitializableAdminUpgradeabilityProxy(_proxyAddr).initialize(coverPoolImpl, owner(), _initData);
  }

  function _computeAddress(bytes32 salt, address deployer) private pure returns (address) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    return Create2.computeAddress(salt, keccak256(bytecode), deployer);
  }
}