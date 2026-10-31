// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Points} from "../../src/lib/Points.sol";
import {LSAG} from "../../src/lib/LSAG.sol";
import {SolLSAG} from "../lib/SolLSAG.sol";

/// @notice unit/points.t.js — парсинг, on-curve, формат x‖y (реестр 13.3).
///          Трассировка: INV-8, AT-9.
contract PointsTest is Test {
    function test_validGeneratorEncoding() public view {
        bytes memory g = abi.encodePacked(uint256(1), uint256(2));
        assertTrue(Points.validPoint(g));
    }

    function test_invalidOnCurve() public {
        // (1,1) не на кривой
        bytes memory bad = abi.encodePacked(uint256(1), uint256(1));
        vm.expectRevert(Points.InvalidPoint.selector);
        this.callDecode(bad);
    }

    function callDecode(bytes memory pt) external pure {
        Points.decode(pt);
    }

    function test_zeroPointIsInfinity() public {
        bytes memory inf = new bytes(64);
        assertFalse(Points.validPoint(inf));
    }

    function test_coordOverflowP() public {
        bytes memory bad = abi.encodePacked(Points.P, uint256(2)); // x >= p
        assertFalse(Points.validPoint(bad));
    }

    function test_wrongLength() public {
        vm.expectRevert(Points.InvalidPoint.selector);
        this.callDecode(hex"00");
    }

    function test_scalarMulG_identityOrder() public view {
        // n·G == бесконечность (0,0 в precompile-кодировке)
        (uint256 x, uint256 y) = Points.mulG(Points.N);
        assertEq(x, 0);
        assertEq(y, 0);
    }

    function test_addGTwiceEqualsMulTwo() public view {
        (uint256 ax, uint256 ay) = Points.ecAdd(1, 2, 1, 2);
        (uint256 mx, uint256 my) = Points.mulG(2);
        assertEq(ax, mx);
        assertEq(ay, my);
    }

    function testFuzz_mulAddConsistency(uint256 a, uint256 b) public view {
        a = bound(a, 1, Points.N - 1);
        b = bound(b, 1, Points.N - 1);
        (uint256 ax, uint256 ay) = Points.mulG(a);
        (uint256 bx, uint256 by) = Points.mulG(b);
        (uint256 sx, uint256 sy) = Points.ecAdd(ax, ay, bx, by);
        (uint256 mx, uint256 my) = Points.mulG(addmod(a, b, Points.N));
        assertEq(sx, mx);
        assertEq(sy, my);
    }
}

/// @notice unit/lsag.t.js — векторы JS<->Solidity (S1); здесь вектор
///          Solidity-подпись → Solidity-верификация. Кросс-векторы с TypeScript
///          генерирует SDK (npm run vectors) и проверяет test/vectors.json.
///          Трассировка: INV-3, INV-8, AT-4, AT-5.
contract LSAGTest is Test {
    function _ring(uint256 n) internal view returns (bytes[] memory ring, uint256[] memory secrets) {
        ring = new bytes[](n);
        secrets = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            secrets[i] = uint256(keccak256(abi.encode("note", i))) % Points.N;
            ring[i] = _pt(secrets[i]);
        }
    }

    function _ringOther(uint256 n) internal view returns (bytes[] memory ring, uint256[] memory secrets) {
        ring = new bytes[](n);
        secrets = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            secrets[i] = uint256(keccak256(abi.encode("other", i))) % Points.N;
            ring[i] = _pt(secrets[i]);
        }
    }

    function _pt(uint256 scalar) internal view returns (bytes memory) {
        (uint256 x, uint256 y) = Points.mulG(scalar);
        return abi.encodePacked(x, y);
    }

    function test_sign_verify_roundtrip_n16() public view {
        (bytes[] memory ring, uint256[] memory secrets) = _ring(16);
        uint256 pi = 7;
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        bytes32 m = keccak256("message M");
        (bytes32 c1, uint256[] memory s, bytes memory I) = SolLSAG.sign(m, ring, pi, secrets[pi], hp);
        assertTrue(LSAG.verify(m, ring, hp, I, c1, s));
    }

    function test_verify_fails_wrong_message() public {
        (bytes[] memory ring, uint256[] memory secrets) = _ring(16);
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        (bytes32 c1, uint256[] memory s, bytes memory I) =
            SolLSAG.sign(keccak256("m1"), ring, 3, secrets[3], hp);
        assertFalse(LSAG.verify(keccak256("m2"), ring, hp, I, c1, s));
    }

    function test_verify_fails_substituted_recipient_in_m() public {
        // AT-5: подмена recipient/assetId в M ломает подпись
        (bytes[] memory ring, uint256[] memory secrets) = _ring(16);
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        (bytes32 c1, uint256[] memory s, bytes memory I) =
            SolLSAG.sign(keccak256("m1"), ring, 3, secrets[3], hp);
        // тот же ring, но M с изменённым байтом recipient-блока
        bytes32 m2 = keccak256(abi.encodePacked(keccak256("m1"), bytes20(uint160(0xdead))));
        assertFalse(LSAG.verify(m2, ring, hp, I, c1, s));
    }

    function test_verify_fails_foreign_ring() public {
        // AT-4: InvalidSignature на чужом кольце (иначе — детерминированном)
        (bytes[] memory ring, uint256[] memory secrets) = _ring(16);
        (bytes[] memory foreign, ) = _ringOther(16);
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        (bytes32 c1, uint256[] memory s, bytes memory I) =
            SolLSAG.sign(keccak256("m"), ring, 3, secrets[3], hp);
        bytes[] memory hpForeign = SolLSAG.hpForAll(foreign);
        assertFalse(LSAG.verify(keccak256("m"), foreign, hpForeign, I, c1, s));
    }

    function test_verify_rejects_noncanonical_scalar() public {
        (bytes[] memory ring, uint256[] memory secrets) = _ring(16);
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        (bytes32 c1, uint256[] memory s, bytes memory I) =
            SolLSAG.sign(keccak256("m"), ring, 3, secrets[3], hp);
        s[5] = Points.N; // неканонический скаляр >= n
        assertFalse(LSAG.verify(keccak256("m"), ring, hp, I, c1, s));
    }

    function test_hp_deterministic_and_canonical() public pure {
        (uint256 gx, uint256 gy) = (1, 2);
        (bytes memory hp1, uint256 x1, uint256 y1) = SolLSAG.hpTryIncrement(gx, gy);
        (bytes memory hp2, uint256 x2, uint256 y2) = SolLSAG.hpTryIncrement(gx, gy);
        assertEq(hp1.length, 65);
        assertEq(x1, x2);
        assertEq(y1, y2);
        // каноничность: mirror не является меньшим валидным корнем
        assertTrue(y1 >= Points.P - y1 || !_onCurve(x1, Points.P - y1));
    }

    function _onCurve(uint256 x, uint256 y) internal pure returns (bool) {
        return mulmod(y, y, Points.P) == addmod(mulmod(mulmod(x, x, Points.P), x, Points.P), 3, Points.P);
    }
}
