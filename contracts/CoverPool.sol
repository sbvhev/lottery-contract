// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./ERC20/SafeERC20.sol";
import "./ERC20/IERC20.sol";
import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/StringHelper.sol";
import "./interfaces/ICover.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/IClaimManagement.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";

/**
 * @title CoverPool contract, manages covers for pool, add coverage for user
 * @author crypto-pumpkin
 * 
 * Pool types:
 * - extendable pool: allowed to add and delete asset
 * - non-extendable pool: NOT allowed to add asset, but allowed to delete asset
 */
contract CoverPool is ICoverPool, Initializable, ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;

  bytes4 private constant COVER_INIT_SIGNITURE = bytes4(keccak256("initialize(string,uint48,address,uint256,uint256)"));

  bool private extendablePool;
  // only active (true) coverPool allows adding more covers (aka. minting more CLAIM and NOCLAIM tokens)
  bool private active;
  bool public override isAddingAsset;
  string public override name;
  // nonce of for the coverPool's claim status, it also indicates count of accepted claim in the past
  uint256 public override claimNonce;
  uint256 public override yearlyFeeRate;
  // delay # of seconds for redeem with/o. accepted claim, redeemCollateral is not affected
  uint256 private defaultRedeemDelay;
  uint256 private noclaimRedeemDelay;

  // only covers that have never accepted a claim
  address[] private activeCovers;
  address[] private allCovers;
  uint48[] private expiries;
  // list of active assets in cover pool
  bytes32[] private assetList;
  bytes32[] private deletedAssetList;
  address[] private collaterals;
  // [claimNonce] => accepted ClaimDetails
  ClaimDetails[] private claimDetails;
  // assetName => status. 0 never added; 1 active, 2 inactive/deleted
  mapping(bytes32 => uint8) private assetsMap;
  mapping(address => CollateralInfo) public override collateralStatusMap;
  mapping(uint48 => ExpiryInfo) public override expiryInfoMap;
  // collateral => timestamp => coverAddress, most recent (might be expired) cover created for the collateral and timestamp combination
  mapping(address => mapping(uint48 => address)) public override coverMap;

  modifier onlyDev() {
    require(msg.sender == _dev(), "CoverPool: caller not dev");
    _;
  }

  modifier onlyGov() {
    require(msg.sender == _factory().governance(), "CoverPool: caller not governance");
    _;
  }

  modifier onlyNotPaused() {
    require(!_factory().paused(), "CoverPool: paused");
    _;
  }

  /// @dev Initialize, called once
  function initialize (
    string calldata _coverPoolName,
    bool _extendablePool,
    string[] calldata _assetList,
    address _collateral,
    uint256 _mintRatio,
    uint48 _expiry,
    string calldata _expiryString
  ) external initializer {
    initializeOwner();
    name = _coverPoolName;
    extendablePool = _extendablePool;
    collaterals.push(_collateral);
    collateralStatusMap[_collateral] = CollateralInfo(_mintRatio, 1);
    expiries.push(_expiry);
    expiryInfoMap[_expiry] = ExpiryInfo(_expiryString, 1);

    for (uint256 j = 0; j < _assetList.length; j++) {
      bytes32 asset = StringHelper.stringToBytes32(_assetList[j]);
      require(assetsMap[asset] == 0, "CoverPool: duplicated assets");
      assetList.push(asset);
      assetsMap[asset] = 1;
    }

    // set default delay for redeem
    defaultRedeemDelay = 3 days;
    noclaimRedeemDelay = 3 days;
    yearlyFeeRate = 0.006 ether; // 0.6% yearly rate
    active = true;
    deployCover(_collateral, _expiry);
  }

  /// @notice add coverage (with expiry) for sender, cover must be deployed first
  function addCover(address _collateral, uint48 _expiry, uint256 _amount)
    external override nonReentrant onlyNotPaused
  {
    _validateCover(_collateral, _expiry);
    require(_amount > 0, "CoverPool: amount <= 0");

    address coverAddr = coverMap[_collateral][_expiry];
    require(coverAddr != address(0), "CoverPool: cover not deployed yet");
    ICover cover = ICover(coverAddr);
    require(cover.deployComplete(), "CoverPool: cover deploy incomplete");

    IERC20 collateral = IERC20(_collateral);
    uint256 coverBalanceBefore = collateral.balanceOf(coverAddr);
    collateral.safeTransferFrom(msg.sender, coverAddr, _amount);
    uint256 coverBalanceAfter = collateral.balanceOf(coverAddr);
    uint256 received = coverBalanceAfter - coverBalanceBefore;
    require(received > 0, "CoverPool: collateral transfer failed");

    cover.mint(received, msg.sender);
    emit CoverAdded(coverAddr, msg.sender, received);
  }

  /// @notice add asset to pool, new asset cannot be deleted asset
  function addAsset(string calldata _asset) external override onlyDev {
    bytes32 asset = StringHelper.stringToBytes32(_asset);
    require(extendablePool, "CoverPool: not extendable pool");
    require(assetsMap[asset] != 2, "CoverPool: deleted asset not allowed");

    if (assetsMap[asset] == 0) {
      // first time adding asset, make sure no other asset adding in prrogress
      require(!isAddingAsset, "CoverPool: last asset adding not complete");
      isAddingAsset = true;
      assetsMap[asset] = 1;
      assetList.push(asset);
      emit AssetUpdated(asset, true);
    }

    // continue adding asset, this may not be the first time this func is called for the asset
    address[] memory activeCoversCopy = activeCovers; // save gas
    if (activeCoversCopy.length == 0) return;
    uint256 startGas = gasleft();
    for (uint256 i = 0; i < activeCoversCopy.length; i++) {
      // ensure enough gas left to avoid revert all the previous work
      if (startGas < _factory().deployGasMin()) return;
      // below call deploys two covToken contracts, if cover already added, call will do nothing
      ICover(activeCoversCopy[i]).addAsset(asset);
      startGas = gasleft();
    }
    isAddingAsset = false;
  }

  /// @notice delete asset from pool
  function deleteAsset(string calldata _asset) external override onlyDev {
    bytes32 asset = StringHelper.stringToBytes32(_asset);
    require(assetsMap[asset] == 1, "CoverPool: not active asset");
    bytes32[] memory assetListCopy = assetList; // save gas
    require(assetListCopy.length > 1, "CoverPool: only 1 asset left");

    bytes32[] memory newAssetList = new bytes32[](assetListCopy.length - 1);
    uint256 newListInd = 0;
    for (uint256 i = 0; i < assetListCopy.length; i++) {
      if (asset != assetListCopy[i]) {
        newAssetList[newListInd] = assetListCopy[i];
        newListInd++;
      } else {
        assetsMap[asset] = 2;
        deletedAssetList.push(asset);
        emit AssetUpdated(asset, false);
      }
    }
    assetList = newAssetList;
  }

  /// @notice update status or add new expiry, call deployCover with collateral and expiry before add cover
  function setExpiry(uint48 _expiry, string calldata _expiryString, uint8 _status)
    external override onlyDev
  {
    require(block.timestamp < _expiry, "CoverPool: expiry in the past");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    // status 0 means never added before, inactive status should be 2
    if (expiryInfoMap[_expiry].status == 0) {
      expiries.push(_expiry);
    }
    expiryInfoMap[_expiry] = ExpiryInfo(_expiryString, _status);
  }

  /// @notice update status or add new collateral, call deployCover with collateral and expiry before add cover
  function setCollateral(address _collateral, uint256 _mintRatio, uint8 _status) external override onlyDev {
    require(_collateral != address(0), "CoverPool: address cannot be 0");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    // status 0 means never added before, inactive status should be 2
    if (collateralStatusMap[_collateral].status == 0) {
      collaterals.push(_collateral);
    }
    collateralStatusMap[_collateral] = CollateralInfo(_mintRatio, _status);
  }

  function setYearlyFeeRate(uint256 _yearlyFeeRate) external override {
    require(msg.sender == _factory().governance(), "CoverPool: caller not governance");
    require(_yearlyFeeRate <= 0.1 ether, "CoverPool: must < 10%");
    yearlyFeeRate = _yearlyFeeRate;
  }

  // update status of coverPool, if false, will pause new cover creation
  function setActive(bool _active) external override onlyDev {
    active = _active;
  }

  function setDefaultRedeemDelay(uint256 _defaultRedeemDelay) external override {
    require(msg.sender == _factory().governance(), "CoverPool: caller not governance");
    emit DefaultRedeemDelayUpdated(defaultRedeemDelay, _defaultRedeemDelay);
    defaultRedeemDelay = _defaultRedeemDelay;
  }

  function setNoclaimRedeemDelay(uint256 _noclaimRedeemDelay) external override {
    require(msg.sender == _factory().governance() || msg.sender == _factory().claimManager(), "CoverPool: caller not gov or claimManager");
    require(_noclaimRedeemDelay >= defaultRedeemDelay, "CoverPool: cannot be less than default delay");
    if (_noclaimRedeemDelay != noclaimRedeemDelay) {
      emit NoclaimRedeemDelayUpdated(noclaimRedeemDelay, _noclaimRedeemDelay);
      noclaimRedeemDelay = _noclaimRedeemDelay;
    }
  }

  /**
   * @dev enact accepted claim, all covers are to be paid out
   *  - increment claimNonce
   *  - delete activeCovers list
   *  - only COVER claim manager can call this function
   *
   * Emit ClaimAccepted
   */
  function enactClaim(
    bytes32[] calldata _payoutAssetList,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator,
    uint48 _incidentTimestamp,
    uint256 _coverPoolNonce
  ) external override {
    require(_coverPoolNonce == claimNonce, "CoverPool: nonces do not match");
    require(_payoutAssetList.length == _payoutNumerators.length, "CoverPool: payout asset length don't match");
    ICoverPoolFactory factory = _factory();
    require(msg.sender == factory.claimManager(), "CoverPool: caller not claimManager");

    uint256 totalNum;
    for (uint256 i = 0; i < _payoutAssetList.length; i++) {
      require(assetsMap[_payoutAssetList[i]] == 1, "CoverPool: has non active asset");
      totalNum = totalNum + _payoutNumerators[i];
    }
    require(totalNum <= _payoutDenominator && totalNum > 0, "CoverPool: payout % is not in (0%, 100%]");

    claimNonce = claimNonce + 1;
    delete activeCovers;
    claimDetails.push(ClaimDetails(
      _payoutAssetList,
      _payoutNumerators,
      totalNum,
      _payoutDenominator,
      _incidentTimestamp,
      uint48(block.timestamp)
    ));
    emit ClaimEnacted(_coverPoolNonce);
  }

  function getCoverPoolDetails() external view override
    returns (
      bool _extendablePool,
      bool _isActive,
      uint256 _claimNonce,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      bytes32[] memory _assetList,
      bytes32[] memory _deletedAssetList,
      address[] memory _allActiveCovers,
      address[] memory _allCovers)
  {
    return (extendablePool, isActive, claimNonce, collaterals, expiries, assetList, deletedAssetList, activeCovers, allCovers);
  }

  function getRedeemDelays() external view override returns (uint256 _defaultRedeemDelay, uint256 _noclaimRedeemDelay) {
    return (defaultRedeemDelay, noclaimRedeemDelay);
  }

  function getAssetList() external view override returns (bytes32[] memory _assetList) {
    return assetList;
  }

  function getClaimDetails(uint256 _nonce) external view override returns (ClaimDetails memory) {
    return claimDetails[_nonce];
  }

  /// @notice Will only deploy or complete existing deployment if necessary, safe to call
  function deployCover(address _collateral, uint48 _expiry) public override returns (address addr) {
    addr = coverMap[_collateral][_expiry];

    // Deploy new cover contract if not exist or if claim accepted
    if (addr == address(0) || ICover(addr).claimNonce() != claimNonce) {
      _validateCover(_collateral, _expiry);
      string memory coverName = _getCoverName(_expiry, IERC20(_collateral).symbol());
      bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
      bytes32 salt = keccak256(abi.encodePacked(name, _expiry, _collateral, claimNonce));
      addr = Create2.deploy(0, salt, bytecode);

      bytes memory initData = abi.encodeWithSelector(COVER_INIT_SIGNITURE, coverName, _expiry, _collateral, collateralStatusMap[_collateral].mintRatio, claimNonce);
      address coverImpl = _factory().coverImpl();
      InitializableAdminUpgradeabilityProxy(payable(addr)).initialize(
        coverImpl,
        IOwnable(owner()).owner(),
        initData
      );
      activeCovers.push(addr);
      allCovers.push(addr);
      coverMap[_collateral][_expiry] = addr;
      emit CoverCreated(addr);
    }

    if (!ICover(addr).deployComplete()) {
      ICover(addr).deploy();
    }
  }

  /// @dev generate the cover name. Example: 3POOL_0_DAI_210131
  function _getCoverName(uint48 _expiry, string memory _collateralSymbol)
   internal view returns (string memory)
  {
    return string(abi.encodePacked(
      name, "_",
      StringHelper.uintToString(claimNonce), "_",
      _collateralSymbol, "_",
      expiryInfoMap[_expiry].name
    ));
  }

  function _validateCover(address _collateral, uint48 _expiry) private view {
    require(active, "CoverPool: pool not active");
    require(!isAddingAsset, "CoverPool: waiting to complete adding asset");
    require(collateralStatusMap[_collateral].status == 1, "CoverPool: invalid collateral");
    require(block.timestamp < _expiry && expiryInfoMap[_expiry].status == 1, "CoverPool: invalid expiry");
  }

  /// @dev the owner of this contract is CoverPoolFactory contract. The owner of CoverPoolFactory is dev
  function _dev() private view returns (address) {
    return IOwnable(owner()).owner();
  }

  function _factory() private view returns (ICoverPoolFactory) {
    return ICoverPoolFactory(owner());
  }
}
