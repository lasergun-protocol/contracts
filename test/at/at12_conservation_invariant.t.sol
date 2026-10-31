// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ATBase} from "../lib/ATBase.sol";
import {console2} from "forge-std/console2.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {IERC20Minimal} from "../../src/interfaces/IComposition.sol";
import {Fees} from "../../src/lib/Fees.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {EnvelopeState} from "../../src/interfaces/ILaserGunCore.sol";

/// AT-12 — инвариант-режим: случайные последовательности входов, трат
/// (со сдачей, стелс-доставкой и обналичиванием), конвертов, claim/refund,
/// свипов казны и выводов комиссий; после каждой операции проверяются
/// INV-16 (покрытие), INV-17 (эскроу-консервация), INV-23 (комиссии).
contract AT12_Conservation is ATBase {
    // ── учёт живой нотной массы по активам (аналог клиентского rebuild) ──
    mapping(uint256 => uint256) internal liveNotes;  // Σ номиналов живых нот
    mapping(uint256 => uint256) internal openEscrow; // Σ эскроу открытых конвертов
    mapping(bytes32 => uint256) internal envSum;     // INV-17: Σ di открытого конверта
    mapping(bytes32 => bool) internal envKnown;

    uint256 internal nonce;

    function setUp() public override {
        super.setUp();
        // стартовая подушка: 20 нот di=27 и 6 нот di=34 (ETH не задействован)
        for (uint256 i = 0; i < 20; ++i) {
            _seedAndAccount(1, DI, string(abi.encodePacked("at12s", i)));
        }
    }

    /// Посев ноты с зачислением в живой учёт.
    function _seedAndAccount(uint256 assetId, uint256 di, string memory tag) internal {
        bytes[] memory ring = _seedPair(assetId, di, 4, tag);
        require(ring.length == 4);
        liveNotes[assetId] += DenomGrid.denomOf(assetId, di);
    }

    // ═══════════════ инварианты ═══════════════

    function _checkInv16(uint256 assetId) internal view {
        // Σ живых нот + Σ открытых конвертов + (feesAccrued − feesWithdrawn)
        // ≤ aTokens казны того же актива + допуск 1 микро (half-up ребейсинг)
        address aT = pool.aTokenOf(assetId == 1 ? address(usdc) : address(weth));
        uint256 cover = IERC20Minimal(aT).balanceOf(treasury);
        uint256 obligation = liveNotes[assetId] + openEscrow[assetId]
            + (core.feesAccrued(assetId) - executor.feesWithdrawn(assetId));
        assertLe(obligation, cover + 1, "INV-16 coverage");
    }

    function _checkInv23() internal view {
        for (uint256 assetId = 1; assetId <= 2; ++assetId) {
            assertLe(executor.feesWithdrawn(assetId), core.feesAccrued(assetId), "INV-23");
        }
    }

    function _checkInv17() internal view {
        for (uint256 i = 0; i < nonce; ++i) {
            bytes32 id = bytes32(keccak256(abi.encodePacked("at12env", i)));
            if (!envKnown[id]) continue;
            EnvelopeState memory e = core.envelope(id);
            assertEq(_sumDi(e.di), envSum[id], "INV-17 escrow sum");
        }
    }

    function _sumDi(uint256[] memory di) internal pure returns (uint256 s) {
        for (uint256 j = 0; j < di.length; ++j) s += DenomGrid.denomOf(1, di[j]);
    }

    // ═══════════════ операции ═══════════════

    function _opSpendChange() internal {
        string memory tag = string(abi.encodePacked("at12chg", nonce++));
        uint256 d = DenomGrid.denomOf(1, DI);
// change-секреты отличны от кольцевых (иначе DuplicateCommitment):
        ILaserGunCore.Change memory ch = _changeFor(1, d - _feeTransfer(d), string(abi.encodePacked(tag, "-c")));
        Prep memory p = _seedAndPrep(tag, 1, DI, address(core), ch, _emptyEnv(), _emptyPayee(), 7); // кольцо 16 (MIN_RING)
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        liveNotes[1] += _sumDi(ch.di); // сдача жива
        liveNotes[1] -= d;             // потраченная ушла
        // сдача минтится на стелс-точки (batch X) — номиналы в учёте
    }

    function _opCashout() internal {
        string memory tag = string(abi.encodePacked("at12out", nonce++));
        address po = _deployPayout(address(0xC1), bytes32(nonce));
        bytes[] memory ring = _seedPair(1, DI, N16, tag); // кольцо 16 (MIN_RING)
        uint256[] memory secs = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) secs[j] = _secretOf(tag, j);
        uint256 d = DenomGrid.denomOf(1, DI);
        Prep memory p = _prepFrom(tag, ring, secs, 1, DI,
            po, _emptyChange(), _emptyEnv(), _emptyPayee(), 0);
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        liveNotes[1] -= d; // нота ушла; комиссия обналичивания — из выплаты
    }

    function _opEnvelope(bool claim) internal {
        string memory tag = string(abi.encodePacked("at12env", nonce));
        bytes32 id = bytes32(keccak256(abi.encodePacked(tag)));
        uint256 d = DenomGrid.denomOf(1, DI);
        uint256 amt = 200e6;
        uint256 f = (d * 15 + 9999) / 10000; // feeTransfer от полного номинала
        ILaserGunCore.Envelope memory env = _envFor(1, amt, id, block.timestamp + 1 days, false, _secretOf(tag, 0));
        ILaserGunCore.Change memory ch = _changeFor(1, d - amt - f, string(abi.encodePacked(tag, "-c")));
        bytes[] memory ring = _seedPair(1, DI, N16, tag);
        uint256[] memory secs = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) secs[j] = _secretOf(tag, j);
        Prep memory p = _prepFrom(tag, ring, secs, 1, DI,
            address(core), ch, env, _emptyPayee(), 0);
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        liveNotes[1] += _sumDi(ch.di);
        liveNotes[1] -= d;
        openEscrow[1] += amt;
        envSum[id] = amt;
        envKnown[id] = true;
        if (claim) {
            core.claimEnvelope(id, new bytes(0));
            liveNotes[1] += amt;
            openEscrow[1] -= amt;
        } else {
            vm.warp(block.timestamp + 2 days);
            core.refundEnvelope(id);
            liveNotes[1] += amt;
            openEscrow[1] -= amt;
        }
        ++nonce;
    }

    function _opTreasurySweep() internal {
        // казна выводит излишек сверх обязательств (inv-16 earmark не задет):
        // свип только в размере излишка — если бы ушёл earmarked, INV-16 нарушился бы
        uint256 aBal = IERC20Minimal(pool.aTokenOf(address(usdc))).balanceOf(treasury);
        uint256 obligation = liveNotes[1] + openEscrow[1]
            + (core.feesAccrued(1) - executor.feesWithdrawn(1));
        address aT = pool.aTokenOf(address(usdc)); // до prank: view-вызов съедает prank
        if (aBal > obligation + 1) {
            uint256 excess = aBal - obligation - 1;
            vm.prank(treasury);
            IERC20Minimal(aT).transfer(address(0xD31), excess);
        }
    }

    function _opSweepFees() internal {
        uint256 accrued = core.feesAccrued(1);
        uint256 withdrawn = executor.feesWithdrawn(1);
        if (accrued > withdrawn) {
            vm.prank(feesOwner);
            executor.sweepFees(1, feesOwner, accrued - withdrawn);
        }
    }

    // ═══════════════ fuzz-прогон ═══════════════

    function test_random_sequence_conservation(uint256 seedRaw) public {
        uint256 seed = bound(seedRaw, 1, type(uint32).max);
        for (uint256 step = 0; step < 24; ++step) {
            uint256 op = uint256(keccak256(abi.encodePacked(seed, step))) % 6;
            console2.log("step", step); console2.log("op", op);
            if (op == 0) _opSpendChange();
            else if (op == 1) _opCashout();
            else if (op == 2) _opEnvelope(true);
            else if (op == 3) _opEnvelope(false);
            else if (op == 4) _opTreasurySweep();
            else _opSweepFees();

            _checkInv16(1);
            _checkInv23();
            _checkInv17();
        }
    }
}
