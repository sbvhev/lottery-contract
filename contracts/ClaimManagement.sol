// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;
pragma experimental ABIEncoderV2;

import "./ClaimConfig.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";
import "./interfaces/IClaimManagement.sol";
import "./utils/SafeERC20.sol";

/**
 * @title Claim Management for claims filed for a COVER supported coverPool
 * @author Alan + crypto-pumpkin
 */
contract ClaimManagement is IClaimManagement, ClaimConfig {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  // coverPool => nonce => Claim[]
  mapping(address => mapping(uint256 => Claim[])) public override coverPoolClaims;

  modifier onlyApprovedDecider() {
    if (isAuditorVoting()) {
      require(msg.sender == auditor, "COVER_CM: !auditor");
    } else {
      require(msg.sender == governance, "COVER_CM: !governance");
    }
    _;
  }

  modifier onlyWhenAuditorVoting() {
    require(isAuditorVoting(), "COVER_CM: !isAuditorVoting");
    _;
  }

  /**
   * @notice Initialize governance and treasury addresses
   * @dev Governance address cannot be set to owner address; `_auditor` can be 0.
   * @param _governance address: address of the governance account
   * @param _auditor address: address of the auditor account
   * @param _treasury address: address of the treasury account
   * @param _coverPoolFactory address: address of the coverPool factory
   */
  constructor(address _governance, address _auditor, address _treasury, address _coverPoolFactory) {
    require(
      _governance != msg.sender && _governance != address(0), 
      "COVER_CC: governance cannot be owner or 0"
    );
    require(_treasury != address(0), "COVER_CM: treasury cannot be 0");
    require(_coverPoolFactory != address(0), "COVER_CM: coverPool factory cannot be 0");
    governance = _governance;
    auditor = _auditor;
    treasury = _treasury;
    coverPoolFactory = _coverPoolFactory;

    initializeOwner();
  }

  /**
   * @notice File a claim for a COVER-supported contract `_coverPool` 
   * by paying the `coverPoolClaimFee[_coverPool]` fee
   * @dev `_incidentTimestamp` must be within the past 14 days
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _coverPoolName bytes32: coverPool name for `_coverPool`
   * @param _incidentTimestamp uint48: timestamp of the claim incident
   * 
   * Emits ClaimFiled
   */ 
  function fileClaim(address _coverPool, bytes32 _coverPoolName, uint48 _incidentTimestamp) 
    external 
    override 
  {
    require(_coverPool != address(0), "COVER_CM: coverPool cannot be 0");
    require(
      _coverPool == getAddressFromFactory(_coverPoolName), 
      "COVER_CM: invalid coverPool address"
    );
    require(
      block.timestamp.sub(_incidentTimestamp) <= getFileClaimWindow(_coverPool),
      "COVER_CM: block.timestamp - incidentTimestamp > fileClaimWindow"
    );
    uint256 nonce = getCoverPoolNonce(_coverPool);
    uint256 claimFee = getCoverPoolClaimFee(_coverPool);
    coverPoolClaims[_coverPool][nonce].push(Claim({
      state: ClaimState.Filed,
      filedBy: msg.sender,
      payoutNumerator: 0,
      payoutDenominator: 1,
      filedTimestamp: uint48(block.timestamp),
      incidentTimestamp: _incidentTimestamp,
      decidedTimestamp: 0,
      feePaid: claimFee
    }));
    feeCurrency.safeTransferFrom(msg.sender, address(this), claimFee);
    _updateCoverPoolClaimFee(_coverPool);
    emit ClaimFiled({
      isForced: false,
      filedBy: msg.sender,
      coverPool: _coverPool,
      incidentTimestamp: _incidentTimestamp,
      nonce: nonce,
      index: coverPoolClaims[_coverPool][nonce].length - 1,
      feePaid: claimFee
    });
  }

  /**
   * @notice Force file a claim for a COVER-supported contract `_coverPool`
   * that bypasses validateClaim by paying the `forceClaimFee` fee
   * @dev `_incidentTimestamp` must be within the past 14 days. 
   * Only callable when isAuditorVoting is true
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _coverPoolName bytes32: coverPool name for `_coverPool`
   * @param _incidentTimestamp uint48: timestamp of the claim incident
   * 
   * Emits ClaimFiled
   */
  function forceFileClaim(address _coverPool, bytes32 _coverPoolName, uint48 _incidentTimestamp)
    external 
    override 
    onlyWhenAuditorVoting 
  {
    require(_coverPool != address(0), "COVER_CM: coverPool cannot be 0");
    require(
      _coverPool == getAddressFromFactory(_coverPoolName), 
      "COVER_CM: invalid coverPool address"
    );  
    require(
      block.timestamp.sub(_incidentTimestamp) <= getFileClaimWindow(_coverPool),
      "COVER_CM: block.timestamp - incidentTimestamp > fileClaimWindow"
    );
    uint256 nonce = getCoverPoolNonce(_coverPool);
    coverPoolClaims[_coverPool][nonce].push(Claim({
      state: ClaimState.ForceFiled,
      filedBy: msg.sender,
      payoutNumerator: 0,
      payoutDenominator: 1,
      filedTimestamp: uint48(block.timestamp),
      incidentTimestamp: _incidentTimestamp,
      decidedTimestamp: 0,
      feePaid: forceClaimFee
    }));
    feeCurrency.safeTransferFrom(msg.sender, address(this), forceClaimFee);
    emit ClaimFiled({
      isForced: true,
      filedBy: msg.sender,
      coverPool: _coverPool,
      incidentTimestamp: _incidentTimestamp,
      nonce: nonce,
      index: coverPoolClaims[_coverPool][nonce].length - 1,
      feePaid: forceClaimFee
    });
  }

  /**
   * @notice Validates whether claim will be passed to approvedDecider to decideClaim
   * @dev Only callable if isAuditorVoting is true
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _nonce uint256: nonce of the coverPool
   * @param _index uint256: index of the claim
   * @param _claimIsValid bool: true if claim is valid and passed to auditor, false otherwise
   *   
   * Emits ClaimValidated
   */
  function validateClaim(address _coverPool, uint256 _nonce, uint256 _index, bool _claimIsValid)
    external 
    override 
    onlyGov
    onlyWhenAuditorVoting 
  {
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    require(
      _nonce == getCoverPoolNonce(_coverPool), 
      "COVER_CM: input nonce != coverPool nonce"
      );
    require(claim.state == ClaimState.Filed, "COVER_CM: claim not filed");
    if (_claimIsValid) {
      claim.state = ClaimState.Validated;
      _resetCoverPoolClaimFee(_coverPool);
    } else {
      claim.state = ClaimState.Invalidated;
      claim.decidedTimestamp = uint48(block.timestamp);
      feeCurrency.safeTransfer(treasury, claim.feePaid);
    }
    emit ClaimValidated({
      claimIsValid: _claimIsValid,
      coverPool: _coverPool,
      nonce: _nonce,
      index: _index
    });
  }

  /**
   * @notice Decide whether claim for a coverPool should be accepted(will payout) or denied
   * @dev Only callable by approvedDecider
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _nonce uint256: nonce of the coverPool
   * @param _index uint256: index of the claim
   * @param _claimIsAccepted bool: true if claim is accepted and will payout, otherwise false
   * @param _payoutNumerator uint256: numerator of percent payout, 0 if _claimIsAccepted = false
   * @param _payoutDenominator uint256: denominator of percent payout
   *
   * Emits ClaimDecided
   */
  function decideClaim(
    address _coverPool, 
    uint256 _nonce, 
    uint256 _index, 
    bool _claimIsAccepted, 
    uint16 _payoutNumerator, 
    uint16 _payoutDenominator
  )   
    external
    override 
    onlyApprovedDecider
  {
    require(
      _nonce == getCoverPoolNonce(_coverPool), 
      "COVER_CM: input nonce != coverPool nonce"
    );
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    if (isAuditorVoting()) {
      require(
        claim.state == ClaimState.Validated || 
        claim.state == ClaimState.ForceFiled, 
        "COVER_CM: claim not validated or forceFiled"
      );
    } else {
      require(claim.state == ClaimState.Filed, "COVER_CM: claim not filed");
    }

    if (_isDecisionWindowPassed(claim)) {
      // Max decision claim window passed, claim is default to Denied
      _claimIsAccepted = false;
    }
    if (_claimIsAccepted) {
      require(_payoutNumerator > 0, "COVER_CM: claim accepted, but payoutNumerator == 0");
      if (allowPartialClaim) {
        require(
          _payoutNumerator <= _payoutDenominator, 
          "COVER_CM: payoutNumerator > payoutDenominator"
        );
      } else {
        require(
          _payoutNumerator == _payoutDenominator, 
          "COVER_CM: payoutNumerator != payoutDenominator"
        );
      }
      claim.state = ClaimState.Accepted;
      claim.payoutNumerator = _payoutNumerator;
      claim.payoutDenominator = _payoutDenominator;
      feeCurrency.safeTransfer(claim.filedBy, claim.feePaid);
      _resetCoverPoolClaimFee(_coverPool);
      // TODO use new enact claim on coverPool
      // ICoverPool(_coverPool).enactClaim(_payoutNumerator, _payoutDenominator, claim.incidentTimestamp, _nonce);
    } else {
      require(_payoutNumerator == 0, "COVER_CM: claim denied (default if passed window), but payoutNumerator != 0");
      claim.state = ClaimState.Denied;
      feeCurrency.safeTransfer(treasury, claim.feePaid);
    }
    claim.decidedTimestamp = uint48(block.timestamp);
    emit ClaimDecided({
      claimIsAccepted: _claimIsAccepted, 
      coverPool: _coverPool, 
      nonce: _nonce, 
      index: _index, 
      payoutNumerator: _payoutNumerator, 
      payoutDenominator: _payoutDenominator
    });
  }

  /**
   * @notice Get all claims for coverPool `_coverPool` and nonce `_nonce` in state `_state`
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _nonce uint256: nonce of the coverPool
   * @param _state ClaimState: state of claim
   * @return all claims for coverPool and nonce in given state
   */
  function getAllClaimsByState(address _coverPool, uint256 _nonce, ClaimState _state)
    external 
    view 
    override 
    returns (Claim[] memory) 
  {
    Claim[] memory allClaims = coverPoolClaims[_coverPool][_nonce];
    uint256 count;
    Claim[] memory temp = new Claim[](allClaims.length);
    for (uint i = 0; i < allClaims.length; i++) {
      if (allClaims[i].state == _state) {
        temp[count] = allClaims[i];
        count++;
      }
    }
    Claim[] memory claimsByState = new Claim[](count);
    for (uint i = 0; i < count; i++) {
      claimsByState[i] = temp[i];
    }
    return claimsByState;
  }

  /**
   * @notice Get all claims for coverPool `_coverPool` and nonce `_nonce`
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _nonce uint256: nonce of the coverPool
   * @return all claims for coverPool and nonce
   */
  function getAllClaimsByNonce(address _coverPool, uint256 _nonce) 
    external 
    view 
    override 
    returns (Claim[] memory) 
  {
    return coverPoolClaims[_coverPool][_nonce];
  }

  /**
   * @notice Get the coverPool address from the coverPool factory
   * @param _coverPoolName bytes32: coverPool name
   * @return address corresponding to the coverPool name `_coverPoolName`
   */
  function getAddressFromFactory(bytes32 _coverPoolName) public view override returns (address) {
    return ICoverPoolFactory(coverPoolFactory).coverPools(_coverPoolName);
  }

  /**
   * @notice Get the current nonce for coverPool `_coverPool`
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @return the current nonce for coverPool `_coverPool`
   */
  function getCoverPoolNonce(address _coverPool) public view override returns (uint256) {
    return ICoverPool(_coverPool).claimNonce();
  }

  /**
   * The times passed since the claim was filed has to be less than the max claim decision window
   */
  function _isDecisionWindowPassed(Claim memory claim) private view returns (bool) {
    return block.timestamp.sub(claim.filedTimestamp) > maxClaimDecisionWindow.sub(1 hours);
  }
} 