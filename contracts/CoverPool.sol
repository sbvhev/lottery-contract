// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/SafeERC20.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/StringHelper.sol";
import "./interfaces/ICover.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";

/**
 * @title CoverPool contract
 * @author crypto-pumpkin
 */
contract CoverPool is ICoverPool, Initializable, ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;

  bytes4 private constant COVER_INIT_SIGNITURE = bytes4(keccak256("initialize(string,uint48,address,uint256)"));
  uint256 private feeNumerator;
  uint256 private feeDenominator;

  /// @notice only active (true) coverPool allows adding more covers (aka. minting more CLAIM and NOCLAIM tokens)
  bool public override isActive;
  bytes32 public override name;
  // nonce of for the coverPool's claim status, it also indicates count of accepted claim in the past
  uint256 public override claimNonce;
  // delay # of seconds for redeem with accepted claim, redeemCollateral is not affected
  uint256 public override claimRedeemDelay;
  // Cover type only, redeemCollateral is not affected
  uint256 public override noclaimRedeemDelay;

  // only active covers, once there is an accepted claim (enactClaim called successfully), this sets to [].
  address[] public override activeCovers;
  address[] private allCovers;
  /// @notice Cover type only, list of every supported expiry, all may not be active.
  uint48[] public override expiries;
  /// @notice list of assets in cover pool
  bytes32[] public override assetList;
  bytes32[] public override deletedAssetList;
  /// @notice list of every supported collateral, all may not be active.
  address[] public override collaterals;
  // [claimNonce] => accepted ClaimDetails
  ClaimDetails[] private claimDetails;
  // @notice assetName => status. 0 never added; 1 active, 2 inactive/deleted
  mapping(bytes32 => uint8) private assetsMap;
  // @notice collateral => status. 0 never set; 1 active, 2 inactive
  mapping(address => uint8) public override collateralStatusMap;
  // Cover type only
  mapping(uint48 => ExpiryInfo) public override expiryInfoMap;
  // collateral => timestamp => coverAddress, most recent cover created for the collateral and timestamp combination
  mapping(address => mapping(uint48 => address)) public override coverMap;

  modifier onlyActive() {
    require(isActive, "CoverPool: coverPool not active");
    _;
  }

  modifier onlyDev() {
    require(msg.sender == _dev(), "CoverPool: caller not dev");
    _;
  }

  modifier onlyGov() {
    require(msg.sender == ICoverPoolFactory(owner()).governance(), "CoverPool: caller not governance");
    _;
  }

  /// @dev Initialize, called once
  function initialize (
    bytes32 _coverPoolName,
    bytes32[] calldata _assetList,
    address _collateral,
    uint48 _expiry,
    string calldata _expiryString
  ) external initializer {
    initializeOwner();
    name = _coverPoolName;
    assetList = _assetList;
    collaterals.push(_collateral);
    collateralStatusMap[_collateral] = 1;
    expiries.push(_expiry);
    expiryInfoMap[_expiry] = ExpiryInfo(_expiryString, 1);

    for (uint256 j = 0; j < _assetList.length; j++) {
      require(assetsMap[_assetList[j]] == 0, "CoverPool: duplicated assets");
      assetsMap[_assetList[j]] = 1;
    }

    // set default delay for redeem
    claimRedeemDelay = 2 days;
    noclaimRedeemDelay = 10 days;
    feeNumerator = 60; // 0.6% yearly rate
    feeDenominator = 10000; // 0 to 65,535
    isActive = true;
  }

  function getCoverPoolDetails()
    external view override
    returns (
      bytes32 _name,
      bool _isActive,
      bytes32[] memory _assetList,
      bytes32[] memory _deletedAssetList,
      uint256 _claimNonce,
      uint256 _claimRedeemDelay,
      uint256 _noclaimRedeemDelay,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      address[] memory _allCovers,
      address[] memory _allActiveCovers)
  {
    return (name, isActive, assetList, deletedAssetList, claimNonce, claimRedeemDelay, noclaimRedeemDelay, collaterals, expiries, allCovers, activeCovers);
  }

  function getRedeemFees()
    external view override
    returns (uint256 _numerator, uint256 _denominator) 
  {
    return (feeNumerator, feeDenominator);
  }

  function getAssetLists() external view override returns (bytes32[] memory _assetList, bytes32[] memory _deletedAssetList) {
    return (assetList, deletedAssetList);
  }

  function getClaimDetails(uint256 _nonce) external view override returns (ClaimDetails memory) {
    return claimDetails[_nonce];
  }

  /// @notice add coverage (with expiry) for sender
  function addCover(address _collateral, uint48 _expiry, uint256 _amount)
    external override onlyActive nonReentrant
  {
    require(_amount > 0, "CoverPool: amount <= 0");
    require(collateralStatusMap[_collateral] == 1, "CoverPool: invalid collateral");
    require(block.timestamp < _expiry && expiryInfoMap[_expiry].status == 1, "CoverPool: invalid expiry");

    // Validate sender collateral balance is > amount
    IERC20 collateral = IERC20(_collateral);
    require(collateral.balanceOf(msg.sender) >= _amount, "CoverPool: amount > collateral balance");

    address addr = _getOrDeployCover(_collateral, _expiry);
    _addCover(collateral, addr, _amount);
  }

  function updateFees(uint256 _feeNumerator, uint256 _feeDenominator) external override onlyGov {
    require(_feeDenominator > 0, "CoverPool: denominator cannot be 0");
    require(_feeDenominator > _feeNumerator, "CoverPool: must < 100%");
    feeNumerator = _feeNumerator;
    feeDenominator = _feeDenominator;
  }

  /// @notice delete asset from pool
  function deleteAsset(bytes32 _asset) external override onlyDev {
    require(assetsMap[_asset] == 1, "CoverPool: not active asset");
    bytes32[] memory assetListCopy = assetList; //save gas
    require(assetListCopy.length > 1, "CoverPool: only 1 asset");

    bytes32[] memory newAssetList = new bytes32[](assetListCopy.length - 1);
    for (uint i = 0; i < assetListCopy.length; i++) {
      if (_asset != assetListCopy[i]) {
        newAssetList[newAssetList.length - 1] = assetListCopy[i];
      } else {
        assetsMap[_asset] = 2;
        deletedAssetList.push(_asset);
        emit AssetUpdated(_asset, false);
      }
    }
    assetList = newAssetList;
  }

  /// @notice update status or add new collateral
  function updateCollateral(address _collateral, uint8 _status) external override onlyDev {
    require(_collateral != address(0), "CoverPool: address cannot be 0");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    if (collateralStatusMap[_collateral] == 0) {
      collaterals.push(_collateral);
    }
    collateralStatusMap[_collateral] = _status;
  }

  /// @notice update status or add new expiry
  function updateExpiry(uint48 _expiry, string calldata _expiryString, uint8 _status)
    external override onlyDev
  {
    require(block.timestamp < _expiry, "CoverPool: expiry in the past");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    if (expiryInfoMap[_expiry].status == 0) {
      expiries.push(_expiry);
    }
    expiryInfoMap[_expiry] = ExpiryInfo(_expiryString, _status);
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
    require(msg.sender == ICoverPoolFactory(owner()).claimManager(), "CoverPool: caller not claimManager");

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
    emit ClaimAccepted(_coverPoolNonce);
  }

  // update status of coverPool, if false, will pause new cover creation
  function setActive(bool _isActive) external override onlyDev {
    isActive = _isActive;
  }

  function updateClaimRedeemDelay(uint256 _claimRedeemDelay) external override onlyGov {
    claimRedeemDelay = _claimRedeemDelay;
  }

  function updateNoclaimRedeemDelay(uint256 _noclaimRedeemDelay) external override onlyGov {
    noclaimRedeemDelay = _noclaimRedeemDelay;
  }

  /// @dev the owner of this contract is CoverPoolFactory contract. The owner of CoverPoolFactory is dev
  function _dev() private view returns (address) {
    return IOwnable(owner()).owner();
  }

  /// @dev generate the cover name. Example: 3POOL_0_DAI_2020_12_31
  function _getCoverNameWithTimestamp(uint48 _expiry, string memory _collateralSymbol)
   internal view returns (string memory) 
  {
    return string(abi.encodePacked(
      _getCoverName(_collateralSymbol),
      "_",
      expiryInfoMap[_expiry].name
    ));
  }

  /// @dev generate the cover name. Example: 3POOL_0_DAI
  function _getCoverName(string memory _collateralSymbol) internal view returns (string memory) {
    return string(abi.encodePacked(
      StringHelper.bytes32ToString(name),
      "_",
      StringHelper.uintToString(claimNonce),
      "_",
      _collateralSymbol
    ));
  }

  function _getOrDeployCover(address _collateral, uint48 _expiry) private returns (address addr) {
    addr = coverMap[_collateral][_expiry];

    // Deploy new cover contract if not exist or if claim accepted
    if (addr == address(0) || ICover(addr).claimNonce() != claimNonce) {
      string memory coverName = _getCoverNameWithTimestamp(_expiry, IERC20(_collateral).symbol());
      bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
      bytes32 salt = keccak256(abi.encodePacked(name, _expiry, _collateral, claimNonce));
      addr = Create2.deploy(0, salt, bytecode);

      bytes memory initData = abi.encodeWithSelector(COVER_INIT_SIGNITURE, coverName, _expiry, _collateral, claimNonce);
      address coverImpl = ICoverPoolFactory(owner()).coverImpl();
      InitializableAdminUpgradeabilityProxy(payable(addr)).initialize(
        coverImpl,
        IOwnable(owner()).owner(),
        initData
      );
      activeCovers.push(addr);
      allCovers.push(addr);
      coverMap[_collateral][_expiry] = addr;
    }
  }

  function _addCover(IERC20 _collateral, address _cover, uint256 _amount) private {
    uint256 coverBalanceBefore = _collateral.balanceOf(_cover);
    _collateral.safeTransferFrom(msg.sender, _cover, _amount);
    uint256 coverBalanceAfter = _collateral.balanceOf(_cover);
    require(coverBalanceAfter > coverBalanceBefore, "CoverPool: collateral transfer failed");

    emit CoverAdded(_cover, coverBalanceAfter - coverBalanceBefore);
    ICover(_cover).mint(coverBalanceAfter - coverBalanceBefore, msg.sender);
  }
}
