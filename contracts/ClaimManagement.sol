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

  constructor(address _governance, address _treasury, address _coverPoolFactory, address _defaultCVC) {
    require(
      _governance != msg.sender && _governance != address(0), 
      "COVER_CC: governance cannot be owner or 0"
    );
    require(_treasury != address(0), "COVER_CM: treasury cannot be 0");
    require(_coverPoolFactory != address(0), "COVER_CM: coverPool factory cannot be 0");
    governance = _governance;
    treasury = _treasury;
    coverPoolFactory = _coverPoolFactory;
    defaultCVC = _defaultCVC;

    initializeOwner();
  }

  function getCoverPoolClaims(address _coverPool, uint256 _nonce, uint256 _index) external view override returns (Claim memory) {
    return coverPoolClaims[_coverPool][_nonce][_index];
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
  function getAllClaimsByNonce(address _coverPool, uint256 _nonce) external view override returns (Claim[] memory) {
    return coverPoolClaims[_coverPool][_nonce];
  }

  /**
   * @notice File a claim for a Cover Pool
   * @dev `_incidentTimestamp` must be within the past 3 days
   * 
   * Emits ClaimUpdated
   */ 
  function fileClaim(
    string calldata _coverPoolName,
    bytes32[] calldata _exploitAssets,
    uint48 _incidentTimestamp,
    string calldata _description
  ) external override {
    address coverPool = _getAddressFromFactory(_coverPoolName);
    require(coverPool != address(0), "COVER_CM: pool not found");
    require(block.timestamp - _incidentTimestamp <= getFileClaimWindow(coverPool), "COVER_CM: time passed window");

    uint256 nonce = _getCoverPoolNonce(coverPool);
    uint256 claimFee = getCoverPoolClaimFee(coverPool);
    coverPoolClaims[coverPool][nonce].push(Claim({
      state: ClaimState.Filed,
      filedBy: msg.sender,
      decidedBy: address(0),
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
    _updateCoverPoolClaimFee(coverPool);
    emit ClaimUpdate(coverPool, ClaimState.Filed, nonce, coverPoolClaims[coverPool][nonce].length - 1);
  }

  /**
   * @notice Force file a claim for a Cover Pool
   * @dev `_incidentTimestamp` must be within the past 3 days.    
   * 
   * Emits ClaimUpdated
   */
  function forceFileClaim(
    string calldata _coverPoolName,
    bytes32[] calldata _exploitAssets,
    uint48 _incidentTimestamp,
    string calldata _description
  ) external override {
    address coverPool = _getAddressFromFactory(_coverPoolName);
    require(coverPool != address(0), "COVER_CM: pool not found");
    require(block.timestamp - _incidentTimestamp <= getFileClaimWindow(coverPool), "COVER_CM: time passed window");

    uint256 nonce = _getCoverPoolNonce(coverPool);
    coverPoolClaims[coverPool][nonce].push(Claim({
      state: ClaimState.ForceFiled,
      filedBy: msg.sender,
      decidedBy: address(0),
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
    emit ClaimUpdate(coverPool, ClaimState.ForceFiled, nonce, coverPoolClaims[coverPool][nonce].length - 1);
  }

  /**
   * @notice Validates whether claim will be passed to approvedDecider to decideClaim
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _nonce uint256: nonce of the coverPool
   * @param _index uint256: index of the claim
   * @param _claimIsValid bool: true if claim is valid and passed to CVC, false otherwise
   *   
   * Emits ClaimValidated
   */
  function validateClaim(
    address _coverPool,
    uint256 _nonce,
    uint256 _index,
    bool _claimIsValid
  ) external override onlyGov {
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    require(_nonce == _getCoverPoolNonce(_coverPool), "COVER_CM: wrong nonce");
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
  ) external override {
    require(isCVCMember(_coverPool, msg.sender), "COVER_CM: !cvc");
    require(_nonce == _getCoverPoolNonce(_coverPool), "COVER_CM: wrong nonce");
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    require(
        claim.state == ClaimState.Validated || 
        claim.state == ClaimState.ForceFiled, 
        "COVER_CM: claim not validated or forceFiled"
      );

    // Max decision claim window passed, claim is default to Denied
    if (_claimIsAccepted && !_isDecisionWindowPassed(claim)) {
      _validatePayoutNums(_exploitAssets, _payoutNumerators, _payoutDenominator);

      claim.state = ClaimState.Accepted;
      claim.payoutAssetList = _exploitAssets;
      claim.payoutNumerators = _payoutNumerators;
      claim.payoutDenominator = _payoutDenominator;
      feeCurrency.safeTransfer(claim.filedBy, claim.feePaid);
      _resetCoverPoolClaimFee(_coverPool);
      // _enactClaim(_coverPool, _nonce, claim);
      ICoverPool(_coverPool).enactClaim(claim.payoutAssetList, claim.payoutNumerators, claim.payoutDenominator, claim.incidentTimestamp, _nonce);
    } else {
      require(_getTotalNum(_payoutNumerators) == 0, "COVER_CM: claim denied (default if passed window), but payoutNumerator != 0");
      claim.state = ClaimState.Denied;
      feeCurrency.safeTransfer(treasury, claim.feePaid);
    }
    claim.decidedBy = msg.sender;
    claim.decidedTimestamp = uint48(block.timestamp);
    emit ClaimUpdate(_coverPool, claim.state, _nonce, _index);
  }

  /// @notice Get the coverPool address from the coverPool factory
  function _getAddressFromFactory(string calldata _coverPoolName) private view returns (address) {
    return ICoverPoolFactory(coverPoolFactory).coverPools(_coverPoolName);
  }

  /**
   * @notice Get the current nonce for coverPool `_coverPool`
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @return the current nonce for coverPool `_coverPool`
   */
  function _getCoverPoolNonce(address _coverPool) private view returns (uint256) {
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
} 