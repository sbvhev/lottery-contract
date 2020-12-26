// SPDX-License-Identifier: No License

pragma solidity ^0.8.0;

import "./ERC20/ERC20Permit.sol";
import "./utils/Initializable.sol";
import "./utils/Ownable.sol";
import "./interfaces/ICoverERC20.sol";

/**
 * @title CoverERC20 implements {ERC20} standards with expended features for COVER
 * @author crypto-pumpkin
 *
 * COVER's covToken Features:
 *  - Has mint and burn by owner (Cover contract) only feature.
 *  - No limit on the totalSupply.
 *  - Should only be created from Cover contract. See {Cover}
 */
contract CoverERC20 is ICoverERC20, ERC20Permit, Ownable {

  /// @notice Initialize, called once
  function initialize (string calldata _symbol, uint8 _decimals) external initializer {
    initializeOwner();
    initializeERC20(_symbol, _decimals);
    initializeERC20Permit(_symbol);
  }

  /// @notice COVER specific function
  function mint(address _account, uint256 _amount) external override onlyOwner returns (bool) {
    _mint(_account, _amount);
    return true;
  }

  /// @notice COVER specific function
  function burnByCover(address _account, uint256 _amount) external override onlyOwner returns (bool) {
    _burn(_account, _amount);
    return true;
  }

  /// @notice COVER specific function
  function setSymbol(string calldata _symbol) external override onlyOwner returns (bool) {
    symbol = _symbol;
    return true;
  }

  /// @notice COVER specific function
  function burn(uint256 _amount) external override returns (bool) {
    _burn(msg.sender, _amount);
    return true;
  }
}
