// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;
pragma abicoder v2;

import "./utils/Ownable.sol";
import "./utils/SafeMath.sol";
import "./interfaces/ICover.sol";
import "./interfaces/ICoverERC20.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/ICoverPool.sol";

/**
 * @title Cover contract
 * @author crypto-pumpkin
 */
abstract contract Cover is ICover, Ownable {
  using SafeMath for uint256;

  bytes4 private constant COVERERC20_INIT_SIGNITURE = bytes4(keccak256("initialize(string)"));
  bool public override isDeployed;
  address public override collateral;
  ICoverERC20 public override noclaimCovToken;
  string public override name;
  uint256 public override claimNonce;

  ICoverERC20[] public override claimCovTokens;
  mapping(bytes32 => ICoverERC20) public claimCovTokenMap;

  function viewClaimable(address _account) external view override returns (uint256 eligibleAmount) {
    ICoverPool.ClaimDetails memory claim = _claimDetails();
    for (uint256 i = 0; i < claim.payoutAssetList.length; i++) {
      ICoverERC20 covToken = claimCovTokenMap[claim.payoutAssetList[i]];
      uint256 amount = covToken.balanceOf(_account);
      eligibleAmount = eligibleAmount.add(amount.mul(claim.payoutNumerators[i]).div(claim.payoutDenominator));
    }
    if (claim.payoutTotalNum < claim.payoutDenominator) {
      uint256 amount = noclaimCovToken.balanceOf(_account);
      uint256 payoutAmount = amount.mul(claim.payoutDenominator.sub(claim.payoutTotalNum)).div(claim.payoutDenominator);
      eligibleAmount = eligibleAmount.add(payoutAmount);
    }
  }

  /// @notice make sure no claim is accepted
  function _noClaimAcceptedCheck() internal view {
    require(ICoverPool(owner()).claimNonce() == claimNonce, "Cover: claim accepted");
  }

  // get the claim details for the corresponding nonce from coverPool contract
  function _claimDetails() internal view returns (ICoverPool.ClaimDetails memory) {
    return ICoverPool(owner()).getClaimDetails(claimNonce);
  }

  /// @notice the owner of this contract is CoverPool contract, the owner of CoverPool is CoverPoolFactory contract
  function _factory() internal view returns (address) {
    return IOwnable(owner()).owner();
  }
}