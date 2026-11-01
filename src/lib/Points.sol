// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @title Points
/// @notice Арифметика точек G1 alt_bn128 на precompile 0x06/0x07 (EIP-1108).
/// @dev Раздел 6 ТЗ LaserGun Core v2. Все точки ходят в 64-байтной кодировке
///      x‖y (POINT_ENCODING), по 32 байта big-endian на координату.
///      Ни одна функция не читает блочный контекст (INV-2).
library Points {
    uint256 internal constant P =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 internal constant N =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // dlog(G) неизвестен исполнителю контрактов; генератор зафиксирован EIP-196
    uint256 internal constant GX =
        1;
    uint256 internal constant GY =
        2;

    error InvalidPoint();

    /// @notice Валидность точки: on-curve, не бесконечность, координаты < P.
    function validPoint(bytes memory pt) internal pure returns (bool) {
        if (pt.length != 64) return false;
        uint256 x;
        uint256 y;
        assembly {
            x := mload(add(pt, 32))
            y := mload(add(pt, 64))
        }
        return validXY(x, y);
    }

    function validXY(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        if (x == 0 && y == 0) return false; // бесконечность запрещена (INV-8)
        // y^2 == x^3 + 3 (mod P)
        uint256 lhs = mulmod(y, y, P);
        uint256 rhs = addmod(mulmod(mulmod(x, x, P), x, P), 3, P);
        return lhs == rhs;
    }

    /// @notice Скалярное умножение — precompile 0x07 или double-and-add
    ///          поверх 0x06 (двойственность разрешена 6.3 ТЗ: «ecMul:
    ///          precompile 0x07 или double-and-add»). На реальном чейне
    ///          всегда срабатывает precompile-путь.
    function ecMul(uint256 scalar, uint256 x, uint256 y)
        internal view returns (uint256 rx, uint256 ry)
    {
        // k·P == (k mod n)·P для точек главной группы
        scalar %= N;
        if (scalar == 0 || (x == 0 && y == 0)) return (0, 0);

        // scratch-буфер без аллокаций — память не растёт квадратично;
        // лимит газа на вызов — стоимость precompile 0x07 (6k): упавший
        // вызов не сжигает лимит целиком и позволяет fallback
        bool ok;
        assembly ("memory-safe") {
            // precompile 0x07 принимает (x, y, scalar) — порядок по EIP-197
            let ptr := mload(0x40)
            mstore(ptr, x)
            mstore(add(ptr, 32), y)
            mstore(add(ptr, 64), scalar)
            ok := staticcall(10000, 0x07, ptr, 96, ptr, 64)
            rx := mload(ptr)
            ry := mload(add(ptr, 32))
            mstore(0x40, add(ptr, 96))
        }
        if (ok && (rx != 0 || ry != 0)) return (rx, ry);
        if (ok && rx == 0 && ry == 0) {
            // ok=true и (0,0): либо k ≡ 0 (mod n) — корректная бесконечность
            // (cofactor=1 в alt_bn128), либо точка-аргумент вне кривой/подгруппы.
            if (scalar % N == 0) return (0, 0);
            // валидируем точку-аргумент: на кривой → бесконечность корректна
            // (k·P = inf ⟺ n | k), иначе — некорректный вход (fallback вернёт
            // мусор, поэтому сразу (0,0))
            if (_onCurve(x, y)) return (0, 0);
            return (0, 0);
        }
        // fallback: double-and-add по битам скаляра через 0x06
        return _doubleAndAdd(scalar, x, y);
    }

    function _doubleAndAdd(uint256 scalar, uint256 x, uint256 y)
        internal view returns (uint256 rx, uint256 ry)
    {
        uint256 ax = x;
        uint256 ay = y;
        uint256 k = scalar;
        while (k != 0) {
            if (k & 1 == 1) {
                (rx, ry) = _addAffine(rx, ry, ax, ay);
            }
            (ax, ay) = _addAffine(ax, ay, ax, ay);
            k >>= 1;
        }
    }

    function _onCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        uint256 lhs = mulmod(y, y, P);
        uint256 rhs = addmod(mulmod(mulmod(x, x, P), x, P), 3, P);
        return lhs == rhs;
    }

    function _addAffine(uint256 x1, uint256 y1, uint256 x2, uint256 y2)
        internal view returns (uint256 rx, uint256 ry)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, x1)
            mstore(add(ptr, 32), y1)
            mstore(add(ptr, 64), x2)
            mstore(add(ptr, 96), y2)
            let ok := staticcall(gas(), 0x06, ptr, 128, ptr, 64)
            if iszero(ok) {
                revert(0, 0)
            }
            rx := mload(ptr)
            ry := mload(add(ptr, 32))
            mstore(0x40, add(ptr, 128))
        }
    }

    /// @notice Сложение точек через precompile 0x06. Возвращает (x, y).
    function ecAdd(uint256 x1, uint256 y1, uint256 x2, uint256 y2)
        internal view returns (uint256 rx, uint256 ry)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, x1)
            mstore(add(ptr, 32), y1)
            mstore(add(ptr, 64), x2)
            mstore(add(ptr, 96), y2)
            let ok := staticcall(gas(), 0x06, ptr, 128, ptr, 64)
            if iszero(ok) {
                revert(0, 0)
            }
            rx := mload(ptr)
            ry := mload(add(ptr, 32))
            mstore(0x40, add(ptr, 128))
        }
    }

    /// @notice ecMul над точкой из 64-байтной кодировки.
    function mulScalar(bytes memory pt, uint256 scalar)
        internal view returns (uint256 rx, uint256 ry)
    {
        uint256 x;
        uint256 y;
        assembly {
            x := mload(add(pt, 32))
            y := mload(add(pt, 64))
        }
        return ecMul(scalar, x, y);
    }

    /// @notice Умножение на генератор G.
    function mulG(uint256 scalar) internal view returns (uint256 x, uint256 y) {
        return ecMul(scalar, GX, GY);
    }

    /// @notice Декодирование 64-байтной точки в (x, y) с проверкой (INV-8).
    function decode(bytes memory pt) internal pure returns (uint256 x, uint256 y) {
        if (pt.length != 64) revert InvalidPoint();
        assembly {
            x := mload(add(pt, 32))
            y := mload(add(pt, 64))
        }
        if (!validXY(x, y)) revert InvalidPoint();
    }

    /// @notice Кодирование (x, y) в 64 байта x‖y.
    function encode(uint256 x, uint256 y) internal pure returns (bytes memory) {
        return abi.encodePacked(x, y);
    }

    /// @notice Хэш точки: ровно 64 байта x‖y (nullifier = H(I), s_ноты = H(v·E)).
    function hash(bytes memory pt) internal pure returns (bytes32) {
        if (pt.length != 64) revert InvalidPoint();
        return keccak256(pt);
    }

    /// @notice Скаляр mod n из 32 байт (канонизация challenge).
    function modN(bytes32 b) internal pure returns (uint256) {
        return uint256(b) % N;
    }
}
