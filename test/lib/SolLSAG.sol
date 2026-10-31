// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Points} from "../../src/lib/Points.sol";

/// @title SolLSAG
/// @notice Генерация LSAG-подписи в тестовом контуре (эмуляция клиента):
///          повторяет псевдокод приложения Б ТЗ. Используется только тестами.
library SolLSAG {
    using Points for bytes;

    /// @notice Hash-to-point с неизвестным дискретным логарифмом (6.3),
    ///          канонический корень — большее значение; возвращает 65 байт.
    function hpTryIncrement(uint256 yx, uint256 yy)
        internal pure returns (bytes memory hp65, uint256 hx, uint256 hy)
    {
        for (uint256 c = 0; c < 256; ++c) {
            bytes32 h = keccak256(abi.encodePacked(yx, yy, uint8(c)));
            uint256 x = uint256(h) % Points.P;
            uint256 rhs = addmod(mulmod(mulmod(x, x, Points.P), x, Points.P), 3, Points.P);
            uint256 y = powMod(rhs, (Points.P + 1) / 4, Points.P);
            if (mulmod(y, y, Points.P) == rhs) {
                uint256 mirror = Points.P - y;
                if (mirror > y) y = mirror; // канонический корень — больший
                hp65 = abi.encodePacked(x, y, uint8(c));
                return (hp65, x, y);
            }
        }
        revert("hp failed");
    }

    function powMod(uint256 base, uint256 exp, uint256 mod)
        internal pure returns (uint256 result)
    {
        result = 1;
        base %= mod;
        while (exp > 0) {
            if (exp & 1 == 1) result = mulmod(result, base, mod);
            base = mulmod(base, base, mod);
            exp >>= 1;
        }
    }

    /// @notice Подпись траты (приложение Б): однопроходная версия —
    ///          все challenges собираются в массив c[0..n-1], затем закрытие.
    function sign(
        bytes32 mHash,
        bytes[] memory ring,
        uint256 pi,
        uint256 ySecret,
        bytes[] memory
    ) internal view returns (bytes32 c1Out, uint256[] memory sArr, bytes memory keyImage) {
        uint256 n = ring.length;
        sArr = new uint256[](n);
        uint256[] memory cArr = new uint256[](n);

        (uint256 pix, uint256 piy) = coords(ring[pi]);
        (, uint256 hpx, uint256 hpy) = hpTryIncrement(pix, piy);
        (uint256 ix, uint256 iy) = Points.ecMul(ySecret, hpx, hpy);
        keyImage = abi.encodePacked(ix, iy);

        uint256 alpha = (uint256(keccak256(abi.encodePacked(mHash, uint256(0x5eed)))) % (Points.N - 1)) + 1;
        for (uint256 k = 0; k < n; ++k) {
            if (k != pi) {
                sArr[k] = (uint256(keccak256(abi.encodePacked(mHash, k, uint256(0x51)))) % (Points.N - 1)) + 1;
            }
        }

        // c_(pi+1) = H(M, alpha·G, alpha·Hp(Y_pi))
        (uint256 agx, uint256 agy) = Points.mulG(alpha);
        (uint256 ahx, uint256 ahy) = Points.ecMul(alpha, hpx, hpy);
        uint256 cNext = Points.modN(keccak256(abi.encodePacked(mHash, agx, agy, ahx, ahy)));

        // один проход по кольцу: j = pi+1 .. pi+n (индексы mod N), последний шаг — pi
        for (uint256 step = 1; step <= n; ++step) {
            uint256 j = (pi + step) % n;
            cArr[j] = cNext;
            if (j == pi) break; // c[pi] записан для закрытия
            (uint256 yjx, uint256 yjy) = Points.decode(ring[j]);
            (, uint256 jhx, uint256 jhy) = hpTryIncrement(yjx, yjy);
            (uint256 sgx, uint256 sgy) = Points.mulG(sArr[j]);
            (uint256 cyx, uint256 cyy) = Points.ecMul(cNext, yjx, yjy);
            (uint256 lx, uint256 ly) = Points.ecAdd(sgx, sgy, cyx, cyy);
            (uint256 shx, uint256 shy) = Points.ecMul(sArr[j], jhx, jhy);
            (uint256 cix, uint256 ciy) = Points.ecMul(cNext, ix, iy);
            (uint256 rx, uint256 ry) = Points.ecAdd(shx, shy, cix, ciy);
            cNext = Points.modN(keccak256(abi.encodePacked(mHash, lx, ly, rx, ry)));
        }

        // закрытие: s_pi = alpha − c_pi·y mod n
        sArr[pi] = addmod(alpha, Points.N - mulmod(cArr[pi], ySecret, Points.N), Points.N);
        c1Out = bytes32(cArr[0]);
    }

    function coords(bytes memory pt) internal pure returns (uint256 x, uint256 y) {
        assembly {
            x := mload(add(pt, 32))
            y := mload(add(pt, 64))
        }
    }

    /// @notice Полный набор hp-точек кольца (65-байтовые).
    function hpForAll(bytes[] memory ring) internal pure returns (bytes[] memory) {
        bytes[] memory hp = new bytes[](ring.length);
        for (uint256 j = 0; j < ring.length; ++j) {
            (uint256 yx, uint256 yy) = coords(ring[j]);
            (hp[j], , ) = hpTryIncrement(yx, yy);
        }
        return hp;
    }
}
