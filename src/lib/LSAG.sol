// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Points} from "./Points.sol";

/// @title LSAG
/// @notice Верификация linkable spontaneous anonymous group подписи (6.3 ТЗ).
/// @dev Верификация — чистая функция от (кольцо, hp, I, M, c1, s); единственное
///      блочное чтение ядра — CHAINID, и оно входит в M (INV-2).
///      Точки Hp(Y_i) подаются клиентом в calldata (65 байт: x‖y + счётчик c)
///      и перепроверяются деривацией try-and-increment до всякой арифметики.
library LSAG {
    using Points for bytes;

    uint256 internal constant P = Points.P;
    uint256 internal constant N_ORDER = Points.N;

    error InvalidPoint();
    error InvalidSignature();

    /// @notice Hash-to-point с неизвестным дискретным логарифмом (6.3).
    /// @dev try-and-increment: x = H(Y‖c) mod p, пока x^3+3 — квадратичный вычет;
    ///      y = (x^3+3)^((p+1)/4) mod p; канонический корень — большее значение.
    ///      Onchain — только перепроверка деривации; сам корень подаёт клиент.
    /// @param yBytes 64 байта x‖y члена кольца
    /// @param c счётчик try-and-increment
    /// @param hx координата x заявленной hp-точки
    /// @param hy координата y заявленной hp-точки
    /// @return true, если деривация сходится
    function hpDerivationOk(bytes memory yBytes, uint8 c, uint256 hx, uint256 hy)
        internal pure returns (bool)
    {
        if (yBytes.length != 64) return false;
        if (hx >= P || hy >= P) return false;
        if (hx == 0 && hy == 0) return false;
        // 1) x = H(Y (64 байта) || uint8(c)) mod p
        bytes32 h = keccak256(abi.encodePacked(yBytes, c));
        if (uint256(h) % P != hx) return false;
        // 2) y^2 == x^3 + 3 (mod p)
        if (!Points.validXY(hx, hy)) return false;
        // 3) канонический корень: y — большее из (y, p − y) (6.3);
        //    не-канонический (меньший) корень запрещён
        uint256 mirror = P - hy;
        if (mirror > hy) return false;
        return true;
    }

    /// @notice Ключ-образ: I = y · Hp(X_real) — считает клиент; ядро проверяет
    ///          только валидность точки и переиспользование (nullifier = H(I)).
    /// @notice Подписываемое сообщение собирает ядро; здесь — пересчёт цепочки.
    /// @param m 32-байтовый хэш сообщения M
    /// @param ring кольцо коммитментов Y_1..Y_N (по 64 байта)
    /// @param hp точки Hp(Y_i) (по 65 байт: x‖y + uint8 счётчик)
    /// @param i 64-байтовый key image
    /// @param c1 начальный challenge
    /// @param s массив скаляров длины N
    /// @return ok подпись валидна
    function verify(
        bytes32 m,
        bytes[] memory ring,
        bytes[] memory hp,
        bytes memory i,
        bytes32 c1,
        uint256[] memory s
    ) internal view returns (bool ok) {
        uint256 n = ring.length;
        if (s.length != n || hp.length != n) return false;
        if (uint256(c1) >= N_ORDER) return false;

        (uint256 ix, uint256 iy) = Points.decode(i);

        // каноничность скаляров до арифметики (INV-8)
        for (uint256 j = 0; j < n; ++j) {
            if (uint256(s[j]) >= N_ORDER) return false;
        }

        uint256 cx = uint256(c1);
        for (uint256 j = 0; j < n; ++j) {
            // decodeHp валидирует длину и on-curve (деривация — в validateRing)
            (uint256 hpx, uint256 hpy, ) = decodeHp(hp[j]);

            // L_j = s_j·G + c_j·Y_j
            (uint256 gx, uint256 gy) = Points.mulG(s[j]);
            (uint256 ryx, uint256 ryy) = Points.decode(ring[j]);
            (uint256 lx, uint256 ly) = Points.ecMul(cx, ryx, ryy);
            (lx, ly) = Points.ecAdd(gx, gy, lx, ly);

            // R_j = s_j·Hp(Y_j) + c_j·I
            (uint256 rx1, uint256 ry1) = Points.ecMul(s[j], hpx, hpy);
            (uint256 rx2, uint256 ry2) = Points.ecMul(cx, ix, iy);
            (uint256 rrx, uint256 rry) = Points.ecAdd(rx1, ry1, rx2, ry2);

            // c_(j+1) = H(M, L, R) mod n
            cx = Points.modN(keccak256(abi.encodePacked(m, lx, ly, rrx, rry)));
        }

        return cx == uint256(c1);
    }

    /// @notice Декодирование hp-точки: 65 байт x‖y || uint8(c).
    function decodeHp(bytes memory hp)
        internal pure returns (uint256 x, uint256 y, uint8 counter)
    {
        if (hp.length != 65) revert InvalidPoint();
        assembly {
            x := mload(add(hp, 32))
            y := mload(add(hp, 64))
            counter := mload(add(hp, 65))
        }
        if (!Points.validXY(x, y)) revert InvalidPoint();
    }

    /// @notice Валидация кольца: точки валидны, попарно различны (INV-14),
    ///          hp-точки проходят деривацию (6.3).
    function validateRing(bytes[] memory ring, bytes[] memory hp)
        internal pure
    {
        uint256 n = ring.length;
        if (n != hp.length) revert InvalidPoint();
        for (uint256 j = 0; j < n; ++j) {
            (uint256 hx, uint256 hy, uint8 counter) = decodeHp(hp[j]);
            bytes memory member = ring[j];
            if (member.length != 64) revert InvalidPoint();
            if (!hpDerivationOk(member, counter, hx, hy)) revert InvalidPoint();
            // попарная уникальность — O(N²) по хэшам; N ≤ 64, каллдата-хэш дешевле
            // transient-хранилища при этих размерах и не требует EIP-1153
            bytes32 hmember = keccak256(member);
            for (uint256 k = j + 1; k < n; ++k) {
                if (keccak256(ring[k]) == hmember) revert DuplicateRingMember();
            }
        }
    }

    error DuplicateRingMember();
}
