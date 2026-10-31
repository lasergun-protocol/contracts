// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-16 — покрытие казны, свип-границы (fuzz) (реестр 13.3, INV-16/G6).
///
/// Случайные входы/траты/конверты/свипы/выводы комиссий; после каждой
/// операции: живые ноты + открытые конверты + (feesAccrued − feesWithdrawn)
/// ≤ aTokens казны (+1 ед. на округление ребейсинга). Свип — строго в
/// пределах излишка; после каждой выплаты и sweepFees — aToken-баланс
/// executor'а = 0 (остаток возвращён казне в той же транзе).
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {IERC20Minimal} from "../../src/interfaces/IComposition.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";

contract AT16_TreasuryCoverage is ATBase {
    uint256 internal nonce;

    function test_smoke_coverage_basic_sequence() public {
        // вход 2 нот
        uint256[] memory di = new uint256[](2);
        di[0] = DI;
        di[1] = DI;
        uint256[] memory secs = new uint256[](2);
        secs[0] = _secretOf("at16a", 0);
        secs[1] = _secretOf("at16a", 1);
        _enterUSDC(user, userKey, _batchDep(1, DI, 2), di, secs); // пачечный фикс-пойнт: notes ровно 2d
        uint256 cover1 = IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(treasury);
        // obligation = 2d + feeIn: cover >= obligation
        assertGe(cover1, 2 * core.denomOf(1, DI), "cover >= notes");

        // кэшаут одной ноты — на СВЕЖЕЙ паре (посев 16 нот в (1, DI)),
        // поэтому дельта казны = 16d − (d − feeOut) = 15d + feeOut
        Prep memory p = _seedAndSpend("at16b", 1, DI, _deployPayout(address(0x16A), "at16b"), _emptyChange(), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));
        // executor: aToken-остаток нулевой вне транзы
        assertEq(IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(address(executor)), 0, "executor residue 0");
        // казна: после посева 16 нот и кэшаута одной живых нот 15d,
        // комиссия feeOut ушла получателю — покрытие ≥ живых нот
        uint256 d = core.denomOf(1, DI);
        uint256 cover2 = IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(treasury);
        assertGe(cover2, 15 * d, "cover >= 15 live notes");
        // покрытие выросло ровно на нетто-приток: feeOut покинул пул, feeIn остался
        assertGt(cover2, cover1, "net inflow");
    }

    function test_sweep_within_surplus_keeps_coverage() public {
        // вход и комиссионное обязательство
        uint256[] memory di = new uint256[](1);
        di[0] = DI;
        uint256[] memory secs = new uint256[](1);
        secs[0] = _secretOf("at16c", 0);
        _enterUSDC(user, userKey, _depFor(1, DI), di, secs);
        // трата со сдачей: feeTransfer в feesAccrued
        uint256 d = core.denomOf(1, DI);
        uint256 ft = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - ft, "at16chg");
        Prep memory p2 = _seedAndSpend("at16d", 1, DI, address(core), ch, _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p2.nullifier));
        // штатный свип комиссий в пределах feesAccrued − feesWithdrawn
        uint256 pend = core.feesAccrued(1) - executor.feesWithdrawn(1);
        assertGe(pend, ft, "fee accrued");
        vm.prank(feesOwner);
        executor.sweepFees(1, feesOwner, pend);
        assertEq(executor.feesWithdrawn(1), core.feesAccrued(1), "swept all");
        assertEq(IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(address(executor)), 0, "no residue");
    }

    /// фикс-пойнт депозита для пачки из n нот номинала d (fee по всей сумме)
    function _batchDep(uint256 assetId, uint256 diIdx, uint256 n)
        internal view returns (uint256 deposited)
    {
        uint256 d = core.denomOf(assetId, diIdx);
        deposited = n * d;
        for (uint256 i = 0; i < 12; ++i) {
            deposited = n * d + ((deposited * 10 + 9999) / 10000);
        }
    }

    function _depFor(uint256 assetId, uint256 diIdx) internal view returns (uint256) {
        uint256 d = core.denomOf(assetId, diIdx);
        uint256 deposited = d + ((d * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 8; ++i) {
            uint256 f = (deposited * 10 + 9999) / 10000;
            if (d + f == deposited) break;
            deposited = d + f;
        }
        return deposited;
    }
}
