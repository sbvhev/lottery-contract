// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICover.sol";
import "./ICoverERC20.sol";

/**
 * @title Cover with expiry contract interface. See {CoverWithExpiry}.
 * @author crypto-pumpkin
 */
interface ICoverWithExpiry is ICover {
  function expiry() external view returns (uint48);
  function getCoverDetails()
    external view returns (
      string memory _name,
      uint48 _expiry,
      address _collateral,
      uint256 _claimNonce,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken
    );
}