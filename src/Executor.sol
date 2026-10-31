// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ILaserGunCore} from "./interfaces/ILaserGunCore.sol";
import {IAavePool, IERC20Minimal, IWETH} from "./interfaces/IComposition.sol";

/// @title Executor
/// @notice Иммутабельный контракт вывода (10.2 ТЗ): единственный вызывающий
///          spend в ядре (NotExecutor у прочих — константная связка INV-22),
///          трата и выплата в одной транзе (атомарность: реверт выплаты
///          откатывает запись nullifier — INV-22), вывод комиссий feesOwner'ом
///          в пределах accrued − withdrawn (INV-23).
/// @dev Тяга aTokens казны — в сумме amount + 1 (aToken ребейсирует 1:1 к
///          underlying; буфер закрывает half-up-полосу validateWithdraw),
///          остаток возвращается казне той же транзой — баланс executor'а
///          после выплаты нулевой (10.2).
contract Executor {
    ILaserGunCore public immutable core;
    address public immutable pool;
    address public immutable aToken1; // aUSDC
    address public immutable aToken2; // aWETH
    address public immutable asset1; // USDC
    address public immutable asset2; // WETH
    address public immutable treasury;
    address public immutable feesOwner; // константа сборки, несменяем (6.7)

    mapping(bytes32 => bool) public feesWithdrawnMap; // обналичивания: nullifier → отметка
    mapping(uint256 => uint256) public feesWithdrawn; // снятый аккумулятор комиссий

    error NotFeeOwner();
    error InsufficientFees();
    error PullFailed();

    event FeesWithdrawn(uint256 indexed assetId, address indexed to, uint256 amount);

    constructor(
        address core_, address pool_,
        address aToken1_, address aToken2_,
        address asset1_, address asset2_,
        address treasury_, address feesOwner_
    ) {
        core = ILaserGunCore(core_);
        pool = pool_;
        aToken1 = aToken1_;
        aToken2 = aToken2_;
        asset1 = asset1_;
        asset2 = asset2_;
        treasury = treasury_;
        if (feesOwner_ == address(0)) revert NotFeeOwner();
        feesOwner = feesOwner_;
    }

    /// @notice Трата + выплата одной транзой. calldata — байт-в-байт core.spend.
    /// @dev Повтор завершённого обналичивания — no-op шага 1 (AT-25);
    ///      при стелс-доставке и получателе-ядре отметка выплат не пишется:
    ///      повтор доходит до гейта получателя ядра и завершается без перевода.
    function execute(bytes calldata spendCalldata) external {
        // core.spend принимает SpendArgs — calldata форвардится как есть
        if (!_coreSpend(spendCalldata)) {
            // ack-повтор (DuplicateSpend) или занятый nullifier с иным payload:
            // ядро уже вернуло ack/реверт; здесь — только чтение реестра
        }
        bytes32 nullifier = _nullifierOf(spendCalldata);
        if (feesWithdrawnMap[nullifier]) return; // no-op: обналичивание завершено (AT-25)
        if (!core.isSpent(nullifier)) return; // ack-ветка ядра без изменений

        (, address recipient, uint256 amount) = core.spentInfo(nullifier);
        if (recipient == address(core)) return; // сдача/конверт: казна (INV-19)
        if (recipient == address(0)) return; // стелс-доставка: минт payee (INV-19)

        feesWithdrawnMap[nullifier] = true; // отметка до перевода (только обналичивания)
        _withdraw(assetIdOf(spendCalldata), recipient, amount);
    }

    /// @notice Вывод накопленных комиссий (6.7, INV-23): только feesOwner,
    ///          в пределах feesAccrued − feesWithdrawn, отметка до перевода.
    function sweepFees(uint256 assetId, address to, uint256 amount) external {
        if (msg.sender != feesOwner) revert NotFeeOwner();
        uint256 withdrawn = feesWithdrawn[assetId];
        if (amount > core.feesAccrued(assetId) - withdrawn) revert InsufficientFees();
        feesWithdrawn[assetId] = withdrawn + amount; // двойной вывод исключён по построению
        _withdraw(assetId, to, amount);
        emit FeesWithdrawn(assetId, to, amount);
    }

    // ── защищённый путь выплаты (10.2) ──────────────────────────────

    function _withdraw(uint256 assetId, address to, uint256 amount) internal {
        address underlying = assetOf(assetId);
        // тяга aTokens: amount + 1 — буфер half-up-полосы validateWithdraw;
        // allowance казны ограничен лимитом (операционная ручка, 10.2)
        IERC20Minimal aToken = IERC20Minimal(aTokenOf(assetId));
        uint256 aTokenAmount = amount + 1;
        if (!aToken.transferFrom(treasury, address(this), aTokenAmount)) revert PullFailed();
        // immediate redeem: underlying — USDC/WETH; сжигает rayDiv(amount, index)
        IAavePool(pool).withdraw(underlying, amount, address(this));
        IERC20Minimal(underlying).transfer(to, amount);
        // возврат остатка тяги (0 или 1 единица) казне той же транзой:
        // баланс executor'а после выплаты нулевой (10.2)
        aToken.transfer(treasury, aToken.balanceOf(address(this)));
    }

    function aTokenOf(uint256 assetId) internal view returns (address) {
        if (assetId == 1) return aToken1;
        return aToken2; // assetId == 2 проверен ядром при трате
    }

    function assetOf(uint256 assetId) internal view returns (address) {
        if (assetId == 1) return asset1;
        return asset2;
    }

    // ── разбор calldata траты (SpendArgs ABI) ────────────────────────

    function _coreSpend(bytes calldata cd) internal returns (bool) {
        (bool ok, ) = address(core).call(cd);
        return ok;
    }

    /// @notice nullifier = keccak256(I) из calldata траты. Calldata —
    ///          селектор core.spend (4 байта) + слово-офсет (32) + кортеж
    ///          SpendArgs: начало кортежа — байт 36, офсеты — от него.
    uint256 internal constant TUPLE_AT = 36; // 4 selector + 32 offset word

    function _nullifierOf(bytes calldata cd) internal pure returns (bytes32) {
        // SpendArgs голова: [assetId][di][recipient][ring][hp][I][c1][s]...
        // I — 6-е поле: офсет на байте 36+160 = 196
        uint256 offI = uint256(bytes32(cd[196:228]));
        uint256 lenI = uint256(bytes32(cd[TUPLE_AT + offI:TUPLE_AT + offI + 32]));
        return keccak256(cd[TUPLE_AT + offI + 32:TUPLE_AT + offI + 32 + lenI]);
    }

    function assetIdOf(bytes calldata cd) internal pure returns (uint256) {
        return uint256(bytes32(cd[TUPLE_AT:TUPLE_AT + 32]));
    }
}
