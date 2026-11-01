// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, console2 } from "forge-std/Test.sol";

interface ISpend {
    function spend(bytes calldata) external;
}

contract SpendRepro is Test {
    function test_repro() external {
        // отладочный репро: требует внешний артефакт inner-calldata.txt
        // (дамп каллдаты падающей траты). Без него — skip, не fail.
        if (!vm.exists("inner-calldata.txt")) {
            vm.skip(true);
        }
        string memory data = vm.readFile("inner-calldata.txt");
        bytes memory cd = vm.parseBytes(data);
        address core = vm.envOr("CORE", address(0));
        address executor = vm.envOr("EXECUTOR", address(0));
        vm.prank(executor);
        (bool ok, bytes memory ret) = core.call(cd);
        if (!ok) {
            // печатаем возвращённые данные ошибки (если есть)
            console2.log("revert data len:", ret.length);
            if (ret.length >= 4) console2.logBytes4(bytes4(ret));
            if (ret.length > 4) console2.logBytes(ret);
        }
        assertTrue(ok, "core.spend reverted");
    }
}
