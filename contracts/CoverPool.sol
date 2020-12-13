// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;
pragma abicoder v2;

import "./proxy/InitializableAdminUpgradeabilityProxy.sol";
import "./utils/Create2.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./utils/SafeMath.sol";
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
 * @notice Each CoverPool can have two types of coverages (cover with expiry like V1, or perpetual cover)
 */
contract CoverPool is ICoverPool, Initializable, ReentrancyGuard, Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  bytes4 private constant COVERWITHEXPIRY_INIT_SIGNITURE = bytes4(keccak256("initialize(string,bytes32[],uint48,address,uint256)"));
  bytes4 private constant PERPCOVER_INIT_SIGNITURE = bytes4(keccak256("initialize(string,bytes32[],address,uint256)"));
  uint256 private perpFeeNum;
  uint256 private expiryFeeNum;
  uint256 private feeDenominator;
  uint256 private feeUpdatedAt;

  /// @notice only active (true) coverPool allows adding more covers (aka. minting more CLAIM and NOCLAIM tokens)
  bool public override isActive;
  bytes32 public override name;
  // nonce of for the coverPool's claim status, it also indicates count of accepted claim in the past
  uint256 public override claimNonce;
  // delay # of seconds for redeem with accepted claim, redeemCollateral is not affected
  uint256 public override claimRedeemDelay;
  // CoverWithExpiry type only, redeemCollateral is not affected
  uint256 public override noclaimRedeemDelay;

  // only active covers, once there is an accepted claim (enactClaim called successfully), this sets to [].
  address[] public override activeCovers;
  address[] private allCovers;
  /// @notice CoverWithExpiry type only, list of every supported expiry, all may not be active.
  uint48[] public override expiries;
  /// @notice list of assets in cover pool
  bytes32[] public override assetList;
  /// @notice list of every supported collateral, all may not be active.
  address[] public override collaterals;
  // [claimNonce] => accepted ClaimDetails
  ClaimDetails[] private claimDetails;
  // @notice collateral => status. 0 never set; 1 active, 2 inactive
  mapping(address => uint8) public override collateralStatusMap;
  // CoverWithExpiry type only
  mapping(uint48 => ExpiryInfo) public override expiryInfoMap;
  // collateral => timestamp => coverAddress, most recent cover created for the collateral and timestamp combination
  mapping(address => mapping(uint48 => address)) public override coverWithExpiryMap;
  // collateral => coverAddress, most recent perpetual cover created for the collateral
  mapping(address => address) public override perpCoverMap;

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
    uint48[] calldata _expiries,
    bytes32[] calldata _expiryNames
  ) external initializer {
    initializeOwner();
    name = _coverPoolName;
    assetList = _assetList;
    collaterals.push(_collateral);
    expiries = _expiries;
    collateralStatusMap[_collateral] = 1;
    for (uint i = 0; i < _expiries.length; i++) {
      if (block.timestamp < _expiries[i]) {
        expiryInfoMap[_expiries[i]] = ExpiryInfo(_expiryNames[i], 1);
      }
    }

    // set default delay for redeem
    claimRedeemDelay = 2 days;
    noclaimRedeemDelay = 10 days;
    perpFeeNum = 12; // fee per rollover period for perp cover, around 0.13% per month
    expiryFeeNum = 12; // 0 to 65,535, 0.2% per expiry
    feeDenominator = 1000; // 0 to 65,535
    feeUpdatedAt = block.timestamp;
    isActive = true;
  }

  function getCoverPoolDetails()
    external view override
    returns (
      bytes32 _name,
      bool _isActive,
      bytes32[] memory _assetList,
      uint256 _claimNonce,
      uint256 _claimRedeemDelay,
      uint256 _noclaimRedeemDelay,
      address[] memory _collaterals,
      uint48[] memory _expiries,
      address[] memory _allCovers,
      address[] memory _allActiveCovers)
  {
    return (name, isActive, assetList, claimNonce, claimRedeemDelay, noclaimRedeemDelay, collaterals, expiries, allCovers, activeCovers);
  }

  function getRedeemFees()
    external view override
    returns (uint256 _perpNumerator, uint256 _numerator, uint256 _denominator, uint256 _updatedAt) 
  {
    return (perpFeeNum, expiryFeeNum, feeDenominator, feeUpdatedAt);
  }

  function getClaimDetails(uint256 _nonce) external view override returns (ClaimDetails memory) {
    return claimDetails[_nonce];
  }

  /// @notice add perpetual coverage for sender
  function addPerpCover(address _collateral, uint256 _amount)
    external override onlyActive nonReentrant
  {
    require(_amount > 0, "CoverPool: amount <= 0");
    require(collateralStatusMap[_collateral] == 1, "CoverPool: invalid collateral");

    // Validate sender collateral balance is > amount
    IERC20 collateral = IERC20(_collateral);
    require(collateral.balanceOf(msg.sender) >= _amount, "CoverPool: amount > collateral balance");

    address addr = perpCoverMap[_collateral];

    // Deploy new cover contract if not exist or if claim accepted
    if (addr == address(0) || ICover(addr).claimNonce() != claimNonce) {
      string memory coverName = _getCoverName(collateral.symbol());

      bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
      bytes32 salt = keccak256(abi.encodePacked(name, _collateral, claimNonce));
      addr = Create2.deploy(0, salt, bytecode);

      bytes memory initData = abi.encodeWithSelector(PERPCOVER_INIT_SIGNITURE, coverName, assetList, _collateral, claimNonce);
      address perpCoverImpl = ICoverPoolFactory(owner()).perpCoverImpl();
      InitializableAdminUpgradeabilityProxy(payable(addr)).initialize(
        perpCoverImpl,
        IOwnable(owner()).owner(),
        initData
      );
      activeCovers.push(addr);
      allCovers.push(addr);
      perpCoverMap[_collateral] = addr;
    }
    _addCover(collateral, addr, _amount);
  }

  /// @notice add coverage (with expiry) for sender
  function addCoverWithExpiry(address _collateral, uint48 _expiry, uint256 _amount)
    external override onlyActive nonReentrant
  {
    require(_amount > 0, "CoverPool: amount <= 0");
    require(collateralStatusMap[_collateral] == 1, "CoverPool: invalid collateral");
    require(block.timestamp < _expiry && expiryInfoMap[_expiry].status == 1, "CoverPool: invalid expiry");

    // Validate sender collateral balance is > amount
    IERC20 collateral = IERC20(_collateral);
    require(collateral.balanceOf(msg.sender) >= _amount, "CoverPool: amount > collateral balance");

    address addr = coverWithExpiryMap[_collateral][_expiry];

    // Deploy new cover contract if not exist or if claim accepted
    if (addr == address(0) || ICover(addr).claimNonce() != claimNonce) {
      string memory coverName = _getCoverNameWithTimestamp(_expiry, collateral.symbol());

      bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
      bytes32 salt = keccak256(abi.encodePacked(name, _expiry, _collateral, claimNonce));
      addr = Create2.deploy(0, salt, bytecode);

      bytes memory initData = abi.encodeWithSelector(COVERWITHEXPIRY_INIT_SIGNITURE, coverName, assetList, _expiry, _collateral, claimNonce);
      address coverImpl = ICoverPoolFactory(owner()).coverImpl();
      InitializableAdminUpgradeabilityProxy(payable(addr)).initialize(
        coverImpl,
        IOwnable(owner()).owner(),
        initData
      );
      activeCovers.push(addr);
      allCovers.push(addr);
      coverWithExpiryMap[_collateral][_expiry] = addr;
    }
    _addCover(collateral, addr, _amount);
  }

  function updateFees(uint256 _perpFeeNum, uint256 _expiryFeeNum, uint256 _feeDenominator) external override onlyGov {
    require(_feeDenominator > 0, "CoverPool: denominator cannot be 0");
    require(_feeDenominator > _perpFeeNum && _feeDenominator > _expiryFeeNum, "CoverPool: must < 100%");
    perpFeeNum = _perpFeeNum;
    expiryFeeNum = _expiryFeeNum;
    feeDenominator = _feeDenominator;
    feeUpdatedAt = block.timestamp;
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
  function updateExpiry(uint48 _expiry, bytes32 _expiryName, uint8 _status)
    external override onlyDev
  {
    require(block.timestamp < _expiry, "CoverPool: invalid expiry");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    if (expiryInfoMap[_expiry].status == 0) {
      expiries.push(_expiry);
    }
    expiryInfoMap[_expiry] = ExpiryInfo(_expiryName, _status);
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
      totalNum = totalNum.add(_payoutNumerators[i]);
    }
    require(totalNum <= _payoutDenominator && totalNum > 0, "CoverPool: payout % is not in (0%, 100%]");

    claimNonce = claimNonce.add(1);
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
      StringHelper.bytes32ToString(expiryInfoMap[_expiry].name)
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

  function _addCover(IERC20 _collateral, address _cover, uint256 _amount) private {
    uint256 coverBalanceBefore = _collateral.balanceOf(_cover);
    _collateral.safeTransferFrom(msg.sender, _cover, _amount);
    uint256 coverBalanceAfter = _collateral.balanceOf(_cover);
    require(coverBalanceAfter > coverBalanceBefore, "CoverPool: collateral transfer failed");

    emit CoverAdded(_cover, coverBalanceAfter.sub(coverBalanceBefore));
    ICover(_cover).mint(coverBalanceAfter.sub(coverBalanceBefore), msg.sender);
  }
}
