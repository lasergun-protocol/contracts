// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ILaserGunCore} from "./ILaserGunCore.sol";

/// @dev Формальные интерфейсы компоновки (11.1, 11.2 ТЗ); сигнатуры целевые.
interface ILaserGunReceiverFactory {
    /// CREATE2-деплой приёмника (входа или вывода) и регистрация его
    /// в ядре в транзе деплоя (8.2, 10.2, INV-21); полный initcode
    /// входит в CREATE2-binding; salt одноразовый (8.2, AT-17)
    function create2(bytes32 salt, bytes calldata initcode)
        external returns (address receiver);
    function predictAddress(bytes32 salt, bytes calldata initcode)
        external view returns (address);
}

interface ILaserGunReceiver {
    /// одноразовый приёмник входа (8.2): pull при первом вызове после
    /// деплоя — не в конструкторе; далее supply(asset, S, onBehalfOf=казна)
    /// и core.mintNotes — ровно S − feeIn(S) (6.7, INV-20); параметры
    /// минта (assetId, S, di, E, X) — immutables приёмника
    function pull(
        address from, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;
    function settle() external; // ETH-ветка: wrap → supply → mintNotes
    receive() external payable;
}

interface ILaserGunExecutor {
    /// единственный вызывающий spend: трата и выплата одной транзой (INV-22)
    function execute(bytes calldata spendCalldata) external;
    /// только feesOwner (NotFeeOwner); в пределах feesAccrued − feesWithdrawn
    function sweepFees(uint256 assetId, address to, uint256 amount) external;
    function feesWithdrawn(uint256 assetId) external view returns (uint256);
}

interface ILaserGunOutputReceiver {
    /// приёмник вывода: единственная операция — вывод сменному адресату (AT-24)
    function sweep(uint256 assetId, address to) external;
}

/// @dev Aave v3 Pool — внешний протокол бэкдинга (раздел 7 ТЗ)
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);

    /// EIP-3009 (USDC): receiveWithAuthorization — перевод по подписи
    /// с проверкой caller == to
    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;

    /// EIP-2612 permit (не требуется ядром; резерв приёмника ETH-ветки нет)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
