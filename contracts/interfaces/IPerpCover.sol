// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICover.sol";
import "./ICoverERC20.sol";

/**
 * @title Perpetual Cover contract interface. See {PerpCover}.
 * @author crypto-pumpkin@github
 */
interface IPerpCover is ICover {
  function createdAt() external view returns (uint256);
  function rolloverPeriod() external view returns (uint256);
  function getCoverDetails()
    external view returns (
      string memory _name,
      uint256 _rolloverPeriod,
      uint256 _createdAt,
      address _collateral,
      uint256 _claimNonce,
      ICoverERC20[] memory _claimCovTokens,
      ICoverERC20 _noclaimCovToken
    );
}