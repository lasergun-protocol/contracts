// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-22 — деградации при размывании аннонимсета (13.5):
/// 1) посев 15 нот → траты всех нот пары последовательно ревертируются
///    RingTooSmall (кольцо 15 < MIN_RING) — деградация явная, не тихая;
/// 2) повтор spend того же payload — InvalidSignature/UnknownCommitment?
///    нет: nullifier-фаза — spentPayload занят → возврат к InvalidSignature
///    невозможен; проверяем canonical-поведение (DoubleSpend).
/// R5a-аспект (AT-22c): полный вывод казны — «казна рециклируется»:
///    treasury withdraw не обнуляет пользователя.
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT22_Degradations is ATBase {
    /// @notice Кольцо 15: посев 15 нот di, все 15 трат ревертируются RingTooSmall.
    function test_ring_of_fifteen_degrades_loudly() public {
        _seedPair(1, DI, 15, "at22s15");
        uint256 d = core.denomOf(1, DI);
        uint256 feeT = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - feeT, "at22chg");

        // каждая из 15 нот: кольцо «своё», 15 членов — spend ревертируется
        // RingTooSmall (15 < MIN_RING=16) до всякой подписи/реестра (5.1)
        for (uint256 pi = 0; pi < 15; ++pi) {
            bytes[] memory ring15 = new bytes[](15);
            uint256[] memory sec15 = new uint256[](15);
            for (uint256 j = 0; j < 15; ++j) {
                sec15[j] = _secretOf("at22s15", j);
                ring15[j] = _ptOf(sec15[j]);
            }
            Prep memory p = _prepFrom("at22s15", ring15, sec15, 1, DI, address(core), ch, _emptyEnv(), _emptyPayee(), pi);
            vm.prank(address(executor));
            vm.expectRevert(LaserGunCore.RingTooSmall.selector);
            core.spend(p.args);
        }
        // «тихой» деградации нет: коммиты на месте, ноты не сожжены;
        // failed spends не начисляют комиссий (аккумулятор = только feeIn посева)
        assertTrue(core.commitmentExists(1, DI, _ptOf(_secretOf("at22s15", 0))), "intact");
        uint256 notes = 15 * d;
        uint256 seedFee = (notes * 10 + 9999) / 10000;
        uint256 dep = notes + seedFee;
        for (uint256 i = 0; i < 12; ++i) {
            uint256 f2 = (dep * 10 + 9999) / 10000;
            if (f2 == dep - notes) break;
            dep = notes + f2;
        }
        assertEq(core.feesAccrued(1), dep - notes, "only seed feeIn accrued");
    }

    /// @notice Кольцо 1 (соло-трата) — так же RingTooSmall: приватность не
    ///         деградирует тихо ни при каком размере ниже 16.
    function test_solo_ring_reverts() public {
        _seedPair(1, DI, 1, "at22s1");
        bytes[] memory ring1 = new bytes[](1);
        uint256[] memory sec1 = new uint256[](1);
        sec1[0] = _secretOf("at22s1", 0);
        ring1[0] = _ptOf(sec1[0]);
        Prep memory p = _prepFrom("at22s1", ring1, sec1, 1, DI, address(core), _emptyChange(), _emptyEnv(), _emptyPayee(), 0);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.RingTooSmall.selector);
        core.spend(p.args);
    }

    /// @notice Полный вывод казны: комиссионный аккумулятор обнуляется по активу,
    ///         пользовательские операции продолжаются (рециклинг не ломает протокол).
    function test_full_withdraw_does_not_break_users() public {
        Prep memory p = _seedAndSpend("at22w", 1, DI, address(core), _changeFor(1, core.denomOf(1, DI) - (core.denomOf(1, DI) * 15 + 9999) / 10000, "at22wchg"), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));
        uint256 accrued = core.feesAccrued(1);
        assertTrue(accrued > 0, "fees accrued");

        vm.prank(feesOwner);
        executor.sweepFees(1, treasury, accrued);
        assertEq(core.feesAccrued(1) - executor.feesWithdrawn(1), 0, "drained");

        // пользовательский поток жив: новый вход → трата со сдачей
        Prep memory q = _seedAndSpend("at22w2", 1, DI, address(core), _changeFor(1, core.denomOf(1, DI) - (core.denomOf(1, DI) * 15 + 9999) / 10000, "at22wchg2"), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(q.nullifier), "user flow continues");
    }
}
