// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {Fees} from "../../src/lib/Fees.sol";

/// @notice unit/grid.t.js — сетка номиналов и разложения (реестр 13.3).
///          Трассировка: 5.3 (таблица 5), 6.7 (комиссии), AT-23.
contract GridTest is Test {
    function test_usdc_grid_bounds() public {
        // 36 номиналов USDC: {1,3,5}×10^k, k=−6..5 (микро-USDC единицы)
        assertEq(DenomGrid.denomCount(1), 36);
        assertEq(DenomGrid.denomOf(1, 0), 1); // 0.000001 USDC = 1 микро
        assertEq(DenomGrid.denomOf(1, 1), 3);
        assertEq(DenomGrid.denomOf(1, 2), 5);
        assertEq(DenomGrid.denomOf(1, 3), 10); // 0.00001
        assertEq(DenomGrid.denomOf(1, 6), 100); // 0.0001
        assertEq(DenomGrid.denomOf(1, 9), 1_000); // 0.001 USDC
        assertEq(DenomGrid.denomOf(1, 18), 1_000_000); // 1 USDC (k=0)
        assertEq(DenomGrid.denomOf(1, 27), 1_000_000_000); // 1000 USDC (k=+3)
        assertEq(DenomGrid.denomOf(1, 35), 500_000_000_000); // 500k USDC
        vm.expectRevert(DenomGrid.UnknownDenom.selector);
        this.callDenomOf(1, 36);
    }

    function callDenomOf(uint256 assetId, uint256 di) external pure {
        DenomGrid.denomOf(assetId, di);
    }

    function test_eth_grid_bounds() public {
        // 21 номинал ETH: от 0.0001 до 500
        assertEq(DenomGrid.denomCount(2), 21);
        assertEq(DenomGrid.denomOf(2, 0), 1e14); // 0.0001 ETH
        assertEq(DenomGrid.denomOf(2, 20), 500 ether);
        vm.expectRevert(DenomGrid.UnknownDenom.selector);
        this.callDenomOf(2, 21);
    }

    function test_unknown_asset() public {
        vm.expectRevert(DenomGrid.UnknownAsset.selector);
        this.callDenomOf(3, 0);
    }

    function test_index_roundtrip_all_denoms() public view {
        for (uint256 i = 0; i < 36; ++i) {
            uint256 v = DenomGrid.denomOf(1, i);
            assertEq(DenomGrid.indexOf(1, v), i, "USDC roundtrip");
        }
        for (uint256 i = 0; i < 21; ++i) {
            uint256 v = DenomGrid.denomOf(2, i);
            assertEq(DenomGrid.indexOf(2, v), i, "ETH roundtrip");
        }
    }

    function test_non_grid_values_rejected() public {
        vm.expectRevert(DenomGrid.UnknownDenom.selector);
        this.callIndexOf(1, 2); // 2 микро — не в сетке {1,3,5}
    }

    function callIndexOf(uint256 assetId, uint256 value) external pure {
        DenomGrid.indexOf(assetId, value);
    }

    function test_max_amounts() public view {
        // максимум сетки: 999 999.999999 USDC / 999.9999 ETH
        assertEq(DenomGrid.maxAmount(1), 999_999_999_999);
        assertEq(DenomGrid.maxAmount(2), 999_9999e14);
    }

    function test_eth_grid_values() public view {
        // ключевые значения ETH-сетки {1,3,5}×10^k, k=−4..2
        assertEq(DenomGrid.denomOf(2, 0), 1e14); // 0.0001 ETH
        assertEq(DenomGrid.denomOf(2, 1), 3e14);
        assertEq(DenomGrid.denomOf(2, 2), 5e14);
        assertEq(DenomGrid.denomOf(2, 3), 1e15); // 0.001 ETH
        assertEq(DenomGrid.denomOf(2, 12), 1 ether); // k=0, цифра 1
        assertEq(DenomGrid.denomOf(2, 15), 10 ether); // k=+1
        assertEq(DenomGrid.denomOf(2, 20), 500 ether); // k=+2, цифра 5
    }

    /// @notice Таблица 5: каноническое разложение — не более трёх нот на разряд.
    ///          Проверка для сумм по разрядам (обязательна для входного минта —
    ///          SDK; ядро проверяет консервацию).
    function test_canonical_example_34_245_usdc() public view {
        // 34.245 = 30 + 3 + 1 + 0.1 + 0.1 + 0.03 + 0.01 + 0.005 — 8 нот
        uint256 total = 34_245_000; // микро-USDC
        uint256 sum = 0;
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 30_000_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 3_000_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 1_000_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 100_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 100_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 30_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 10_000));
        sum += DenomGrid.denomOf(1, DenomGrid.indexOf(1, 5_000));
        assertEq(sum, total);
    }

    // ── комиссии (6.7, AT-23) ───────────────────────────────────────

    function test_feeIn_ceil_and_grid() public view {
        // V = 1 000 000 (1 USDC): feeIn = ceil(1e6 × 10 / 10000) = 1000
        uint256 f = Fees.feeIn(1, 1_000_000, DenomGrid.minDenom(1));
        assertEq(f, 1_000);
        // остаток входа: 999 000 микро = канонически разложим (таблица 5)
        assertEq(DenomGrid.sumOf(1, _decomp(999_000)), 999_000);
    }

    function test_fee_out_raw_precision() public view {
        // feeOut — сырая сумма (wei-точность допустима)
        uint256 f = Fees.feeOut(10_000_000); // 10 USDC
        assertEq(f, 25_000); // 0.25% = 25 000 микро
    }

    function test_fee_transfer_full_denomination_base() public view {
        // комиссия перевода берётся с полного номинала ноты 10 USDC (6.7)
        uint256 d = DenomGrid.denomOf(1, DenomGrid.indexOf(1, 10_000_000));
        assertEq(d, 10_000_000);
        uint256 f = Fees.feeTransfer(1, d, DenomGrid.minDenom(1));
        assertEq(f, 15_000); // 0.015 USDC
    }

    function test_fee_grid_cap_10_percent() public view {
        // порог 10%: нота 3 микро → feeIn = ceil(3×10/10000) = 1
        // остаток 3−1=2 < 1? нет; 1/3 = 33% > 10% → ноль (порог)
        assertEq(Fees.feeIn(1, 3, DenomGrid.minDenom(1)), 0);
        // нота 100 000 (0.1 USDC): feeTransfer = ceil(100000×15/10000) = 150
        // → 150 < 10% от 100000 и остаток ≥ 1 — взимается
        assertEq(Fees.feeTransfer(1, 100_000, DenomGrid.minDenom(1)), 150);
    }

    function test_fee_displacement_rule() public view {
        // ETH: V = 0.0002 ETH; raw = ceil(2e14×15/10000) = 3e11 wei
        // grid-приведение вверх → 1×1e14 (0.0001 ETH) = 50% > 10% → ноль
        assertEq(Fees.feeTransfer(2, 2e14, DenomGrid.minDenom(2)), 0);
    }

    function test_eth_grid_rounding() public view {
        // ETH: комиссия кратна 0.0001 ETH; V = 1 ETH: feeTransfer = 0.0015
        // — уже кратно сетке (15×1e14), остаётся 0.0015
        uint256 f = Fees.feeTransfer(2, 1 ether, DenomGrid.minDenom(2));
        assertEq(f, 0.0015 ether);
        // консервация: 1 ETH = 0.9985 (выход) + 0.0015 (комиссия)
        assertTrue(f + 0.9985 ether == 1 ether);
    }

    function _decomp(uint256 amount) internal view returns (uint256[] memory di) {
        // жадное каноническое разложение (таблица 5)
        uint256[] memory tmp = new uint256[](64);
        uint256 n = 0;
        while (amount > 0) {
            // старший разряд
            uint256 pow = 1;
            while (pow * 10 <= amount) pow *= 10;
            uint256 digit = amount / pow;
            uint256[3] memory grid = [uint256(1), uint256(3), uint256(5)];
            uint256 idx = 2;
            for (uint256 k = 0; k < 3; ++k) {
                if (grid[k] <= digit) idx = k;
            }
            tmp[n++] = DenomGrid.indexOf(1, grid[idx] * pow);
            amount -= grid[idx] * pow;
        }
        di = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) di[k] = tmp[k];
    }
}
