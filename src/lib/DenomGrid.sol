// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @title DenomGrid
/// @notice Сетка номиналов {1,3,5}×10^k (раздел 5.3 ТЗ) и комиссии (6.7).
/// @dev USDC: k = −6..+5 (36 номиналов), максимум суммы 999 999.999999
///      (микро-единицы совпадают с минимальным номиналом).
///      ETH: k = −4..+2 (21 номинал), максимум 999.9999 (0.0001 ETH —
///      минимальный номинал и единица grid-округления комиссий).
///      Каноническое разложение (таблица 5) обязательно только для входного
///      минта; ядро проверяет консервацию и MAX_NOTES_PER_MINT.
library DenomGrid {
    // assetId: 1 = USDC, 2 = ETH
    uint256 public constant USDC_SCALE = 1e6; // минимальные единицы USDC
    uint256 public constant ETH_MIN_DENOM = 1e14; // 0.0001 ETH в wei

    // границы k сеток: USDC k∈[−6..5], ETH k∈[−4..2]
    int256 public constant USDC_K_MIN = -6;
    int256 public constant USDC_K_MAX = 5;
    int256 public constant ETH_K_MIN = -4;
    int256 public constant ETH_K_MAX = 2;

    /// @notice Число номиналов в сетке актива.
    function denomCount(uint256 assetId) internal pure returns (uint256) {
        if (assetId == 1) return 36;
        if (assetId == 2) return 21;
        revert UnknownAsset();
    }

    /// @notice Значение номинала по индексу (в минимальных единицах актива).
    /// @dev индекс 0 — младший номинал (1e-6 USDC / 0.0001 ETH);
    ///      далее цифра {1,3,5} × 10^k по возрастанию.
    function denomOf(uint256 assetId, uint256 di) internal pure returns (uint256) {
        if (assetId == 1) {
            if (di >= 36) revert UnknownDenom();
            // k = di/3 − 6; цифра = [1,3,5][di%3]
            int256 k = int256(di / 3) - 6;
            uint256 digit = digitOf(di % 3);
            return digit * pow10(uint256(k + 6)); // 10^(k+6) микро-USDC
        }
        if (assetId == 2) {
            if (di >= 21) revert UnknownDenom();
            int256 k = int256(di / 3) - 4;
            uint256 digit = digitOf(di % 3);
            // digit·10^k ETH = digit·10^(k+4)·(0.0001 ETH) в wei
            return digit * pow10(uint256(k + 4)) * ETH_MIN_DENOM;
        }
        revert UnknownAsset();
    }

    /// @notice Индекс номинала по значению — обязателен для консервации и M.
    function indexOf(uint256 assetId, uint256 value) internal pure returns (uint256) {
        if (assetId == 1) {
            // минимальные единицы — микро-USDC; мантисса {1,3,5}×10^trailing
            if (value == 0) revert UnknownDenom();
            uint256 di = indexFromMantissa(value);
            if (di >= 36) revert UnknownDenom();
            return di;
        }
        if (assetId == 2) {
            // единица сетки — 0.0001 ETH
            if (value == 0 || value % ETH_MIN_DENOM != 0) revert UnknownDenom();
            uint256 mantissa = value / ETH_MIN_DENOM; // в единицах 0.0001
            uint256 di = indexFromMantissa(mantissa);
            if (di >= 21) revert UnknownDenom();
            return di;
        }
        revert UnknownAsset();
    }

    function indexFromMantissa(uint256 mantissa) private pure returns (uint256) {
        // мантисса сетки: значащая цифра ∈ {1,3,5}, остальное — степени 10
        uint256 trailing = 0;
        uint256 m = mantissa;
        while (m % 10 == 0 && m > 0) {
            m /= 10;
            ++trailing;
        }
        if (m == 1) return 0 + trailing * 3;
        if (m == 3) return 1 + trailing * 3;
        if (m == 5) return 2 + trailing * 3;
        revert UnknownDenom();
    }

    function digitOf(uint256 i) private pure returns (uint256) {
        if (i == 0) return 1;
        if (i == 1) return 3;
        return 5;
    }

    function pow10(uint256 e) private pure returns (uint256) {
        uint256 r = 1;
        for (uint256 i = 0; i < e; ++i) r *= 10;
        return r;
    }

    /// @notice Максимум сетки актива (999 999.999999 USDC / 999.9999 ETH).
    function maxAmount(uint256 assetId) internal pure returns (uint256) {
        if (assetId == 1) return 999_999_999_999; // микро-USDC
        if (assetId == 2) return 999_9999e14; // 999.9999 ETH
        revert UnknownAsset();
    }

    /// @notice Минимальный номинал актива — единица grid-округления комиссий.
    function minDenom(uint256 assetId) internal pure returns (uint256) {
        if (assetId == 1) return 1; // микро-USDC
        if (assetId == 2) return ETH_MIN_DENOM;
        revert UnknownAsset();
    }

    /// @notice Сумма номиналов разложения по индексам (консервация).
    function sumOf(uint256 assetId, uint256[] memory di)
        internal pure returns (uint256 total)
    {
        for (uint256 j = 0; j < di.length; ++j) {
            total += denomOf(assetId, di[j]);
        }
    }

    error UnknownAsset();
    error UnknownDenom();
}
