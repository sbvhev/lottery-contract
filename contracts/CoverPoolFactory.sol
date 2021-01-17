// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./proxy/BasicProxyLib.sol";
import "./utils/Address.sol";
import "./utils/Create2.sol";
import "./utils/Ownable.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";

/**
 * @title CoverPoolFactory contract, manages all the coverPools for Cover Protocol
 * @author crypto-pumpkin
 * Using string (instead of bytes32) for all inputs for operation convinience at the expenses of a slightly highly cost
 */
contract CoverPoolFactory is ICoverPoolFactory, Ownable {

  bytes4 private constant COVER_POOL_INIT_SIGNITURE = bytes4(keccak256("initialize(string,bool,string[],address,uint256,uint48,string)"));

  bool public override paused;
  address public override responder;
  address public override coverPoolImpl;
  address public override coverImpl;
  address public override coverERC20Impl;
  address public override treasury; // receive fees collected
  address public override governance;
  address public override claimManager;
  // delay # of seconds for redeem with/o. accepted claim, redeemCollateral with all covTokens is not affected
  uint256 public override defaultRedeemDelay = 3 days;
  uint256 public override yearlyFeeRate = 0.006 ether; // 0.6% yearly rate
  /// @notice min gas left requirement before continue deployments (when creating new Cover or adding risks to CoverPool)
  uint256 public override deployGasMin = 1000000;
  // not all coverPools are active
  string[] private coverPoolNames;
  mapping(string => address) public override coverPools;

  constructor (
    address _coverPoolImpl,
    address _coverImpl,
    address _coverERC20Impl,
    address _governance,
    address _treasury
  ) {
    require(Address.isContract(_coverPoolImpl), "CoverPoolFactory: _coverPoolImpl is not a contract");
    require(Address.isContract(_coverImpl), "CoverPoolFactory: _coverImpl is not a contract");
    require(Address.isContract(_coverERC20Impl), "CoverPoolFactory: _coverERC20Impl is not a contract");
    require(_governance != address(0), "CoverPoolFactory: governance cannot be 0");
    require(_treasury != address(0), "CoverPoolFactory: treasury cannot be 0");
    coverPoolImpl = _coverPoolImpl;
    coverImpl = _coverImpl;
    coverERC20Impl = _coverERC20Impl;
    governance = _governance;
    treasury = _treasury;

    initializeOwner();
  }

  /**
   * @notice Create a new Cover Pool
   * @param _name name for pool, e.g. Yearn
   * @param _extendablePool extendable pools allow adding new risk
   * @param _riskList list of underlying that are covered in the pool
   * @param _collateral the collateral of the pool
   * @param _mintRatio must be 18 decimals, in (0, + infinity), 1.5 means 1 collateral mints 1.5 covTokens
   * @param _expiry expiration date supported for the pool
   * @param _expiryString MONTH_DATE_YEAR, used to create covToken symbols only
   * Emits CoverPoolCreated
   */
  function createCoverPool(
    string calldata _name,
    bool _extendablePool,
    string[] calldata _riskList,
    address _collateral,
    uint256 _mintRatio,
    uint48 _expiry,
    string calldata _expiryString
  ) external override onlyOwner returns (address _addr) {
    require(coverPools[_name] == address(0), "CoverPoolFactory: coverPool exists");
    require(_riskList.length > 0, "CoverPoolFactory: no risk underlying passed for pool");
    require(_expiry > block.timestamp, "CoverPoolFactory: expiry in the past");

    coverPoolNames.push(_name);
    bytes memory initData = abi.encodeWithSelector(COVER_POOL_INIT_SIGNITURE, _name, _extendablePool, _riskList, _collateral, _mintRatio, _expiry, _expiryString);
    _addr = address(_deployCoverPool(_name, initData));
    coverPools[_name] = _addr;
    emit CoverPoolCreated(_addr);
  }

  function setYearlyFeeRate(uint256 _yearlyFeeRate) external override onlyOwner {
    require(_yearlyFeeRate <= 0.1 ether, "CoverPool: must < 10%");
    yearlyFeeRate = _yearlyFeeRate;
  }

  function setDefaultRedeemDelay(uint256 _defaultRedeemDelay) external override onlyOwner {
    emit DefaultRedeemDelayUpdated(defaultRedeemDelay, _defaultRedeemDelay);
    defaultRedeemDelay = _defaultRedeemDelay;
  }

  function setPaused(bool _paused) external override {
    require(msg.sender == owner() || msg.sender == responder, "CoverPoolFactory: caller not owner or responder");
    emit PausedStatusUpdated(paused, _paused);
    paused = _paused;
  }

  function setDeployGasMin(uint256 _deployGasMin) external override onlyOwner {
    require(_deployGasMin > 0, "CoverPoolFactory: min gas cannot be 0");
    deployGasMin = _deployGasMin;
  }

  /// @dev update this will only affect coverPools deployed after
  function setCoverPoolImpl(address _newImpl) external override onlyOwner {
    require(Address.isContract(_newImpl), "CoverPoolFactory: new implementation is not a contract");
    emit ImplUpdated('CoverPool', coverPoolImpl, _newImpl);
    coverPoolImpl = _newImpl;
  }

  /// @dev update this will only affect covers of coverPools deployed after
  function setCoverImpl(address _newImpl) external override onlyOwner {
    require(Address.isContract(_newImpl), "CoverPoolFactory: new implementation is not a contract");
    emit ImplUpdated('Cover', coverImpl, _newImpl);
    coverImpl = _newImpl;
  }

  /// @dev update this will only affect covTokens of covers of coverPools deployed after
  function setCoverERC20Impl(address _newImpl) external override onlyOwner {
    require(Address.isContract(_newImpl), "CoverPoolFactory: new implementation is not a contract");
    emit ImplUpdated('CoverERC20', coverERC20Impl, _newImpl);
    coverERC20Impl = _newImpl;
  }

  function setClaimManager(address _address) external override onlyOwner {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    emit AddressUpdated('claimManager', claimManager, _address);
    claimManager = _address;
  }

  function setGovernance(address _address) external override onlyOwner {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    require(_address != owner(), "CoverPoolFactory: governance cannot be owner");
    emit AddressUpdated('governance', governance, _address);
    governance = _address;
  }

  function setTreasury(address _address) external override onlyOwner {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    emit AddressUpdated('treasury', treasury, _address);
    treasury = _address;
  }

  function setResponder(address _address) external override onlyOwner {
    require(_address != address(0), "CoverPoolFactory: address cannot be 0");
    emit AddressUpdated('responder', responder, _address);
    responder = _address;
  }

  function getCoverPools() external view override returns (address[] memory) {
    string[] memory coverPoolNamesCopy = coverPoolNames;
    address[] memory coverPoolAddresses = new address[](coverPoolNamesCopy.length);
    for (uint256 i = 0; i < coverPoolNamesCopy.length; i++) {
      coverPoolAddresses[i] = coverPools[coverPoolNamesCopy[i]];
    }
    return coverPoolAddresses;
  }

  /// @notice return covToken contract address, the contract may not be deployed yet, _prefix example: "C_CURVE", "C_FUT1", or "NC_"
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

  /// @notice return coverPool contract address, the contract may not be deployed yet
  function getCoverPoolAddress(string calldata _name) public view override returns (address) {
    return _computeAddress(keccak256(abi.encodePacked("CoverV2", _name)), address(this));
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

  function _deployCoverPool(string calldata _name, bytes memory _initData) private returns (address payable _proxyAddr) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    // unique salt required for each coverPool, salt + deployer decides contract address
    _proxyAddr = Create2.deploy(0, keccak256(abi.encodePacked("CoverV2", _name)), bytecode);
    InitializableAdminUpgradeabilityProxy(_proxyAddr).initialize(coverPoolImpl, owner(), _initData);
  }

  function _computeAddress(bytes32 salt, address deployer) private pure returns (address) {
    bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
    return Create2.computeAddress(salt, keccak256(bytecode), deployer);
  }
}