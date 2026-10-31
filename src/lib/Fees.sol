// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @title Fees
/// @notice Комиссии протокола (6.7 ТЗ): константы байткода, ceil-округление,
///          grid-приведение нотных комиссий, порог обнуления 10%.
library Fees {
    uint256 public constant FEE_IN_BPS = 10; // 0.10%
    uint256 public constant FEE_TRANSFER_BPS = 15; // 0.15%
    uint256 public constant FEE_OUT_BPS = 25; // 0.25%
    uint256 public constant FEE_CAP_BPS = 100; // жёсткий потолок 1% (FeeCapExceeded)
    uint256 public constant FEE_GRID_CAP_BPS = 1000; // порог обнуления 10%

    /// @notice Сырая комиссия: ceil(V × bps / 10000) в минимальных единицах.
    function rawFee(uint256 value, uint256 bps) internal pure returns (uint256) {
        // округление вверх в пользу протокола
        return (value * bps + 9999) / 10000;
    }

    /// @notice Нотная комиссия: grid-приведение вверх до кратности минимальному
    ///          номиналу сетки; обнуление при превышении 10% V или вытеснении
    ///          минимального номинала.
    function gridFee(uint256 value, uint256 bps, uint256 minDenom_)
        internal pure returns (uint256)
    {
        uint256 f = rawFee(value, bps);
        if (f == 0) return 0;
        // приведение вверх до кратности минимальному номиналу
        uint256 rem = f % minDenom_;
        if (rem != 0) f += minDenom_ - rem;
        // порог 10%: grid-комиссия выше FEE_GRID_CAP_BPS (1000 bps) доли V — ноль
        if (f * 10000 > value * FEE_GRID_CAP_BPS) return 0;
        // вытеснение минимального номинала: остаток операции ниже минимальной
        // ноты — комиссия не взимается (защита малых номиналов, 6.7)
        if (value - f < minDenom_) return 0;
        return f;
    }

    /// @notice feeIn для ввода: grid-комиссия от полной суммы вклада.
    ///          Ставки одинаковы для обоих активов (6.7).
    function feeIn(uint256, uint256 deposited, uint256 minDenom_)
        internal pure returns (uint256)
    {
        return gridFee(deposited, FEE_IN_BPS, minDenom_);
    }

    /// @notice feeTransfer: grid-комиссия от полного номинала потраченной ноты.
    function feeTransfer(uint256, uint256 denomValue, uint256 minDenom_)
        internal pure returns (uint256)
    {
        return gridFee(denomValue, FEE_TRANSFER_BPS, minDenom_);
    }

    /// @notice feeOut: сырая сумма без разложения — wei-точность допустима.
    function feeOut(uint256 denomValue) internal pure returns (uint256) {
        uint256 f = rawFee(denomValue, FEE_OUT_BPS);
        // вытеснение: вывод не опускается ниже минимальной ноты — для сырой
        // суммы защиты малых нот нет: обналичивание минимальной ноты невозможно
        // по построению реестра (номинал ≥ минимального)
        return f;
    }

    error FeeCapExceeded();
}
