// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-13 — ack повтора / NullifierSpent (уровень ядра, реестр 13.3).
///
/// Обе ветки повтора ядра — defense-in-depth: штатный executor гасит
/// проигравшую подачу раньше ядра (PRD 10.2), поэтому ветки вызываются
/// напрямую core.spend от имени executor'а.
/// INV-15: идентичный payload → событие DuplicateSpend, состояние не меняется;
/// занятый nullifier с иным payload → revert NullifierSpent.
/// Дополнительно: прямая подача мимо executor'а — NotExecutor (INV-22).
import {Test} from "forge-std/Test.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {IERC20Minimal} from "../../src/interfaces/IComposition.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT13_DuplicateAck is ATBase {
    function test_duplicate_payload_ack_noop() public {
        Prep memory p = _seedAndSpend("at13", 1, DI, _deployPayout(address(0xD1), "at13p"), _emptyChange(), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier), "first spend passed");

        // фиксируем состояние до повтора
        uint256 feesBefore = core.feesAccrued(1);
        (bytes32 payloadBefore,, ) = core.spentInfo(p.nullifier);
        uint256 aBalBefore = IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(treasury);

        // ожидаем событие DuplicateSpend(nullifier, payloadHash)
        vm.expectEmit(true, true, true, true, address(core));
        emit LaserGunCore.DuplicateSpend(p.nullifier, keccak256(abi.encode(p.args)));
        vm.prank(address(executor));
        core.spend(p.args); // байт-в-байт тот же payload — ack

        // состояние ядра и казны не изменилось (no-op)
(bytes32 payloadAfter,, ) = core.spentInfo(p.nullifier);
        assertEq(payloadAfter, payloadBefore, "payload unchanged");
        assertEq(core.feesAccrued(1), feesBefore, "no fees on ack");
        assertEq(IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(treasury), aBalBefore, "no transfer on ack");
    }

    function test_same_nullifier_other_payload_reverts() public {
        Prep memory p = _seedAndSpend("at13x", 1, DI, _deployPayout(address(0xD2), "at13xp"), _emptyChange(), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));

        // тот же key image (тот же X в кольце) → тот же nullifier, но иная
        // подпись/кольцо → иной payload-хэш → NullifierSpent (INV-4)
        bytes[] memory ring2 = new bytes[](N16);
        uint256[] memory secrets2 = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) {
            secrets2[j] = _secretOf("at13y", j);
            ring2[j] = _ptOf(secrets2[j]);
        }
        uint256 pi2 = 5;
        ring2[pi2] = p.ring[p.pi]; // потраченная нота в позиции подписанта
        secrets2[pi2] = p.secret;
        Prep memory p2 = _prepFrom("at13y", ring2, secrets2, 1, DI, address(core), _emptyChange(), _emptyEnv(), _emptyPayee(), pi2);
        assertEq(p2.nullifier, p.nullifier, "same key image -> same nullifier");
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.NullifierSpent.selector);
        core.spend(p2.args);
    }

    function test_direct_call_not_executor() public {
        Prep memory p = _seedAndPrep("at13z", 1, DI, _deployPayout(address(0xD3), "at13zp"), _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        vm.expectRevert(LaserGunCore.NotExecutor.selector);
        core.spend(p.args); // подача мимо executor'а отклонена целиком (INV-22)
        assertFalse(core.isSpent(p.nullifier), "state untouched");
    }
}
