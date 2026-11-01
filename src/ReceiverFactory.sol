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

    // Эталонные шаблоны initcode (11.1 ТЗ): хеш шаблонного префикса и его
    // длина для каждого типа приёмника. Полный initcode = шаблон (префикс)
    // + аргументы конструктора (core, pool, asset, treasury, assetId, S,
    // di, E, X / owner, usdc, weth). create2 регистрирует приёмник ТОЛЬКО
    // если префикс initcode совпадает с эталоном — произвольный код
    // зарегистрировать нельзя (INV-20: минт только в обмен на реальный
    // supply). Задаётся владельцем фабрики однократно после сборки стека.
    bytes32 public receiverTemplateHash;
    uint256 public receiverTemplateLen;
    bytes32 public outputReceiverTemplateHash;
    uint256 public outputReceiverTemplateLen;
    address public owner;

    event ReceiverDeployed(address indexed receiver, bytes32 indexed salt, bool payout);
    event TemplateHashesSet(bytes32 receiverTemplateHash, bytes32 outputReceiverTemplateHash);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error DeploymentFailed();
    error InitcodeMismatch();
    error NotOwner();
    error HashesNotSet();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address core_) {
        core = ILaserGunCore(core_);
        owner = msg.sender;
    }

    /// @notice Однократная фиксация эталонных шаблонов (после сборки стека).
    /// @param receiverHash_ keccak256(шаблон Receiver)
    /// @param receiverLen_ длина шаблона Receiver в байтах
    /// @param outputHash_ keccak256(шаблон OutputReceiver)
    /// @param outputLen_ длина шаблона OutputReceiver в байтах
    function setTemplateHashes(
        bytes32 receiverHash_,
        uint256 receiverLen_,
        bytes32 outputHash_,
        uint256 outputLen_
    ) external onlyOwner {
        require(receiverTemplateHash == bytes32(0), "already set");
        require(receiverHash_ != bytes32(0) && outputHash_ != bytes32(0), "zero hash");
        require(receiverLen_ != 0 && outputLen_ != 0, "zero len");
        receiverTemplateHash = receiverHash_;
        receiverTemplateLen = receiverLen_;
        outputReceiverTemplateHash = outputHash_;
        outputReceiverTemplateLen = outputLen_;
        emit TemplateHashesSet(receiverHash_, outputHash_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
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
        bytes32 want = payout ? outputReceiverTemplateHash : receiverTemplateHash;
        if (want == bytes32(0)) revert HashesNotSet();
        uint256 tLen = payout ? outputReceiverTemplateLen : receiverTemplateLen;
        // INV-20: префикс initcode обязан быть эталонным шаблоном — произвольный
        // код зарегистрировать приёмником нельзя, необеспеченный минт невозможен
        if (initcode.length <= tLen || keccak256(initcode[:tLen]) != want) {
            revert InitcodeMismatch();
        }
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
