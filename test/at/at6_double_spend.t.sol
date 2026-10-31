// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-6 — NullifierSpent.
/// Given: успешно потраченная нота. When: вторая трата той же ноты
/// (то же I, новое кольцо). Then: NullifierSpent; реестры не изменились.
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {SolLSAG} from "../lib/SolLSAG.sol";

contract AT6_DoubleSpend is ATBase {
    function test_double_spend_nullifier_spent() public {
        Prep memory p = _seedAndSpend("at6", 1, DI, _deployPayout(address(0xB6), "at6p"), _emptyChange(), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));

        // вторая трата той же ноты: новое кольцо (тот же X в позиции pi —
        // I зависит только от X) и иная подпись
        bytes[] memory ring2 = new bytes[](N16);
        uint256[] memory secrets2 = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) {
            secrets2[j] = _secretOf("at6b", j);
            ring2[j] = _ptOf(secrets2[j]);
        }
        ring2[3] = p.ring[p.pi]; // та же потраченная нота — тот же key image
        secrets2[3] = p.secret;
        Prep memory p2 = _prepFrom("at6b", ring2, secrets2, 1, DI, address(0xCAFE), _emptyChange(), _emptyEnv(), _emptyPayee(), 3);
        assertEq(p2.nullifier, p.nullifier, "same key image -> same nullifier");
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.NullifierSpent.selector);
        core.spend(p2.args);
    }
}
