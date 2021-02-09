// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../ERC20/IERC20.sol";
import "../interfaces/ICoverPool.sol";
import "../interfaces/ICoverPoolCallee.sol";

/// Dummy contract to test FlashMint func for addCover in CoverPool
contract FlashCover is ICoverPoolCallee {

  function onFlashMint(
    address _sender,
    address _paymentToken,
    uint256 _paymentAmount,
    uint256 _amountOut,
    bytes calldata _data
  ) external override returns (bytes32) {
    require(_sender != address(0), "sender is 0");
    require(_data.length >= 0, "data < 0");
    require(_amountOut >= 0, "_amountOut < 0");
    IERC20(_paymentToken).approve(msg.sender, _paymentAmount);
    return keccak256("ICoverPoolCallee.onFlashMint");
  }

  function addCover(
    ICoverPool _pool,
    address _collateral,
    uint48 _expiry,
    address _receiver,
    uint256 _colAmountIn,
    uint256 _amountOut,
    bytes calldata _data
  ) external {
    _pool.addCover(_collateral, _expiry, _receiver, _colAmountIn, _amountOut, _data);
  }
}