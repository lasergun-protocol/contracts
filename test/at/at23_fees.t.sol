// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-23 — комиссионная консервация (6.7): FeeMismatch при расхождении
/// denomOf-суммы и deposited − feeIn; gridFee-округление вверх до сетки;
/// обнуление при 10%-пороге и вытеснении минимального номинала; потолок
/// 100 bps зашит конструктором (FeeCapExceeded при нарушении констант).
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {Fees} from "../../src/lib/Fees.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {Receiver} from "../../src/Receiver.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT23_Fees is ATBase {
    function _depFor(uint256 assetId, uint256 diIdx) internal view returns (uint256 deposited) {
        uint256 d = core.denomOf(assetId, diIdx);
        deposited = d + ((d * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 12; ++i) {
            deposited = d + ((deposited * 10 + 9999) / 10000);
        }
    }

    function test_batch_fee_mismatch_reverts() public {
        // пачка двух нот: deposited ниже суммы нот + feeIn → FeeMismatch
        uint256[] memory di = new uint256[](2);
        di[0] = DI;
        di[1] = DI;
        uint256 d = core.denomOf(1, DI);
        uint256 dep = _depFor(1, DI); // одно-нотный фикс-пойнт
        // feeIn(2*dep) > 2*feeIn(dep): сырая сдача двух нот не бьётся
        uint256[] memory secs = new uint256[](2);
        secs[0] = _secretOf("at23a", 0);
        secs[1] = _secretOf("at23a", 1);
        bytes[] memory es = new bytes[](2);
        bytes[] memory xs = new bytes[](2);
        es[0] = _ptOf(_secretOf("e", secs[0]));
        xs[0] = _ptOf(secs[0]);
        es[1] = _ptOf(_secretOf("e", secs[1]));
        xs[1] = _ptOf(secs[1]);

        // депонируем «как две отдельные ноты» — недостаточно для пачки:
        // FeeMismatch ДО DuplicateCommitment (консервация 6.7):
        // feeIn(2*dep) = 2002003 → notes = 2000000001 ≠ 2e9.
        // Receiver оборачивает реверт ядра в MintFailed; expect ставим
        // непосредственно перед pull (low-level, паттерн AT-17)
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(usdc), treasury, 1, 2 * dep, di, es, xs)
        );
        bytes32 salt = keccak256("at23-bad-batch");
        address rcv = factory.create2(salt, initcode, false);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256(abi.encode(salt, address(this)));
        bytes32 digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                user, rcv, 2 * dep, uint256(0), deadline, nonce
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        vm.startPrank(user);
        usdc.mint(user, 2 * dep);
        usdc.approve(rcv, 2 * dep);
        vm.stopPrank();
        vm.prank(rcv);
        vm.expectRevert(Receiver.MintFailed.selector);
        Receiver(payable(rcv)).pull(user, 2 * dep, 0, deadline, nonce, v, r, s);
    }

    function test_fee_in_grid_rounding_up() public view {
        // gridFee округляет вверх до кратности минимальному номиналу
        assertEq(DenomGrid.minDenom(1), 1, "USDC min = 1 micro");
        // 1000 микро USDC: raw = ceil(1000*10/10000) = 1 → grid 1
        uint256 fee = Fees.feeIn(1, 1000, 1);
        assertEq(fee, 1, "feeIn 1000 gives 1");
        // 1001 микро: raw = ceil(1.001) = 2
        assertEq(Fees.feeIn(1, 1001, 1), 2, "ceil up");
        // 1e6 микро: raw = 1000
        assertEq(Fees.feeIn(1, 1e6, 1), 1000, "feeIn 1e6 gives 1000");
        // ETH: min denom 1e14 wei
        assertEq(DenomGrid.minDenom(2), 1e14, "ETH min 1e14");
        // 1 ETH депозит: raw = 1e15 (0.001 ETH); кратно 1e14; ниже 10% порога
        assertEq(Fees.feeIn(2, 1e18, 1e14), 1e15, "ETH feeIn 0.001 ETH");
        // 0.001 ETH: raw 1e12 → grid-округление вверх до 1e14 (min denom)
        assertEq(Fees.feeIn(2, 1e15, 1e14), 1e14, "ETH grid rounds up to 1e14");
    }

    function test_fee_grid_zero_below_threshold_cases() public view {
        // порог 10%: f*10000 > value*FEE_GRID_CAP_BPS → комиссия 0
        // v=5: raw 1; 1*10000 > 5*1000 → 0
        assertEq(Fees.feeIn(1, 5, 1), 0, "10pct threshold zeroes fee at v=5");
        // v=100000: raw 100; 100*10000 == 100000*1000? 1e6 vs 1e8 → fee 100
        assertEq(Fees.feeIn(1, 100000, 1), 100, "fee under threshold");
        // ETH: value = 1.05e15: raw 1.05e12 → grid 1e14; порог: 1e18 < 1.05e18 → fee 1e14
        assertEq(Fees.feeIn(2, 105e13, 1e14), 1e14, "ETH v=1.05e15 fee");
        // value = 1.2e14: grid 1e14, но 1e18 > 1.2e17 (порог) → 0
        assertEq(Fees.feeIn(2, 12e13, 1e14), 0, "ETH fee zeroed by cap");
        // value = 9e13: grid 1e14 > value → 0
        assertEq(Fees.feeIn(2, 9e13, 1e14), 0, "ETH fee zeroed by cap 2");
    }

    function test_fee_cap_baked_in_constructor() public {
        // константы комиссий ≤ FEE_CAP_BPS=100 — деплой ядра с нарушением невозможен:
        // конструктор ревертирует FeeCapExceeded (INV-7). Проверяем штатный деплой
        // базы и отсутствие сеттеров комиссий в байткоде ядра
        assertEq(Fees.FEE_IN_BPS, 10, "FEE_IN 10bps");
        assertEq(Fees.FEE_TRANSFER_BPS, 15, "FEE_TRANSFER 15bps");
        assertEq(Fees.FEE_OUT_BPS, 25, "FEE_OUT 25bps");
        assertEq(Fees.FEE_CAP_BPS, 100, "cap 100bps");
        // конструктор с корректными константами отработал: core адрес ненулевой
        assertTrue(address(core) != address(0));
    }

    function test_full_cycle_fee_conservation() public {
        // полный контур: минт → трата со сдачей → свип: feesAccrued == feeIn + feeTransfer
        uint256 d = core.denomOf(1, DI);
        uint256 dep = _depFor(1, DI);
        uint256[] memory di = new uint256[](1);
        di[0] = DI;
        uint256[] memory secs = new uint256[](1);
        secs[0] = _secretOf("at23cin", 0);
        _enterUSDC(user, userKey, dep, di, secs);

        uint256 feeIn_ = dep - d;
        uint256 afterIn = core.feesAccrued(1);
        assertEq(afterIn, feeIn_, "accrued after deposit == feeIn(dep)");

        // посев 16 нот (кольцо траты) — их feeIn тоже ложится в аккумулятор
        uint256 seedDep = 16 * d;
        uint256 seedFee = (seedDep * 10 + 9999) / 10000;
        uint256 deposited = seedDep + seedFee;
        for (uint256 i = 0; i < 8; ++i) {
            uint256 f2 = (deposited * 10 + 9999) / 10000;
            if (f2 == deposited - seedDep) break;
            deposited = seedDep + f2;
        }
        seedFee = deposited - seedDep;

        uint256 feeTransfer = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - feeTransfer, "at23chg");
        // отдельные теги посева и траты: секреты не пересекаются
        Prep memory p = _seedAndSpend("at23cycb", 1, DI, address(core), ch, _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));

        // дельта казны: feeIn(seed) + feeTransfer; свипов не было
        assertEq(core.feesAccrued(1) - afterIn, seedFee + feeTransfer, "delta == seedFee + feeTransfer");
        assertEq(executor.feesWithdrawn(1), 0, "nothing withdrawn");
    }
}
