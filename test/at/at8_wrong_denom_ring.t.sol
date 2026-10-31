// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-8 — UnknownCommitment.
/// Given: кольцо, где один член существует в другой паре «актив × номинал»
/// или отсутствует. When: spend. Then: UnknownCommitment.
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";

contract AT8_WrongDenomRing is ATBase {
    function test_member_of_other_pair() public {
        // кольцо di=27; один член — нота пары di=26
        bytes[] memory ring27 = _seedPair(1, DI, N16, "at8a");
        bytes[] memory ring26 = _seedPair(1, DI - 1, 1, "at8b");
        ring27[5] = ring26[0];

        address payout = _deployPayout(address(0xA8), "at8");
        uint256[] memory secs = new uint256[](N16);
        secs[0] = 1; // подпись не дойдёт до проверки: реестр — раньше арифметики
        Prep memory p = _prepFrom("at8", ring27, secs, 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 0);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.UnknownCommitment.selector);
        core.spend(p.args);
    }

    function test_member_absent() public {
        bytes[] memory ring = _seedPair(1, DI, N16, "at8c");
        ring[9] = _ptOf(_secretOf("at8ghost", 0)); // нет в реестре

        address payout = _deployPayout(address(0xB8), "at8c");
        uint256[] memory secs = new uint256[](N16);
        secs[0] = 1;
        Prep memory p = _prepFrom("at8c", ring, secs, 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 0);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.UnknownCommitment.selector);
        core.spend(p.args);
    }
}
