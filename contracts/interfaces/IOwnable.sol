// SPDX-License-Identifier: MIT

pragma solidity ^0.7.5;

/**
 * @title Interface of Ownable
 */
interface IOwnable {
    function owner() external view returns (address);
}
