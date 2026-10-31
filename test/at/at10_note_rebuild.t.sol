// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-10 — Rebuild Note из события: детерминированная реконструкция
/// ключей реестра (pairKey, commitment hash) из Minted после
/// 50 минтов / 20 трат / 10 конвертов. События — единственный публичный
/// источник точек (6.2), rebuild обязан совпадать с реестром ядра.
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {Vm} from "forge-std/Vm.sol";

contract AT10_NoteRebuild is ATBase {
    uint256 internal constant MINTS = 50;
    uint256 internal constant SPENDS = 20;
    uint256 internal constant ENVELOPES = 10;

    function test_rebuild_matches_registry() public {
        vm.recordLogs(); // включить запись событий для rebuild
        // ── генерация истории ────────────────────────────────────────
        for (uint256 i = 0; i < MINTS; ++i) {
            _seedPair(1, 20 + uint256(keccak256(abi.encode(i))) % 8, 1, string(abi.encodePacked("at10m", i)));
        }
        for (uint256 i = 0; i < SPENDS; ++i) {
            string memory tag = string(abi.encodePacked("at10s", i));
            // кэшаут на кольце 4 (INV-12 допускает n>=4): 20 полноразмерных
            // 16-членных трат не влезают в газовый бюджет одного прогона
            bytes[] memory ring = _seedPair(1, DI, 4, tag);
            uint256[] memory secs = new uint256[](4);
            for (uint256 j = 0; j < 4; ++j) secs[j] = _secretOf(tag, j);
            Prep memory p = _prepFrom(tag, ring, secs, 1, DI,
                _deployPayout(address(0xC0), keccak256(bytes(tag))),
                _emptyChange(), _emptyEnv(), _emptyPayee(), 0);
            executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        }
        for (uint256 i = 0; i < ENVELOPES; ++i) {
            string memory tag = string(abi.encodePacked("at10e", i));
            bytes32 id = keccak256(bytes(tag));
            uint256 d = core.denomOf(1, DI);
            uint256 amt = 432e6;
            uint256 fee = (d * 15 + 9999) / 10000;
            ILaserGunCore.Envelope memory env =
                _envFor(1, amt, id, block.timestamp + 1 days, false, _secretOf(tag, 0));
            ILaserGunCore.Change memory ch = _changeFor(1, d - amt - fee, string(abi.encodePacked(tag, "c")));
            _seedAndSpend(tag, 1, DI, address(core), ch, env, _emptyPayee());
        }

        // ── rebuild из событий Minted ────────────────────────────────
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rebuilt;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(core)) continue;
            if (logs[i].topics[0] != LaserGunCore.Minted.selector) continue;
            // Minted(assetId indexed, di indexed, E, X)
            uint256 assetId = uint256(logs[i].topics[1]);
            uint256 di = uint256(logs[i].topics[2]);
            (bytes memory E, bytes memory X) = abi.decode(logs[i].data, (bytes, bytes));
            // ключ реестра: pairKey(assetId, di) → commitment keccak(X)
            assertTrue(core.commitmentExists(assetId, di, X), "commitment known");
            // E — публичный эфемерник; X не выводится из E (односторонность)
            assertTrue(keccak256(E) != keccak256(X), "E distinct from X");
            ++rebuilt;
        }
        assertGt(rebuilt, MINTS + SPENDS * (1 + 1), "mints + change rebuilt");
        assertEq(core.totalNotes(), rebuilt, "totalNotes == rebuilt count");
    }

    /// @dev feeTransfer(d) локально (15 bps, grid USDC).
    function Fees_exact(uint256, uint256 d) internal pure returns (uint256) {
        return (d * 15) / 10000;
    }
}
