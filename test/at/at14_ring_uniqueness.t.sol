// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-14 — DuplicateRingMember (реестр 13.3, INV-14).
///
/// Given: calldata с кольцом, содержащим один и тот же коммитмент дважды.
/// When: spend. Then: DuplicateRingMember до любых изменений состояния.
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {SolLSAG} from "../lib/SolLSAG.sol";

contract AT14_RingUniqueness is ATBase {
    function test_duplicate_ring_member() public {
        // живое кольцо: 16 уникальных нот посева
        _seedPair(1, DI, N16, "at14");
        address payout = _deployPayout(address(0xE1), "at14");

        // кольцо 16 членов, но member[7] == member[12] (одна точка дважды)
        bytes[] memory ring = new bytes[](N16);
        uint256[] memory secrets = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) {
            secrets[j] = _secretOf("at14", j);
            ring[j] = _ptOf(secrets[j]);
        }
        ring[12] = ring[7];
        secrets[12] = secrets[7];

        Prep memory p = _prepFrom("at14", ring, secrets, 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        uint256 feesBefore = core.feesAccrued(1); // включает feeIn посева
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.DuplicateRingMember.selector);
        core.spend(p.args);

        // состояние не задето: nullifier не записан, комиссия траты не начислена
        assertFalse(core.isSpent(p.nullifier), "state untouched");
        assertEq(core.feesAccrued(1), feesBefore, "no spend fee");
    }

    function test_duplicate_member_with_valid_sig_otherwise() public {
        // усиление: подпись корректна для дегенеративного кольца —
        // реверт всё равно до арифметики/эффектов (порядок гейтов)
        _seedPair(1, DI, N16, "at14b");
        address payout = _deployPayout(address(0xE2), "at14b");

        bytes[] memory ring = new bytes[](N16);
        uint256[] memory secrets = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) {
            secrets[j] = _secretOf("at14b", j);
            ring[j] = _ptOf(secrets[j]);
        }
        ring[15] = ring[0];
        secrets[15] = secrets[0];

        Prep memory p = _prepFrom("at14b", ring, secrets, 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 0);
        // SolLSAG-подписант строит подпись честно — ядро отвергает кольцо раньше
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.DuplicateRingMember.selector);
        core.spend(p.args);
        assertFalse(core.isSpent(p.nullifier), "state untouched");
    }
}
