// SPDX-License-Identifier: No License

pragma solidity ^0.7.5;

/**
 * @title Interface of the CovTokens Proxy.
 */
interface ICovTokenProxy {
  function initialize(string calldata _symbol) external;
}