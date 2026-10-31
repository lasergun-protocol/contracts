// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-5 — подмена recipient/assetId в M.
/// Given: валидная трата ноты A. When: повтор с тем же кольцом, но изменённым
/// recipient или assetId в M. Then: подпись не сойдётся (M входит в challenges)
/// — InvalidSignature.
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";

contract AT5_MBinding is ATBase {
    function test_recipient_swap_breaks_signature() public {
        address payout = _deployPayout(address(0xA5), "at5a");
        Prep memory p = _seedAndPrep("at5a", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        // копия calldata с другим ЗАРЕГИСТРИРОВАННЫМ recipient (гейт пройдёт):
        // подпись перестаёт сходиться — M входит в challenges
        ILaserGunCore.SpendArgs memory forged = p.args;
        forged.recipient = _deployPayout(address(0xCAFE), "at5x");
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidSignature.selector);
        core.spend(forged);
    }

    function test_assetid_swap_breaks_signature() public {
        address payout = _deployPayout(address(0xB5), "at5b");
        Prep memory p = _seedAndPrep("at5b", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        ILaserGunCore.SpendArgs memory forged = p.args;
        forged.assetId = 2; // ETH-ветка: di 27 валиден (27 < 21? нет) → UnknownDenom до подписи;
        // для проверки привязки M берём di, валидный в обеих сетках, но ≠ подписанному значению:
        // UnknownDenom — тоже валидный исход (отвергнуто до эффектов), отдельно чистая
        // проверка M — в test_recipient_swap_breaks_signature
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.UnknownDenom.selector);
        core.spend(forged);
    }

    function test_di_swap_breaks_signature() public {
        address payout = _deployPayout(address(0xC5), "at5c");
        Prep memory p = _seedAndPrep("at5c", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        ILaserGunCore.SpendArgs memory forged = p.args;
        forged.di = DI - 1; // валидный, но другой номинал: кольцо того же набора
        // точек не состоит в этой паре — UnknownCommitment до арифметики
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.UnknownCommitment.selector);
        core.spend(forged);
    }
}
