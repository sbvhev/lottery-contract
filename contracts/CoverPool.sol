// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

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
 * @author crypto-pumpkin@github
 */
contract CoverPool is ICoverPool, Initializable, ReentrancyGuard, Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  struct ClaimDetails {
    uint16 payoutNumerator; // 0 to 65,535
    uint16 payoutDenominator; // 0 to 65,535
    uint48 incidentTimestamp;
    uint48 claimEnactedTimestamp;
  }

  struct ExpirationTimestampInfo {
    bytes32 name;
    uint8 status; // 0 never set; 1 active, 2 inactive
  }

  bytes4 private constant COVER_INIT_SIGNITURE = bytes4(keccak256("initialize(string,uint48,address,uint256)"));

  uint16 private redeemFeeNumerator;
  uint16 private redeemFeeDenominator;

  /// @notice only active (true) coverPool allows adding more covers
  bool public override active;

  bytes32 public override name;

  // nonce of for the coverPool's claim status, it also indicates count of accepted claim in the past
  uint256 public override claimNonce;

  // delay # of seconds for redeem with accepted claim, redeemCollateral is not affected
  uint256 public override claimRedeemDelay;
  // delay # of seconds for redeem without accepted claim, redeemCollateral is not affected
  uint256 public override noclaimRedeemDelay;

  // only active covers, once there is an accepted claim (enactClaim called successfully), this sets to [].
  address[] public override activeCovers;
  address[] private allCovers;

  /// @notice list of every supported expirationTimestamp, all may not be active.
  uint48[] public override expirationTimestamps;

  /// @notice list of asset in pool
  bytes32[] public override assetList;

  /// @notice list of every supported collateral, all may not be active.
  address[] public override collaterals;

  // [claimNonce] => accepted ClaimDetails
  ClaimDetails[] public override claimDetails;

  // @notice collateral => status. 0 never set; 1 active, 2 inactive
  mapping(address => uint8) public override collateralStatusMap;

  mapping(uint48 => ExpirationTimestampInfo) public override expirationTimestampMap;

  // collateral => timestamp => coverAddress, most recent cover created for the collateral and timestamp combination
  mapping(address => mapping(uint48 => address)) public override coverMap;
  // collateral => coverAddress, most recent perpetual cover created for the collateral
  mapping(address => address) public override perpCoverMap;

  modifier onlyActive() {
    require(active, "CoverPool: coverPool not active");
    _;
  }

  modifier onlyDev() {
    require(msg.sender == _dev(), "CoverPool: caller not dev");
    _;
  }

  modifier onlyGovernance() {
    require(msg.sender == ICoverPoolFactory(owner()).governance(), "CoverPool: caller not governance");
    _;
  }

  /// @dev Initialize, called once
  function initialize (
    bytes32 _coverPoolName,
    bytes32[] calldata _assetList,
    address _collateral,
    uint48[] calldata _expirationTimestamps,
    bytes32[] calldata _expirationTimestampNames
  )
    external initializer
  {
    name = _coverPoolName;
    assetList = _assetList;
    collaterals.push(_collateral);
    active = true;
    expirationTimestamps = _expirationTimestamps;

    collateralStatusMap[_collateral] = 1;

    for (uint i = 0; i < _expirationTimestamps.length; i++) {
      if (block.timestamp < _expirationTimestamps[i]) {
        expirationTimestampMap[_expirationTimestamps[i]] = ExpirationTimestampInfo(
          _expirationTimestampNames[i],
          1
        );
      }
    }

    // set default delay for redeem
    claimRedeemDelay = 2 days;
    noclaimRedeemDelay = 10 days;
    redeemFeeNumerator = 10; // 0 to 65,535
    redeemFeeDenominator = 10000; // 0 to 65,535

    initializeOwner();
  }

  function getRedeemFees() external view override returns (uint16 _numerator, uint16 _denominator) {
    return (redeemFeeNumerator, redeemFeeDenominator);
  }

  function getCoverPoolDetails()
    external view override returns (
      bytes32 _name,
      bool _active,
      bytes32[] memory _assetList,
      uint256 _claimNonce,
      uint256 _claimRedeemDelay,
      uint256 _noclaimRedeemDelay,
      address[] memory _collaterals,
      uint48[] memory _expirationTimestamps,
      address[] memory _allCovers,
      address[] memory _allActiveCovers
    )
  {
    return (
      name,
      active,
      assetList,
      claimNonce,
      claimRedeemDelay,
      noclaimRedeemDelay,
      getCollaterals(),
      getExpirationTimestamps(),
      getAllCovers(),
      getAllActiveCovers()
    );
  }

  function collateralsLength() external view override returns (uint256) {
    return collaterals.length;
  }

  function expirationTimestampsLength() external view override returns (uint256) {
    return expirationTimestamps.length;
  }

  function activeCoversLength() external view override returns (uint256) {
    return activeCovers.length;
  }

  function claimsLength() external view override returns (uint256) {
    return claimDetails.length;
  }

  function addPerpCover(address _collateral, uint256 _amount)
    external override onlyActive nonReentrant returns (bool)
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

      bytes memory initData = abi.encodeWithSelector(COVER_INIT_SIGNITURE, coverName, 0, _collateral, claimNonce);
      address coverImplementation = ICoverPoolFactory(owner()).coverImplementation();
      InitializableAdminUpgradeabilityProxy(payable(addr)).initialize(
        coverImplementation,
        IOwnable(owner()).owner(),
        initData
      );

      activeCovers.push(addr);
      allCovers.push(addr);
      perpCoverMap[_collateral] = addr;
    }

    // move collateral to the cover contract and mint CovTokens to sender
    uint256 coverBalanceBefore = collateral.balanceOf(addr);
    collateral.safeTransferFrom(msg.sender, addr, _amount);
    uint256 coverBalanceAfter = collateral.balanceOf(addr);
    require(coverBalanceAfter > coverBalanceBefore, "CoverPool: collateral transfer failed");
    ICover(addr).mint(coverBalanceAfter.sub(coverBalanceBefore), msg.sender);
    return true;
  }

  /**
   * @notice add cover for sender
   *  - transfer collateral from sender to cover contract
   *  - mint the same amount CLAIM covToken to sender
   *  - mint the same amount NOCLAIM covToken to sender
   */
  function addCover(address _collateral, uint48 _timestamp, uint256 _amount)
    external override onlyActive nonReentrant returns (bool)
  {
    require(_amount > 0, "CoverPool: amount <= 0");
    require(collateralStatusMap[_collateral] == 1, "CoverPool: invalid collateral");
    require(block.timestamp < _timestamp && expirationTimestampMap[_timestamp].status == 1, "CoverPool: invalid expiration date");

    // Validate sender collateral balance is > amount
    IERC20 collateral = IERC20(_collateral);
    require(collateral.balanceOf(msg.sender) >= _amount, "CoverPool: amount > collateral balance");

    address addr = coverMap[_collateral][_timestamp];

    // Deploy new cover contract if not exist or if claim accepted
    if (addr == address(0) || ICover(addr).claimNonce() != claimNonce) {
      string memory coverName = _getCoverNameWithTimestamp(_timestamp, collateral.symbol());

      bytes memory bytecode = type(InitializableAdminUpgradeabilityProxy).creationCode;
      bytes32 salt = keccak256(abi.encodePacked(name, _timestamp, _collateral, claimNonce));
      addr = Create2.deploy(0, salt, bytecode);

      bytes memory initData = abi.encodeWithSelector(COVER_INIT_SIGNITURE, coverName, _timestamp, _collateral, claimNonce);
      address coverImplementation = ICoverPoolFactory(owner()).coverImplementation();
      InitializableAdminUpgradeabilityProxy(payable(addr)).initialize(
        coverImplementation,
        IOwnable(owner()).owner(),
        initData
      );

      activeCovers.push(addr);
      allCovers.push(addr);
      coverMap[_collateral][_timestamp] = addr;
    }

    // move collateral to the cover contract and mint CovTokens to sender
    uint256 coverBalanceBefore = collateral.balanceOf(addr);
    collateral.safeTransferFrom(msg.sender, addr, _amount);
    uint256 coverBalanceAfter = collateral.balanceOf(addr);
    require(coverBalanceAfter > coverBalanceBefore, "CoverPool: collateral transfer failed");
    ICover(addr).mint(coverBalanceAfter.sub(coverBalanceBefore), msg.sender);
    return true;
  }

  /// @notice update status or add new expiration timestamp
  function updateExpirationTimestamp(uint48 _expirationTimestamp, bytes32 _expirationTimestampName, uint8 _status) external override onlyDev returns (bool) {
    require(block.timestamp < _expirationTimestamp, "CoverPool: invalid expiration date");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    if (expirationTimestampMap[_expirationTimestamp].status == 0) {
      expirationTimestamps.push(_expirationTimestamp);
    }
    expirationTimestampMap[_expirationTimestamp] = ExpirationTimestampInfo(
      _expirationTimestampName,
      _status
    );
    return true;
  }

  /// @notice update status or add new collateral
  function updateCollateral(address _collateral, uint8 _status) external override onlyDev returns (bool) {
    require(_collateral != address(0), "CoverPool: address cannot be 0");
    require(_status > 0 && _status < 3, "CoverPool: status not in (0, 2]");

    if (collateralStatusMap[_collateral] == 0) {
      collaterals.push(_collateral);
    }
    collateralStatusMap[_collateral] = _status;
    return true;
  }

  function updateFees(
    uint16 _redeemFeeNumerator,
    uint16 _redeemFeeDenominator
  )
    external override onlyGovernance returns (bool)
  {
    require(_redeemFeeDenominator > 0, "CoverPool: denominator cannot be 0");
    redeemFeeNumerator = _redeemFeeNumerator;
    redeemFeeDenominator = _redeemFeeDenominator;
    return true;
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
    uint16 _payoutNumerator,
    uint16 _payoutDenominator,
    uint48 _incidentTimestamp,
    uint256 _coverPoolNonce
  )
   external override returns (bool)
  {
    require(_coverPoolNonce == claimNonce, "CoverPool: nonces do not match");
    require(_payoutNumerator <= _payoutDenominator && _payoutNumerator > 0, "CoverPool: payout % is not in (0%, 100%]");
    require(msg.sender == ICoverPoolFactory(owner()).claimManager(), "CoverPool: caller not claimManager");

    claimNonce = claimNonce.add(1);
    delete activeCovers;
    claimDetails.push(ClaimDetails(
      _payoutNumerator,
      _payoutDenominator,
      _incidentTimestamp,
      uint48(block.timestamp)
    ));
    emit ClaimAccepted(_coverPoolNonce);
    return true;
  }

  // update status of coverPool, if false, will pause new cover creation
  function setActive(bool _active) external override onlyDev returns (bool) {
    active = _active;
    return true;
  }

  function updateClaimRedeemDelay(uint256 _claimRedeemDelay)
   external override onlyGovernance returns (bool)
  {
    claimRedeemDelay = _claimRedeemDelay;
    return true;
  }

  function updateNoclaimRedeemDelay(uint256 _noclaimRedeemDelay)
   external override onlyGovernance returns (bool)
  {
    noclaimRedeemDelay = _noclaimRedeemDelay;
    return true;
  }

  function getAllCovers() private view returns (address[] memory) {
    return allCovers;
  }

  function getAllActiveCovers() private view returns (address[] memory) {
    return activeCovers;
  }

  function getCollaterals() private view returns (address[] memory) {
    return collaterals;
  }

  function getExpirationTimestamps() private view returns (uint48[] memory) {
    return expirationTimestamps;
  }

  /// @dev the owner of this contract is CoverPoolFactory contract. The owner of CoverPoolFactory is dev
  function _dev() private view returns (address) {
    return IOwnable(owner()).owner();
  }

  /// @dev generate the cover name. Example: 3POOL_0_DAI_2020_12_31
  function _getCoverNameWithTimestamp(uint48 _expirationTimestamp, string memory _collateralSymbol)
   internal view returns (string memory) 
  {
    return string(abi.encodePacked(
      _getCoverName(_collateralSymbol),
      "_",
      StringHelper.bytes32ToString(expirationTimestampMap[_expirationTimestamp].name)
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
}
