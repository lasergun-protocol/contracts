// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-4 — InvalidSignature на чужом кольце.
/// Given: кольцо из N коммитментов атакующего, не знающего секретов чужих нот.
/// When: попытка тратить несуществующую ноту с синтезированной подписью.
/// Then: InvalidSignature; эффектов нет.
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {SolLSAG} from "../lib/SolLSAG.sol";
import {Points} from "../../src/lib/Points.sol";

contract AT4_ForgeRing is ATBase {
    function test_forge_ring() public {
        // посев чужих нот (не атакующего)
        bytes[] memory ring = _seedPair(1, DI, N16, "at4");

        // атакующий синтезирует подпись с ЛЮБОЙ позиции: даже собственный
        // секрет не соответствует ни одному члену кольца — M связан с кольцом
        uint256 foreignKey = _secretOf("at4attacker", 0);
        (uint256 x0, uint256 y0) = Points.mulG(foreignKey);
        bytes[] memory ringWithOwn = new bytes[](N16);
        for (uint256 j = 0; j < N16; ++j) ringWithOwn[j] = ring[j];
        ringWithOwn[0] = abi.encodePacked(x0, y0); // чужой не в реестре → UnknownCommitment
        // а) точка атакующего в кольце — UnknownCommitment (гейт пройдёт:
        //    payout-приёмник регистрируется заранее)
        bytes[] memory hp2 = SolLSAG.hpForAll(ringWithOwn);
        ILaserGunCore.SpendArgs memory a2;
        a2.assetId = 1;
        a2.di = DI;
        a2.recipient = _deployPayout(address(0xA), "at4");
        a2.ring = ringWithOwn;
        a2.hp = hp2;
        (bytes32 c12, uint256[] memory s2, bytes memory I2) = _signArgs(a2, 0, foreignKey);
        a2.I = I2;
        a2.c1 = c12;
        a2.s = s2;
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.UnknownCommitment.selector);
        core.spend(a2);

        // б) валидное кольцо реестра, подделанный challenge — InvalidSignature
        address payoutB = _deployPayout(address(0xB), "at4b");
        Prep memory p = _seedAndPrep("at4b", 1, DI, payoutB, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        // подменяем c1 произвольно — проверка сойдётся в ложное значение
        p.args.c1 = bytes32(uint256(p.args.c1) ^ 1);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidSignature.selector);
        core.spend(p.args);

        // в) эффектов нет: трат не появилось
        assertFalse(core.isSpent(p.nullifier), "no effects");
    }
}
