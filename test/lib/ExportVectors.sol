// SPDX-License-Identifier: MIT
// Vector exporter: produces deterministic (seeded) JSON vectors for the
// TypeScript cross-check (PRD S1: 1000 random cases must match JS<->Solidity).
// Run: forge script test/lib/ExportVectors --rpc-url http://localhost:8545 -vvv
// (no state needed — pure/view calls; any EVM works)
pragma solidity >=0.8.24 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {SolLSAG} from "./SolLSAG.sol";
import {Points} from "../../src/lib/Points.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {Fees} from "../../src/lib/Fees.sol";

contract ExportVectors is Script {
    using Points for bytes;

    struct Case {
        bytes32 mHash;
        uint256 pi;
        uint256 secret;
        bytes32 c1;
        uint256 s0;
        uint256 sLast;
        bytes I;
    }

    function _pt(uint256 seed) internal view returns (bytes memory) {
        (uint256 x, uint256 y) = Points.mulG(seed % Points.N);
        return abi.encodePacked(x, y);
    }

    function _h(uint256 a, uint256 b) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(a, b))) % (Points.N - 1) + 1;
    }

    function run() external {
        uint256 from = vm.envOr("CASE_FROM", uint256(0));
        uint256 to = vm.envOr("CASE_TO", uint256(12));
        for (uint256 t = from; t < to; ++t) {
            uint256 n = 16 + (t % 3) * 16; // 16 / 32 / 48
            uint256 pi = t % n;
            uint256 secret = _h(t, 777);
            bytes[] memory ring = new bytes[](n);
            (uint256 sx, uint256 sy) = Points.mulG(secret);
            for (uint256 j = 0; j < n; ++j) {
                ring[j] = (j == pi) ? abi.encodePacked(sx, sy) : _pt(_h(t, j));
            }
            bytes32 mHash = keccak256(abi.encodePacked("LG2-vector", t));
            (bytes32 c1, uint256[] memory s, bytes memory I) = SolLSAG.sign(mHash, ring, pi, secret, SolLSAG.hpForAll(ring));
            vm.writeFile(_name(t), _case(t, mHash, ring, c1, s, I, secret, pi));
        }
    }

    function _name(uint256 t) internal pure returns (string memory) {
        return string(abi.encodePacked("./vectors/case_", vm.toString(t), ".json"));
    }

    function _case(
        uint256 t, bytes32 mHash, bytes[] memory ring, bytes32 c1,
        uint256[] memory s, bytes memory I, uint256 secret, uint256 pi
    ) internal pure returns (string memory) {
        string memory j = string(abi.encodePacked(
            ' {"t":', vm.toString(t),
            ', "mHash":"', vm.toString(mHash), '"',
            ', "ring":', _arr(ring),
            ', "c1":"', vm.toString(c1), '"',
            ', "s":[', _uarr(s), ']',
            ', "I":"', vm.toString(I), '"',
            ', "secret":"', vm.toString(secret), '"',
            ', "pi":', vm.toString(pi), '}',
            "\n"
        ));
        return j;
    }

    function _arr(bytes[] memory xs) internal pure returns (string memory) {
        string memory out = "[";
        for (uint256 j = 0; j < xs.length; ++j) {
            out = string(abi.encodePacked(out, '"', vm.toString(xs[j]), '"', j + 1 == xs.length ? "" : ","));
        }
        return string(abi.encodePacked(out, "]"));
    }

    function _uarr(uint256[] memory xs) internal pure returns (string memory) {
        string memory out = "[";
        for (uint256 j = 0; j < xs.length; ++j) {
            out = string(abi.encodePacked(out, '"', vm.toString(xs[j]), '"', j + 1 == xs.length ? "" : ","));
        }
        return string(abi.encodePacked(out, "]"));
    }
}
