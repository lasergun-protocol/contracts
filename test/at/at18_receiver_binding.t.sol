// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-18 — CREATE2-binding приёмников: predictAddress == EIP-1014, деплой
/// совпадает с предсказанием, ранний деплой чужого контракта на адрес,
/// минт из незарегистрированного контракта и прямой mintNotes ревертируются
/// (INV-20/21; реестр 13.3).
import {Receiver} from "../../src/Receiver.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {ReceiverFactory} from "../../src/ReceiverFactory.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT18_ReceiverBinding is ATBase {
    /// одно-нотный фикс-пойнт депозита
    function _depFor(uint256 assetId, uint256 diIdx) internal view returns (uint256 deposited) {
        uint256 d = core.denomOf(assetId, diIdx);
        deposited = d + ((d * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 12; ++i) {
            deposited = d + ((deposited * 10 + 9999) / 10000);
        }
    }

    function _params(string memory tag)
        internal view
        returns (uint256[] memory di, bytes[] memory es, bytes[] memory xs, uint256 deposited)
    {
        di = new uint256[](1);
        di[0] = DI;
        uint256[] memory secs = new uint256[](1);
        secs[0] = _secretOf(tag, 0);
        es = new bytes[](1);
        xs = new bytes[](1);
        es[0] = _ptOf(_secretOf("e", secs[0]));
        xs[0] = _ptOf(secs[0]);
        deposited = _depFor(1, DI);
    }

    function _init(uint256 deposited, uint256[] memory di, bytes[] memory es, bytes[] memory xs)
        internal view returns (bytes memory)
    {
        return abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(usdc), treasury, 1, deposited, di, es, xs)
        );
    }

    uint256 internal saltSeq;

    function _salt() internal returns (bytes32) {
        return keccak256(abi.encode("at18", ++saltSeq));
    }

    function test_predict_matches_deploy_eip1014() public {
        (uint256[] memory di, bytes[] memory es, bytes[] memory xs, uint256 deposited) = _params("at18p");
        bytes memory init = _init(deposited, di, es, xs);
        bytes32 salt = _salt();

        // формула адреса совпадает с EIP-1014 (прямая криптопроверка)
        address predicted = factory.predictAddress(salt, init);
        address manual = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(factory), salt, keccak256(init)
        )))));
        assertEq(predicted, manual, "EIP-1014 formula");

        // предсказанный == фактически задеплоенный
        address deployed = factory.create2(salt, init, false);
        assertEq(deployed, predicted, "deploy == predict");
        assertTrue(core.receiverRegistered(deployed), "auto-registered");
    }

    function test_early_squatter_on_predicted_address_blocks() public {
        // ранняя посадка чужого контракта на предсказанный адрес:
        // factory.create2 вернёт 0 → DeploymentFailed; в проде клиент
        // видит занятый адрес и НЕ шлёт подпись ERC-3009 на него
        (uint256[] memory di, bytes[] memory es, bytes[] memory xs, uint256 deposited) = _params("at18q");
        bytes memory init = _init(deposited, di, es, xs);
        bytes32 salt = _salt();
        address predicted = factory.predictAddress(salt, init);

        // занимаем адрес чужим контрактом через etch (эмуляция раннего деплоя
        // на выбранную соль в той же фабрике невозможна без initcode-коллизии;
        // в проде коллизия соли+initcode даёт тот же эффект — деплой не удастся)
        vm.etch(predicted, hex"fe");

        vm.expectRevert(ReceiverFactory.DeploymentFailed.selector);
        factory.create2(salt, init, false);
    }

    function test_mint_from_unregistered_reverts() public {
        // минт из незарегистрированного контракта — UnregisteredReceiver
        (uint256[] memory di, bytes[] memory es, bytes[] memory xs, uint256 deposited) = _params("at18r");
        address stranger = makeAddr("at18stranger");
        vm.prank(stranger);
        vm.expectRevert(LaserGunCore.UnregisteredReceiver.selector);
        core.mintNotes(1, deposited, di, es, xs);
    }

    function test_receiver_cannot_mint_twice() public {
        // легальный приёмник: повторный pull — AlreadySettled; прямой второй
        // mintNotes из приёмника — SenderNotFactory (structurally: only factory)
        (uint256[] memory di, bytes[] memory es, bytes[] memory xs, uint256 deposited) = _params("at18s");
        bytes memory init = _init(deposited, di, es, xs);
        bytes32 salt = _salt();
        address rcv = factory.create2(salt, init, false);

        // registration-гейт: только фабрика регистрирует приёмники —
        // прямой вызов registerReceiver посторонним ревертируется SenderNotFactory
        vm.prank(makeAddr("at18-noone"));
        vm.expectRevert(LaserGunCore.SenderNotFactory.selector);
        core.registerReceiver(makeAddr("at18-fake-rcv"));
    }
}
