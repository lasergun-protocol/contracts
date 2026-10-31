// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ATBase} from "./lib/ATBase.sol";
import {ILaserGunCore} from "../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../src/LaserGunCore.sol";

/// AT-3 — отсутствие привилегированных путей (G3): ни паузы, ни апгрейда,
/// ни ролей, ни admin-изъятия; только executor тратит (NotExecutor прочим).
contract AT3_NoPrivileges is ATBase {
    function test_admin_selectors_absent() public view {
        // селекторы типовых admin-функций не должны существовать в ABI ядра
        bytes4[8] memory banned = [
            bytes4(keccak256("pause()")),
            bytes4(keccak256("unpause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("setFee(uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("emergencyWithdraw(address,uint256)")),
            bytes4(keccak256("setTreasury(address)")),
            bytes4(keccak256("owner()"))
        ];
        for (uint256 i = 0; i < 8; ++i) {
            (bool ok, ) = address(executor).staticcall(abi.encodePacked(banned[i], bytes32(0)));
            assertTrue(!ok, "admin selector exists");
        }
    }

    function test_no_eip1967_slots() public view {
        // прокси-слоты пусты: impl/admin/ beacon
        bytes32 impl = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 adm = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        assertEq(vm.load(address(executor), impl), bytes32(0));
        assertEq(vm.load(address(executor), adm), bytes32(0));
    }

    function test_only_executor_spends() public {
        // любой не-executor не может подать трату — NotExecutor
        bytes[] memory ring = _seedPair(1, 27, N16, "at3");
        uint256[] memory secrets = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) secrets[j] = _secretOf("at3", j);
        uint256 d = core.denomOf(1, 27);
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - fee, "at3ch");
        Prep memory p = _prep("at3", 1, 27, address(core), ch, _emptyEnv(), _emptyPayee(), 0);
        vm.prank(user);
        vm.expectRevert(LaserGunCore.NotExecutor.selector);
        core.spend(p.args);
        vm.prank(treasury);
        vm.expectRevert(LaserGunCore.NotExecutor.selector);
        core.spend(p.args);
        // легальный путь работает
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        assertTrue(core.isSpent(p.nullifier));
    }

    function test_treasury_cannot_touch_notes() public {
        // казна не может ни минтовать напрямую, ни тратить, ни изымать
        uint256[] memory di = new uint256[](1);
        di[0] = 27;
        bytes[] memory es = new bytes[](1);
        bytes[] memory xs = new bytes[](1);
        es[0] = _ptOf(_secretOf("at3t", 0));
        xs[0] = _ptOf(_secretOf("at3t", 1));
        vm.prank(treasury);
        vm.expectRevert(LaserGunCore.UnregisteredReceiver.selector);
        core.mintNotes(1, 1001, di, es, xs);
    }
}
