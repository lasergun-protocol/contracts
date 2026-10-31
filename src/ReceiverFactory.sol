// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ILaserGunCore} from "./interfaces/ILaserGunCore.sol";

/// @title ReceiverFactory
/// @notice Counterfactual-фабрика приёмников входа и вывода (8.2, 10.2 ТЗ):
///          деплой CREATE2 по соли и регистрация в ядре в транзе деплоя.
///          Полный initcode входит в CREATE2-binding (INV-21); salt
///          одноразовый — повтор по занятой соли невозможен (AT-17).
/// @dev Константная связка core↔factory: адрес ядра — иммутабель.
contract ReceiverFactory {
    ILaserGunCore public immutable core;

    event ReceiverDeployed(address indexed receiver, bytes32 indexed salt, bool payout);

    error DeploymentFailed();
    error InitcodeMismatch();

    constructor(address core_) {
        core = ILaserGunCore(core_);
    }

    /// @notice CREATE2-деплой приёмника и регистрация в ядре.
    /// @param salt одноразовая соль (входит в адрес вместе с полным initcode)
    /// @param initcode полный initcode: шаблон + аргументы конструктора
    /// @param payout true — приёмник вывода (registerPayoutReceiver)
    /// @return receiver адрес задеплоенного приёмника
    function create2(bytes32 salt, bytes calldata initcode, bool payout)
        external
        returns (address receiver)
    {
        // create2 читает память: calldata-срез копируется в память
        bytes memory code = initcode;
        assembly ("memory-safe") {
            receiver := create2(0, add(code, 32), mload(code), salt)
        }
        if (receiver == address(0)) revert DeploymentFailed();
        if (payout) {
            core.registerPayoutReceiver(receiver);
        } else {
            core.registerReceiver(receiver);
        }
        emit ReceiverDeployed(receiver, salt, payout);
    }

    /// @notice Предсказанный CREATE2-адрес (формула EIP-1014).
    function predictAddress(bytes32 salt, bytes calldata initcode)
        external view returns (address)
    {
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initcode))
        );
        return address(uint160(uint256(h)));
    }
}
