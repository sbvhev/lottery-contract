// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

/**
 * @title Interface of the CovTokens Proxy.
 */
interface ICovTokenProxy {
  function initialize(string calldata _symbol) external;
}