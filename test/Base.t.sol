// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {ReceiverFactory} from "../../src/ReceiverFactory.sol";
import {Executor} from "../../src/Executor.sol";
import {Receiver} from "../../src/Receiver.sol";
import {OutputReceiver} from "../../src/OutputReceiver.sol";
import {MockUSDC, MockWETH, MockAavePool} from "./mocks/Mocks.sol";
import {Points} from "../../src/lib/Points.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";

/// @dev Общая обвязка тестов: деплой тройки (ядро → фабрика → executor),
///      моки активов и пула, казна. Криптографию трат готовит SolLSAG
///      (см. test/lib/Crypto.t.sol): точки подаются как в реальном клиенте.
contract Base is Test {
    MockUSDC internal usdc;
    MockWETH internal weth;
    MockAavePool internal pool;
    LaserGunCore internal core;
    ReceiverFactory internal factory;
    Executor internal executor;
    address internal treasury = makeAddr("treasury");
    address internal feesOwner = makeAddr("feesOwner");

    // тестовые ключи нот
    uint256 internal constant Y1 = 0xa11ce;
    uint256 internal constant Y2 = 0xb0b;

    function setUp() public virtual {
        usdc = new MockUSDC();
        weth = new MockWETH();
        pool = new MockAavePool(address(usdc), address(weth));

        // Связка тройки: адреса взаимозависимы (ядро знает фабрику и executor'а,
        // они — ядро). Разрешается фиксированной точкой: последовательные
        // пере-деплои сходятся, когда адреса перестают меняться (порядок деплоя
        // фиксирован 15.1; в проде связка задаётся константами сборки).
        // адреса связки предсказуемы: деплой по порядку nonce (ядро → фабрика
        // → executor), адреса вычисляются до деплоя (vm.computeCreateAddress)
        uint256 n = vm.getNonce(address(this));
        address cAddr = vm.computeCreateAddress(address(this), n);
        address fAddr = vm.computeCreateAddress(address(this), n + 1);
        address eAddr = vm.computeCreateAddress(address(this), n + 2);
        core = new LaserGunCore(fAddr, eAddr);
        factory = new ReceiverFactory(cAddr);
        executor = new Executor(
            cAddr, address(pool),
            address(pool.aUSDC()), address(pool.aWETH()),
            address(usdc), address(weth),
            treasury, feesOwner
        );

        // INV-20: фиксируем эталоны шаблонов (как в DeployLocal.s.sol)
        factory.setTemplateHashes(
            keccak256(type(Receiver).creationCode),
            type(Receiver).creationCode.length,
            keccak256(type(OutputReceiver).creationCode),
            type(OutputReceiver).creationCode.length
        );

        // казна должна дать allowance executor'у на aTokens (10.2)
        vm.prank(treasury);
        pool.aUSDC().approve(address(executor), type(uint256).max);
        vm.prank(treasury);
        pool.aWETH().approve(address(executor), type(uint256).max);
    }

    // ── помощники минта через приёмник (вход) ───────────────────────

    /// @notice Деплой входного приёмника фабрикой и исполнение входа USDC.
    function _enterUSDC(
        address user, uint256 deposited,
        uint256[] memory di, bytes[] memory es, bytes[] memory xs,
        uint256 userKey
    ) internal returns (address rcv, bytes32 nonce) {
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(
                address(core), address(pool), address(usdc), treasury,
                uint256(1), deposited, di, es, xs
            )
        );
        bytes32 salt = keccak256(abi.encode("salt", xs, userKey, block.number));
        rcv = factory.create2(salt, initcode, false);

        uint256 amount = deposited;
        bytes32 digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                user, rcv, amount, uint256(0), block.timestamp + 1 hours,
                keccak256(abi.encode(xs, userKey))
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        nonce = keccak256(abi.encode(xs, userKey));
        usdc.mint(user, amount);
        vm.prank(rcv);
        Receiver(payable(rcv)).pull(user, amount, 0, block.timestamp + 1 hours, nonce, v, r, s);
    }

    /// @notice Деплой приёмника вывода для владельца.
    function _deployOutputReceiver(address owner, bytes32 saltSeed) internal returns (address) {
        bytes memory initcode = abi.encodePacked(
            type(OutputReceiver).creationCode,
            abi.encode(owner, address(usdc), address(weth))
        );
        bytes32 salt = keccak256(abi.encodePacked("payout", saltSeed, owner));
        return factory.create2(salt, initcode, true);
    }

    // ── генерация точек из скаляров (валидные on-curve точки) ───────

    function _pt(uint256 scalar) internal view returns (bytes memory) {
        (uint256 x, uint256 y) = Points.mulG(scalar);
        return abi.encodePacked(x, y);
    }
}
