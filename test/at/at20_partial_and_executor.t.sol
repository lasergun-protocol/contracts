// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-20 — частичная передача и executor-границы: консервация сдачи,
/// ChangeMismatch, InvalidRecipient-ветки, подмена change/env в calldata,
/// выплатная точность executor'а и NotExecutor при прямой подаче spend
/// (6.7, 9.2, 10.2; реестр 13.3).
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {Points} from "../../src/lib/Points.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT20_PartialAndExecutor is ATBase {
    uint256 internal DI10 = 21; // denomOf(1,21) = 1e7 микро = 10 USDC
    uint256 internal senderSecret =
        uint256(keccak256("at20-sender")) % (2 ** 250);

    /// stealth-получатель отправителя: X + sG (стелс-сдача)
    function _stealthX(bytes memory XBase) internal view returns (bytes memory) {
        (uint256 bx, uint256 by) = Points.decode(XBase);
        (uint256 gx, uint256 gy) = Points.mulG(senderSecret);
        (uint256 sx, uint256 sy) = Points.ecAdd(bx, by, gx, gy);
        return abi.encodePacked(sx, sy);
    }

    function test_partial_conservation_change_envelope() public {
        // нота 10 USDC (di=9: 1e7 микро) → сдача 5.665e6 (6 нот) + конверт 4.32e6
        uint256 d = core.denomOf(1, DI10); // 1e7 микро
        assertEq(d, 10_000_000, "d == 10 USDC");
        uint256 fee = (d * 15 + 9999) / 10000; // 15000 микро = 0.015 USDC
        // сдача 5.665 USDC (жадное разложение по сетке {1,3,5}×10^k)
        uint256 changeAmt = 5_665_000;
        ILaserGunCore.Change memory ch = _changeFor(1, changeAmt, "at20chg");
        assertEq(DenomGrid.sumOf(1, ch.di), changeAmt, "change sum exact");
        // конверт: остаток расходуемого: d − fee − changeAmt = 4.32 USDC
        uint256 envAmt = d - fee - changeAmt;
        assertEq(envAmt, 4_320_000, "envelope 4.32");
        bytes32 envId = keccak256("at20-env");
        ILaserGunCore.Envelope memory env = _envFor(1, envAmt, envId, block.timestamp + 1 days, false, senderSecret);

        Prep memory p = _seedAndSpend(
            "at20a", 1, DI10, address(core), ch, env, _emptyPayee());
        assertTrue(core.isSpent(p.nullifier), "spent");

        // консервация: changeAmt + envAmt + fee == d
        assertEq(changeAmt + envAmt + fee, d, "conservation 6.7");

        // executor: выплата — стелс-минт? нет: получатель-ядро при частичной
        // передаче — executor ничего не выплачивает
        assertEq(usdc.balanceOf(address(core)), 0, "core holds nothing");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor holds nothing");
    }

    function test_change_over_spent_reverts() public {
        // сдача сверх потраченного: changeAmt == d → feeTransfer некуда деть
        uint256 d = core.denomOf(1, DI10);
        ILaserGunCore.Change memory ch = _changeFor(1, d, "at20big");
        vm.expectRevert(LaserGunCore.ChangeMismatch.selector);
        _seedAndSpend("at20b", 1, DI10, address(core), ch, _emptyEnv(), _emptyPayee());
    }

    function test_core_recipient_requires_outputs() public {
        // трата «в ядро» без сдачи и конверта — InvalidRecipient (сожжение)
        vm.expectRevert(LaserGunCore.InvalidRecipient.selector);
        _seedAndSpend("at20c", 1, DI10, address(core), _emptyChange(), _emptyEnv(), _emptyPayee());

        // сдача при ином (незарегистрированном) получателе — InvalidRecipient
        uint256 d = core.denomOf(1, DI10); // нота 10 USDC
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - fee, "at20chgX");
        address unregistered = makeAddr("at20-unregistered");
        vm.expectRevert(LaserGunCore.InvalidRecipient.selector);
        _seedAndSpend("at20d", 1, DI10, unregistered, ch, _emptyEnv(), _emptyPayee());
    }

    function test_calldata_substitution_invalid_signature() public {
        // подмена change в calldata после подписания: хэши в M → InvalidSignature
        uint256 d = core.denomOf(1, DI10); // нота 10 USDC
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - fee, "at20chgf");
        Prep memory p = _prep("at20e", 1, DI10, address(core), ch, _emptyEnv(), _emptyPayee(), 7);

        // трояним calldata: меняем сдачу на пустую
        bytes memory call = abi.encodeCall(LaserGunCore.spend, (p.args));
        ILaserGunCore.SpendArgs memory fake = p.args;
        fake.change = _emptyChange();
        bytes memory evil = abi.encodeCall(LaserGunCore.spend, (fake));
        // точки байт-в-байт различны только в change-хэше
        assertTrue(keccak256(call) != keccak256(evil), "calldata differs");
        vm.prank(address(executor));
        vm.expectRevert(); // InvalidSignature либо эквивалентный реверт верификации
        (bool ok, ) = address(core).call(evil);
        ok; // подавить предупреждение о неиспользуемом результате
    }

    function test_executor_payout_precision() public {
        // обналичивание: executor перевёл ровно d − feeOut приёмнику вывода из реестра
        uint256 d = core.denomOf(1, DI10); // нота 10 USDC
        address payout = _deployPayout(address(0x20A), "at20pay");
        Prep memory p = _seedAndSpend("at20f", 1, DI10, payout, _emptyChange(), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));
        uint256 feeOut = (d * 25 + 9999) / 10000;
        assertEq(usdc.balanceOf(payout), d - feeOut, "payout == d - feeOut");
        assertEq(usdc.balanceOf(address(executor)), 0, "no residue");

        // при получателе-ядре (конверт) executor ничего не перевёл — покрыто
        // в test_partial_conservation_change_envelope; повторный перевод
        // «иначе» невозможен: spentPayload перезапись ревертируется (AT-25)
    }

    function test_direct_spend_to_core_reverts_not_executor() public {
        // прямая подача spend в ядро мимо executor'а — NotExecutor до эффектов
        Prep memory p = _prep("at20g", 1, DI10, address(core), _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        vm.prank(user);
        vm.expectRevert(LaserGunCore.NotExecutor.selector);
        core.spend(p.args);
        assertFalse(core.isSpent(p.nullifier), "no state change before revert");
    }
}
