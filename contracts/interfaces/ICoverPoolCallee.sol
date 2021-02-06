// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

/**
 * @dev ICoverPoolCallee interface for flash mint
 * @author crypto-pumpkin
 */
interface ICoverPoolCallee {
    function onFlashMint(address sender, uint amountIn, uint amountOut, bytes calldata data) external;
}