// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ILaserGunCore} from "./interfaces/ILaserGunCore.sol";
import {IAavePool, IERC20Minimal, IWETH} from "./interfaces/IComposition.sol";

/// @title Receiver
/// @notice Одноразовый counterfactual-приёмник входа (8.2 ТЗ): pull EIP-3009
///          (USDC) или value-взнос (ETH через WETH-шлюз), supply
///          (onBehalfOf=казна), вызов минта ядра ровно на S − feeIn(S).
/// @dev Параметры минта (assetId, treasury, S, di, E, X) — immutables,
///          зашитые конструктором при деплое; в calldata pull/settle не ходят
///          (8.3, INV-21). Актив ни на секунду не задерживается на публичном
///          адресе: токен-переводы и Pool — единственные внешние вызовы.
contract Receiver {
    ILaserGunCore public immutable core;
    address public immutable pool;
    address public immutable asset; // USDC или WETH
    address public immutable treasury;
    uint256 public immutable assetId; // 1 = USDC, 2 = ETH
    uint256 public immutable depositAmount; // полная сумма вклада S
    uint256[] internal denomIndicesArr; // разложение di минта — только конструктор
    bytes[] internal ephemeralsArr; // эфемерные точки E
    bytes[] internal commitmentsArr; // коммитменты X

    bool public settled;

    error AlreadySettled();
    error AmountMismatch();
    error PullFailed();
    error MintFailed();
    error UnwrapFailed();

    constructor(
        address core_, address pool_, address asset_, address treasury_,
        uint256 assetId_, uint256 depositAmount_,
        uint256[] memory denomIndices_, bytes[] memory ephemerals_, bytes[] memory commitments_
    ) {
        core = ILaserGunCore(core_);
        pool = pool_;
        asset = asset_;
        treasury = treasury_;
        assetId = assetId_;
        depositAmount = depositAmount_;
        for (uint256 j = 0; j < denomIndices_.length; ++j) denomIndicesArr.push(denomIndices_[j]);
        for (uint256 j = 0; j < ephemerals_.length; ++j) ephemeralsArr.push(ephemerals_[j]);
        for (uint256 j = 0; j < commitments_.length; ++j) commitmentsArr.push(commitments_[j]);
    }

    function denomIndices(uint256 j) external view returns (uint256) { return denomIndicesArr[j]; }
    function denomIndicesLength() external view returns (uint256) { return denomIndicesArr.length; }
    function ephemerals(uint256 j) external view returns (bytes memory) { return ephemeralsArr[j]; }
    function ephemeralsLength() external view returns (uint256) { return ephemeralsArr.length; }
    function commitments(uint256 j) external view returns (bytes memory) { return commitmentsArr[j]; }
    function commitmentsLength() external view returns (uint256) { return commitmentsArr.length; }

    /// @notice USDC-ветка: receiveWithAuthorization → supply → mintNotes.
    ///          Привязка from/value к соли — через полный initcode (AT-17):
    ///          приёмник задеплоен под конкретные параметры, mismatch — реверт.
    function pull(
        address from, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 sigS
    ) external {
        if (settled) revert AlreadySettled();
        if (value != depositAmount) revert AmountMismatch();
        settled = true;
        IERC20Minimal(asset).receiveWithAuthorization(
            from, address(this), value, validAfter, validBefore, nonce, v, r, sigS
        );
        _supplyAndMint();
    }

    /// @notice ETH-ветка: взнос уже на балансе приёмника (value на
    ///          предсказанный адрес до деплоя, 8.2): wrap → supply → mint.
    function settle() external {
        if (settled) revert AlreadySettled();
        settled = true;
        if (address(this).balance < depositAmount) revert AmountMismatch();
        IWETH(address(asset)).deposit{value: depositAmount}();
        _supplyAndMint();
    }

    receive() external payable {} // value-взнос на предсказанный адрес (8.2)

    /// @notice supply(asset, S, onBehalfOf=казна) и минт ровно S − feeIn(S).
    function _supplyAndMint() internal {
        IERC20Minimal(asset).approve(address(pool), depositAmount);
        IAavePool(pool).supply(asset, depositAmount, treasury, 0);
        // минт: deposited — полная сумма; ядро вычтет feeIn и проверит консервацию
        (bool ok, ) = address(core).call(
            abi.encodeCall(
                ILaserGunCore.mintNotes,
                (assetId, depositAmount, denomIndicesArr, ephemeralsArr, commitmentsArr)
            )
        );
        if (!ok) revert MintFailed();
    }
}
