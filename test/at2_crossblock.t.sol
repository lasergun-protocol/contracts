// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ATBase} from "./lib/ATBase.sol";
import {console2} from "forge-std/console2.sol";
import {ILaserGunCore} from "../src/interfaces/ILaserGunCore.sol";

/// AT-2 — трата в B+1/B+2/B+100/B+1000 (G2): верификация — чистая функция
/// от (кольцо, I, M, сигнатура), не читает блочный контекст.
contract AT2_Crossblock is ATBase {
    string constant TAG = "at2";

    function test_spends_in_later_blocks() public {
        bytes[] memory ring = _seedPair(1, DI, N16, TAG);
        uint256[] memory secrets = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) secrets[j] = _secretOf(TAG, j);

        uint256 startBlock = block.number;
        uint256[4] memory offsets = [uint256(1), 2, 100, 1000];
        // d = 1000 USDC; feeTransfer(15bps, grid) = 1.5; сдача 998.5 → core
        uint256 d = core.denomOf(1, DI);
        uint256 fee = (d * 15 + 9999) / 10000; // grid-кратно 1 (USDC)
        uint256 changeSum = d - fee;
        for (uint256 k = 0; k < 4; ++k) {
            vm.roll(startBlock + offsets[k]);
            ILaserGunCore.Change memory ch = _changeFor(1, changeSum, string(abi.encodePacked(TAG, k)));
            Prep memory p = _prep(TAG, 1, DI, address(core), ch, _emptyEnv(), _emptyPayee(), k);
            executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
            assertTrue(core.isSpent(p.nullifier), "spend failed in B+k");
        }
    }

    function test_message_hash_block_independent() public {
        // M не зависит от блока: одно и то же сообщение до/после ролла
        bytes32 m1 = _mHash(1, DI, address(executor), _emptyChange(), _emptyEnv(), _emptyPayee());
        vm.roll(block.number + 1000);
        bytes32 m2 = _mHash(1, DI, address(executor), _emptyChange(), _emptyEnv(), _emptyPayee());
        assertEq(m1, m2, "M depends on block");
    }
}
