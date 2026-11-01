// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {LaserGunCore} from "../src/LaserGunCore.sol";
import {Executor} from "../src/Executor.sol";
import {ReceiverFactory} from "../src/ReceiverFactory.sol";
import {MockUSDC, MockWETH, MockAavePool} from "../test/mocks/Mocks.sol";

contract DeployLocal is Script {
    function run() external {
        uint256 pk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        vm.startBroadcast(pk);
        MockUSDC usdc = new MockUSDC();
        MockWETH weth = new MockWETH();
        MockAavePool pool = new MockAavePool(address(usdc), address(weth));

        address deployer = vm.addr(pk);
        uint256 nc = vm.getNonce(deployer);
        address cAddr = vm.computeCreateAddress(deployer, nc);
        address fAddr = vm.computeCreateAddress(deployer, nc + 1);
        address eAddr = vm.computeCreateAddress(deployer, nc + 2);

        LaserGunCore core = new LaserGunCore(fAddr, eAddr);
        ReceiverFactory factory = new ReceiverFactory(cAddr);
        Executor executor = new Executor(
            cAddr, address(pool),
            address(pool.aUSDC()), address(pool.aWETH()),
            address(usdc), address(weth),
            deployer, deployer
        );
        require(address(core) == cAddr, "core addr mismatch");

        // mint тестовых активов первому аккаунту (в broadcast: mutation)
        usdc.mint(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 1_000_000e6);
        weth.deposit{value: 1000 ether}();
        weth.transfer(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 1000 ether);
        vm.stopBroadcast();

        // печать адресов в машинно-читаемом виде
        _print("USDC", address(usdc));
        _print("WETH", address(weth));
        _print("POOL", address(pool));
        _print("CORE", address(core));
        _print("FACTORY", fAddr);
        _print("EXECUTOR", address(executor));
    }

    function _print(string memory k, address v) internal {
        bytes memory out = abi.encodePacked(k, "=", _toHex(abi.encodePacked(v)), "\n");
        assembly { log0(add(out, 32), mload(out)) }
    }

    function _toHex(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0"; str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
