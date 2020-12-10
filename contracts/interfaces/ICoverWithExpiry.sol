// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

import "./ICover.sol";
import "./ICoverERC20.sol";

/**
 * @title Cover contract interface. See {Cover}.
 * @author crypto-pumpkin@github
 */
interface ICoverWithExpiry is ICover {
  function expiry() external view returns (uint48);
}