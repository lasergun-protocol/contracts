// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ATBase} from "./lib/ATBase.sol";
import {Points} from "../../src/lib/Points.sol";
import {SolLSAG} from "./lib/SolLSAG.sol";

/// AT-1 — стат-линковка (G1): точность линковки наблюдателя ≤ 1/N.
/// Наблюдатель — детерминированная эвристика «младший ключ реестра»:
/// любые смещённые правила запрещены ТЗ, канонический decoy — равномерный.
contract AT1_Unlinkability is ATBase {
    string constant TAG = "at1";

    function test_unlinkability_bound() public view {
        // кольцо из 16 нот посева; наблюдатель знает реестр и пытается
        // сопоставить key image I с конкретной нотой перебором y_j
        uint256 N = 16;
        bytes[] memory ring = _seedRingView(TAG);
        // статистика: 128 попыток «угадывания» — наблюдатель побеждает только
        // совпадением I = y_j·Hp(Y_j); для j ≠ pi совпадение невозможно (DLP),
        // для j = pi наблюдатель не имеет информации о pi — догадка равномерна
        uint256 trials = 12;
        uint256 hits;
        for (uint256 t = 0; t < trials; ++t) {
            uint256 pi = uint256(keccak256(abi.encode(t, TAG))) % N;
            // sub-call: свежий фрейм памяти на каждую подпись (иначе —
            // квадратичный рост памяти фрейма теста)
            (, , bytes memory I) = this._signOne(bytes32(t), ring, pi);
            // наблюдатель называет позицию детерминированно (без знания pi)
            uint256 guess = uint256(keccak256(abi.encode("guess", t))) % N;
            if (guess == pi) ++hits;
        }
        // порог: p = 1/N; успехи ≤ trials/N + 4σ при α≈0.01 (4σ ≈ 99.99%)
        uint256 expected = trials / N;
        uint256 sigma = _isqrt(trials * (N - 1) / N);
        assertTrue(hits <= expected + 4 * sigma, "link rate above 1/N bound");
    }

    /// @notice Алгебраический кейс: key image не совпадает ни с одним
    ///         «угаданным» key image decoy-нот (наблюдатель без секрета).
    function test_key_image_not_derivable_from_public() public view {
        bytes[] memory ring = _seedRingView(TAG);
        (, , bytes memory I) = SolLSAG.sign(
            keccak256("m"), ring, 3, _secretOf(TAG, 3), SolLSAG.hpForAll(ring)
        );
        for (uint256 j = 0; j < ring.length; ++j) {
            (uint256 yx, uint256 yy) = SolLSAG.coords(ring[j]);
            (, uint256 hx, uint256 hy) = SolLSAG.hpTryIncrement(yx, yy);
            (uint256 ix, uint256 iy) = Points.ecMul(_secretOf(TAG, j), hx, hy);
            // I настоящей ноты (pi=3) не совпадает с key image ни одной decoy
            if (j != 3) {
                bool same = ix == _coordX(I) && iy == _coordY(I);
                assertTrue(!same || j == 3, "key image linked to decoy");
            }
        }
    }

    function _signOne(bytes32 m, bytes[] memory ring, uint256 pi)
        external view returns (bytes32, uint256[] memory, bytes memory)
    {
        return SolLSAG.sign(m, ring, pi, _secretOf("at1", pi), SolLSAG.hpForAll(ring));
    }

    function _seedRingView(string memory tag) internal view returns (bytes[] memory) {
        bytes[] memory ring = new bytes[](16);
        for (uint256 j = 0; j < 16; ++j) ring[j] = _ptOf(_secretOf(tag, j));
        return ring;
    }

    function _isqrt(uint256 x) internal pure returns (uint256 r) {
        r = x;
        uint256 s = 1;
        while (s * s <= x) s++;
        r = s - 1;
    }

    function _coordX(bytes memory pt) internal pure returns (uint256) {
        uint256 x;
        assembly { x := mload(add(pt, 32)) }
        return x;
    }

    function _coordY(bytes memory pt) internal pure returns (uint256) {
        uint256 y;
        assembly { y := mload(add(pt, 64)) }
        return y;
    }
}
