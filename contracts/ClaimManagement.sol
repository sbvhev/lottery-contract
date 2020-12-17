// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

  // coverPool => nonce => Claim[]
  mapping(address => mapping(uint256 => Claim[])) private coverPoolClaims;

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

  function getCoverPoolClaims(address _coverPool, uint256 _nonce, uint256 _index) external view override returns (Claim memory) {
    return coverPoolClaims[_coverPool][_nonce][_index];
  }

  /**
   * @notice File a claim for a COVER-supported contract `_coverPool` 
   * by paying the `coverPoolClaimFee[_coverPool]` fee
   * @dev `_incidentTimestamp` must be within the past 3 days
   * 
   * Emits ClaimUpdated
   */ 
  function fileClaim(
    address _coverPool,
    string calldata _coverPoolName,
    bytes32[] calldata _exploitAssets,
    uint48 _incidentTimestamp,
    string calldata _description
  ) external override {
    require(_coverPool != address(0), "COVER_CM: coverPool cannot be 0");
    require(
      _coverPool == getAddressFromFactory(_coverPoolName), 
      "COVER_CM: invalid coverPool address"
    );
    require(
      block.timestamp - _incidentTimestamp <= getFileClaimWindow(_coverPool),
      "COVER_CM: block.timestamp - incidentTimestamp > fileClaimWindow"
    );
    uint256 nonce = getCoverPoolNonce(_coverPool);
    uint256 claimFee = getCoverPoolClaimFee(_coverPool);
    coverPoolClaims[_coverPool][nonce].push(Claim({
      state: ClaimState.Filed,
      filedBy: msg.sender,
      payoutAssetList: _exploitAssets,
      payoutNumerators: new uint256[](_exploitAssets.length),
      payoutDenominator: 1,
      filedTimestamp: uint48(block.timestamp),
      incidentTimestamp: _incidentTimestamp,
      decidedTimestamp: 0,
      feePaid: claimFee,
      description: _description
    }));
    feeCurrency.safeTransferFrom(msg.sender, address(this), claimFee);
    _updateCoverPoolClaimFee(_coverPool);
    uint256 index = coverPoolClaims[_coverPool][nonce].length - 1;
    emit ClaimUpdate({
      coverPool: _coverPool,
      state: ClaimState.Filed,
      nonce: nonce,
      index: index
    });
  }

  /**
   * @notice Force file a claim for a COVER-supported contract `_coverPool`
   * that bypasses validateClaim by paying the `forceClaimFee` fee
   * @dev `_incidentTimestamp` must be within the past 3 days. 
   * Only callable when isAuditorVoting is true
   * 
   * Emits ClaimUpdated
   */
  function forceFileClaim(
    address _coverPool,
    string calldata _coverPoolName,
    bytes32[] calldata _exploitAssets,
    uint48 _incidentTimestamp,
    string calldata _description
  ) external override onlyWhenAuditorVoting {
    require(_coverPool != address(0), "COVER_CM: coverPool cannot be 0");
    require(
      _coverPool == getAddressFromFactory(_coverPoolName), 
      "COVER_CM: invalid coverPool address"
    );  
    require(
      block.timestamp - _incidentTimestamp <= getFileClaimWindow(_coverPool),
      "COVER_CM: block.timestamp - incidentTimestamp > fileClaimWindow"
    );
    uint256 nonce = getCoverPoolNonce(_coverPool);
    coverPoolClaims[_coverPool][nonce].push(Claim({
      state: ClaimState.ForceFiled,
      filedBy: msg.sender,
      payoutAssetList: _exploitAssets,
      payoutNumerators: new uint256[](_exploitAssets.length),
      payoutDenominator: 1,
      filedTimestamp: uint48(block.timestamp),
      incidentTimestamp: _incidentTimestamp,
      decidedTimestamp: 0,
      feePaid: forceClaimFee,
      description: _description
    }));
    feeCurrency.safeTransferFrom(msg.sender, address(this), forceClaimFee);
    emit ClaimUpdate({
      coverPool: _coverPool,
      state: ClaimState.ForceFiled,
      nonce: nonce,
      index: coverPoolClaims[_coverPool][nonce].length - 1
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
  function validateClaim(
    address _coverPool,
    uint256 _nonce,
    uint256 _index,
    bool _claimIsValid
  ) external override onlyGov onlyWhenAuditorVoting {
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
    emit ClaimUpdate({
      coverPool: _coverPool,
      state: claim.state,
      nonce: _nonce,
      index: _index
    });
  }

  /**
   * @notice Decide whether claim for a coverPool should be accepted(will payout) or denied
   * @dev Only callable by approvedDecider
   *
   * Emits ClaimUpdated
   */
  function decideClaim(
    address _coverPool,
    uint256 _nonce,
    uint256 _index,
    bool _claimIsAccepted,
    bytes32[] calldata _exploitAssets,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator
  ) external override onlyApprovedDecider {
    require(_nonce == getCoverPoolNonce(_coverPool), "COVER_CM: input nonce != coverPool nonce");
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    _validateClaimState(claim);

    // Max decision claim window passed, claim is default to Denied
    if (_claimIsAccepted && !_isDecisionWindowPassed(claim)) {
      _validatePayoutNums(_exploitAssets, _payoutNumerators, _payoutDenominator);

      claim.state = ClaimState.Accepted;
      claim.payoutAssetList = _exploitAssets;
      claim.payoutNumerators = _payoutNumerators;
      claim.payoutDenominator = _payoutDenominator;
      feeCurrency.safeTransfer(claim.filedBy, claim.feePaid);
      _resetCoverPoolClaimFee(_coverPool);
      _enactClaim(_coverPool, _nonce, claim);
    } else {
      require(_getTotalNum(_payoutNumerators) == 0, "COVER_CM: claim denied (default if passed window), but payoutNumerator != 0");
      claim.state = ClaimState.Denied;
      feeCurrency.safeTransfer(treasury, claim.feePaid);
    }
    claim.decidedTimestamp = uint48(block.timestamp);
    emit ClaimUpdate(_coverPool, claim.state, _nonce, _index);
  }

  function _enactClaim(address _coverPool, uint256 _nonce, Claim memory claim) private {
    ICoverPool(_coverPool).enactClaim(claim.payoutAssetList, claim.payoutNumerators, claim.payoutDenominator, claim.incidentTimestamp, _nonce);
  }

  /// @notice Get all claims for coverPool `_coverPool` and nonce `_nonce` in state `_state`
  function getAllClaimsByState(address _coverPool, uint256 _nonce, ClaimState _state)
    external view override returns (Claim[] memory) 
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

  /// @notice Get all claims for coverPool `_coverPool` and nonce `_nonce`
  function getAllClaimsByNonce(address _coverPool, uint256 _nonce) 
    external 
    view 
    override 
    returns (Claim[] memory) 
  {
    return coverPoolClaims[_coverPool][_nonce];
  }

  /// @notice Get the coverPool address from the coverPool factory
  function getAddressFromFactory(string calldata _coverPoolName) public view override returns (address) {
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
    return block.timestamp - claim.filedTimestamp > maxClaimDecisionWindow - 1 hours;
  }

  function _validatePayoutNums(
    bytes32[] calldata _payoutAssetList,
    uint256[] calldata _payoutNumerators,
    uint256 _payoutDenominator
  ) private view {
    require(_payoutAssetList.length == _payoutNumerators.length, "CoverPool: payout assets len don't match");
    uint256 totalNum = _getTotalNum(_payoutNumerators);

    require(totalNum > 0, "CoverPool: claim accepted, but payoutNumerator == 0");
    if (allowPartialClaim) {
      require(totalNum <= _payoutDenominator, "CoverPool: payout % is not in (0%, 100%]");
    } else {
      require(totalNum == _payoutDenominator, "CoverPool: no partial payout % is not in 100%");
    }
  }

  function _getTotalNum(uint256[] calldata _payoutNumerators) private pure returns (uint256 _totalNum) {
    for (uint256 i = 0; i < _payoutNumerators.length; i++) {
      _totalNum = _totalNum + _payoutNumerators[i];
    }
  }

  function _validateClaimState(Claim memory claim) private view {
    if (isAuditorVoting()) {
      require(
        claim.state == ClaimState.Validated || 
        claim.state == ClaimState.ForceFiled, 
        "COVER_CM: claim not validated or forceFiled"
      );
    } else {
      require(claim.state == ClaimState.Filed, "COVER_CM: claim state not filed");
    }
  }
} 