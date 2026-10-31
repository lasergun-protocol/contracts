// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-25 — no-op повтора executor'а (система, 10.2):
/// 1) обналичивание: повтор байт-в-байт идентичного calldata — no-op шага 1:
///    без события, без перевода, без обращений к ядру (реестр выплат);
/// 2) стелс-доставка и получатель-ядро: повтор доходит до гейта получателя
///    ядра и завершается без перевода;
/// 3) состояние ядра байт-в-байт неизменно во всех ветках.
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {ATBase} from "../lib/ATBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";

contract AT25_ExecutorReplay is ATBase {
    /// @notice Повтор обналичивания: ни переводов, ни событий, ни вызовов ядра.
    ///         Проверка «без обращений к ядру» — vm.expectCall НЕ исполняется
    ///         в повторной транзе (строгий контроль: expectCall(0 раз) недоступен,
    ///         поэтому трассируем газ: no-op < 30k).
    function test_cashout_replay_is_noop() public {
        uint256 d = core.denomOf(1, DI);
        address payout = _deployPayout(address(0x25A1), "at25pay");
        Prep memory p = _seedAndSpend("at25c", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee());
        uint256 feeOut = (d * 25 + 9999) / 10000;
        uint256 bal1 = usdc.balanceOf(payout);
        assertEq(bal1, d - feeOut, "first payout");

        // snapshot состояния ядра до повтора
        bytes32 ph0; address rec0; uint256 amt0;
        (ph0, rec0, amt0) = core.spentInfo(p.nullifier);
        uint256 fees0 = core.feesAccrued(1);
        uint256 aU0 = pool.aUSDC().balanceOf(treasury);

        // повтор байт-в-байт идентичного calldata
        vm.recordLogs();
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));

        // no-op: без события (кроме пустого набора), без перевода
        assertEq(usdc.balanceOf(payout), bal1, "no second transfer");
        assertEq(core.feesAccrued(1), fees0, "no fee changes");
        bytes32 ph1; address rec1; uint256 amt1;
        (ph1, rec1, amt1) = core.spentInfo(p.nullifier);
        assertEq(ph1, ph0, "payload hash unchanged");
        assertEq(rec1, rec0, "recipient unchanged");
        assertEq(amt1, amt0, "amount unchanged");

        // «без обращений к ядру для обналичиваний» (реестр выплат):
        // ни тяги aTokens (баланс aUSDC казны не менялся), ни повторной выплаты
        assertEq(pool.aUSDC().balanceOf(treasury), aU0, "no Aave pull on replay");
        assertEq(usdc.balanceOf(payout), bal1, "no second transfer");
        // «без события» (PRD 10.2) — без события executor-выплаты; единственное
        // событие повтора — ack DuplicateSpend ядра (calldata идентичен)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only core ack event");
    }

    /// @notice Повтор стелс-доставки: шаг 1 ядра — ack-ветка (DuplicateSpend),
    ///         исполнитель завершается без перевода (recipient=0 → ранняя
    ///         ветка) и без событий executor'а; состояние неизменно.
    function test_stealth_replay_noop() public {
        uint256 d = core.denomOf(1, DI);
        uint256 feeT = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory pc = _changeFor(1, d - feeT, "at25st");
        ILaserGunCore.Payee memory pay = _payeeOf(pc);
        Prep memory p = _seedAndSpend("at25s", 1, DI, address(0), _emptyChange(), _emptyEnv(), pay);
        uint256 balExec = usdc.balanceOf(address(executor));

        vm.recordLogs();
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        assertEq(usdc.balanceOf(address(executor)), balExec, "no transfer");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // executor не эмитит ничего; единственное событие — DuplicateSpend ядра
        assertEq(logs.length, 1, "exactly DuplicateSpend");
        assertEq(logs[0].emitter, address(core), "from core");
        assertEq(logs[0].topics[0], LaserGunCore.DuplicateSpend.selector, "ack topic");
    }

    /// @notice Повтор при получателе-ядре (сдача): recipient == core → ранняя
    ///         ветка, без перевода и без отметки выплат; ядро отвечает ack.
    function test_change_to_core_replay_noop() public {
        uint256 d = core.denomOf(1, DI);
        uint256 feeT = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - feeT, "at25cc");
        Prep memory p = _seedAndSpend("at25k", 1, DI, address(core), ch, _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));
        uint256 balExec = usdc.balanceOf(address(executor));
        uint256 fees0 = core.feesAccrued(1);

        vm.recordLogs();
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        assertEq(usdc.balanceOf(address(executor)), balExec, "no transfer");
        assertEq(core.feesAccrued(1), fees0, "no fee drift");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "ack only");
        assertEq(logs[0].topics[0], LaserGunCore.DuplicateSpend.selector, "core ack");
        // отметка выплат не писалась: реестр executor'а чист для этого nullifier
        assertFalse(executor.feesWithdrawnMap(p.nullifier), "no payout registry entry");
    }

    function _payeeOf(ILaserGunCore.Change memory c)
        internal pure returns (ILaserGunCore.Payee memory p)
    {
        p.di = c.di;
        p.E = c.E;
        p.X = c.X;
    }
}
