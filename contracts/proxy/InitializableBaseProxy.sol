// SPDX-License-Identifier: MIT

pragma solidity ^0.7.3;

import "../utils/Address.sol";
import "./Proxy.sol";

/**
 * @dev This contract implements an Initializable proxy. It is upgradeable because calls are delegated to an
 * implementation address that can be changed. This address is stored in storage in the location specified by
 * https://eips.ethereum.org/EIPS/eip-1967[EIP1967], so that it doesn't conflict with the storage layout of the
 * implementation behind the proxy.
 * @author crypto-pumpkin
 * 
 * Upgradeability is only provided internally through {_upgradeTo}. For an externally upgradeable proxy see
 * {TransparentUpgradeableProxy}.
 */
contract InitializableBaseProxy is Proxy {

    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event Upgraded(address indexed implementation);

    /**
    * Contract initializer.
    * @param _logic address of the initial implementation.
    * @param _data Data to send as msg.data to the implementation to initialize the proxied contract.
    * It should include the signature and the parameters of the function to be called, as xdescribed in
    * https://solidity.readthedocs.io/en/v0.4.24/abi-spec.html#function-selector-and-argument-encoding.
    * This parameter is optional, if no data is given the initialization call to proxied contract will be skipped.
    */
    function initialize(address _logic, bytes memory _data) public payable {
        require(_implementation() == address(0));

        assert(IMPLEMENTATION_SLOT == bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1));
        _setImplementation(_logic);
        if(_data.length > 0) {
            (bool success,) = _logic.delegatecall(_data);
            require(success);
        }
    }

    function implementation() external view returns (address impl) {
        impl = _implementation();
    }

    /**
     * @dev Returns the current implementation address.
     */
    function _implementation() internal override view returns (address impl) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            impl := sload(slot)
        }
    }

    /**
     * @dev Stores a new address in the EIP1967 implementation slot.
     */
    function _setImplementation(address newImplementation) internal {
        require(Address.isContract(newImplementation), "UpgradeableProxy: new implementation is not a contract");

        bytes32 slot = IMPLEMENTATION_SLOT;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, newImplementation)
        }
    }
}