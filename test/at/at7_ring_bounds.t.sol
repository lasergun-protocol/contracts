// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-7 — RingTooSmall / RingTooLarge (INV-12: анти-футган).
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {SolLSAG} from "../lib/SolLSAG.sol";

contract AT7_RingBounds is ATBase {
    function test_ring_too_small() public {
        // кольцо N=8: 8 членов из реестра (посев), подпись корректна —
        // но MIN_RING=16, отвергается независимо от валидности
        _seedPair(1, DI, N16, "at7a");
        bytes[] memory ring8 = new bytes[](8);
        uint256[] memory secrets8 = new uint256[](8);
        for (uint256 j = 0; j < 8; ++j) {
            secrets8[j] = _secretOf("at7a", j);
            ring8[j] = _ptOf(secrets8[j]);
        }
        address payout = _deployPayout(address(0xA7), "at7a");
        Prep memory p = _prepFrom("at7a", ring8, secrets8, 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 3);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.RingTooSmall.selector);
        core.spend(p.args);
    }

    function test_ring_too_large() public {
        _seedPair(1, DI, N16, "at7b");
        uint256 N65 = 65;
        bytes[] memory ring65 = new bytes[](N65);
        uint256[] memory secrets65 = new uint256[](N65);
        for (uint256 j = 0; j < N65; ++j) {
            secrets65[j] = _secretOf("at7b", j % N16); // члены из посева
            ring65[j] = _ptOf(_secretOf("at7b", j % N16));
        }
        address payout = _deployPayout(address(0xB7), "at7b");
        // подпись не нужна: размер проверяется до арифметики — соберём args вручную
        ILaserGunCore.SpendArgs memory a;
        a.assetId = 1;
        a.di = DI;
        a.recipient = payout;
        a.ring = ring65;
        a.hp = new bytes[](N65);
        a.s = new uint256[](N65);
        a.I = _ptOf(1);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.RingTooLarge.selector);
        core.spend(a);
    }
}
