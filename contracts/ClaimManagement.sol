// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ERC20/SafeERC20.sol";
import "./ClaimConfig.sol";
import "./interfaces/ICoverPool.sol";
import "./interfaces/ICoverPoolFactory.sol";
import "./interfaces/IClaimManagement.sol";

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
      "ClaimManagement: governance cannot be owner or 0"
    );
    require(_treasury != address(0), "ClaimManagement: treasury cannot be 0");
    require(_coverPoolFactory != address(0), "ClaimManagement: coverPool factory cannot be 0");
    require(_defaultCVC != address(0), "ClaimManagement: defaultCVC cannot be 0");
    governance = _governance;
    treasury = _treasury;
    coverPoolFactory = _coverPoolFactory;
    defaultCVC = _defaultCVC;

    initializeOwner();
  }

  /// @notice File a claim for a Cover Pool, `_incidentTimestamp` must be within allowed time window
  function fileClaim(
    string calldata _coverPoolName,
    bytes32[] calldata _exploitRisks,
    uint48 _incidentTimestamp,
    string calldata _description,
    bool isForceFile
  ) external override {
    address coverPool = _getCoverPoolAddr(_coverPoolName);
    require(coverPool != address(0), "ClaimManagement: pool not found");
    require(block.timestamp - _incidentTimestamp <= getFileClaimWindow(coverPool), "ClaimManagement: time passed window");

    ICoverPool(coverPool).setNoclaimRedeemDelay(10 days);
    uint256 nonce = _getCoverPoolNonce(coverPool);
    uint256 claimFee = isForceFile ? forceClaimFee : getCoverPoolClaimFee(coverPool);
    feeCurrency.safeTransferFrom(msg.sender, address(this), claimFee);
    _updateCoverPoolClaimFee(coverPool);
    ClaimState state = isForceFile ? ClaimState.ForceFiled : ClaimState.Filed;
    coverPoolClaims[coverPool][nonce].push(Claim({
      filedBy: msg.sender,
      decidedBy: address(0),
      filedTimestamp: uint48(block.timestamp),
      incidentTimestamp: _incidentTimestamp,
      decidedTimestamp: 0,
      description: _description,
      state: state,
      feePaid: claimFee,
      payoutRiskList: _exploitRisks,
      payoutRates: new uint256[](_exploitRisks.length)
    }));
    emit ClaimUpdate(coverPool, state, nonce, coverPoolClaims[coverPool][nonce].length - 1);
  }

  /**
   * @notice Validates whether claim will be passed to approvedDecider to decideClaim
   * @param _coverPool address: contract address of the coverPool that COVER supports
   * @param _nonce uint256: nonce of the coverPool
   * @param _index uint256: index of the claim
   * @param _claimIsValid bool: true if claim is valid and passed to CVC, false otherwise
   * Emits ClaimUpdate
   */
  function validateClaim(
    address _coverPool,
    uint256 _nonce,
    uint256 _index,
    bool _claimIsValid
  ) external override onlyGov {
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    require(_nonce == _getCoverPoolNonce(_coverPool), "ClaimManagement: wrong nonce");
    require(claim.state == ClaimState.Filed, "ClaimManagement: claim not filed");
    if (_claimIsValid) {
      claim.state = ClaimState.Validated;
      _resetCoverPoolClaimFee(_coverPool);
    } else {
      claim.state = ClaimState.Invalidated;
      claim.decidedTimestamp = uint48(block.timestamp);
      feeCurrency.safeTransfer(treasury, claim.feePaid);
      _resetNoclaimRedeemDelay(_coverPool, _nonce);
    }
    emit ClaimUpdate({
      coverPool: _coverPool,
      state: claim.state,
      nonce: _nonce,
      index: _index
    });
  }

  /// @notice Decide whether claim for a coverPool should be accepted(will payout) or denied,  Only callable by approvedDecider
  function decideClaim(
    address _coverPool,
    uint256 _nonce,
    uint256 _index,
    bool _claimIsAccepted,
    bytes32[] calldata _exploitRisks,
    uint256[] calldata _payoutRates
  ) external override {
    require(_exploitRisks.length == _payoutRates.length, "CoverPool: payout risks len don't match");
    require(isCVCMember(_coverPool, msg.sender), "ClaimManagement: !cvc");
    require(_nonce == _getCoverPoolNonce(_coverPool), "ClaimManagement: wrong nonce");
    Claim storage claim = coverPoolClaims[_coverPool][_nonce][_index];
    require(
        claim.state == ClaimState.Validated || 
        claim.state == ClaimState.ForceFiled, 
        "ClaimManagement: claim not validated or forceFiled"
      );

    // Max decision claim window passed, claim is default to Denied
    uint256 totalRates = _getTotalNum(_payoutRates);
    if (_claimIsAccepted && !_isDecisionWindowPassed(claim)) {
      require(totalRates > 0 && totalRates <= 1 ether, "CoverPool: payout % is not in (0%, 100%]");

      claim.state = ClaimState.Accepted;
      claim.payoutRiskList = _exploitRisks;
      claim.payoutRates = _payoutRates;
      feeCurrency.safeTransfer(claim.filedBy, claim.feePaid);
      _resetCoverPoolClaimFee(_coverPool);
      ICoverPool(_coverPool).enactClaim(claim.payoutRiskList, claim.payoutRates, claim.incidentTimestamp, _nonce);
    } else {
      require(totalRates == 0, "ClaimManagement: claim denied (default if passed window), but payoutNumerator != 0");
      claim.state = ClaimState.Denied;
      feeCurrency.safeTransfer(treasury, claim.feePaid);
    }
    _resetNoclaimRedeemDelay(_coverPool, _nonce);
    claim.decidedBy = msg.sender;
    claim.decidedTimestamp = uint48(block.timestamp);
    emit ClaimUpdate(_coverPool, claim.state, _nonce, _index);
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

  /// @notice Get whether a pending claim for coverPool `_coverPool` and nonce `_nonce` exists
  function hasPendingClaim(address _coverPool, uint256 _nonce) public view override returns (bool) {
    Claim[] memory allClaims = coverPoolClaims[_coverPool][_nonce];
    for (uint i = 0; i < allClaims.length; i++) {
      ClaimState state = allClaims[i].state;
      if (state == ClaimState.Filed || state == ClaimState.ForceFiled || state == ClaimState.Validated) {
        return true;
      }
    }
    return false;
  }

  function _resetNoclaimRedeemDelay(address _coverPool, uint256 _nonce) private {
    if (!hasPendingClaim(_coverPool, _nonce)) {
      (uint256 defaultRedeemDelay, ) = ICoverPool(_coverPool).getRedeemDelays();
      ICoverPool(_coverPool).setNoclaimRedeemDelay(defaultRedeemDelay);
    }
  }

  function _getCoverPoolAddr(string calldata _coverPoolName) private view returns (address) {
    return ICoverPoolFactory(coverPoolFactory).coverPools(_coverPoolName);
  }

  function _getCoverPoolNonce(address _coverPool) private view returns (uint256) {
    return ICoverPool(_coverPool).claimNonce();
  }

  // The times passed since the claim was filed has to be less than the max claim decision window
  function _isDecisionWindowPassed(Claim memory claim) private view returns (bool) {
    return block.timestamp - claim.filedTimestamp > maxClaimDecisionWindow - 1 hours;
  }

  function _getTotalNum(uint256[] calldata _payoutRates) private pure returns (uint256 _totalRates) {
    for (uint256 i = 0; i < _payoutRates.length; i++) {
      _totalRates = _totalRates + _payoutRates[i];
    }
  }
} 