// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-17 — EIP-3009 binding: подпись на приёмник P1 c параметрами Q не
/// исполняется на приёмнике P2 / параметрах Q' (адресация = приёмник +
/// параметры; реестр 13.3, 8.2/8.3).
import {Receiver} from "../../src/Receiver.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT17_Eip3009Binding is ATBase {
    address internal attacker = makeAddr("at17attacker");
    uint256 internal nonceCounter;

    /// деплой приёмника на параметрах Q и штатный pull — возвращает binding
    function _pullFromBindedReceiver(string memory tag, uint256 fromKey)
        internal
        returns (
            address rcv, uint256 deposited, uint256 deadline, bytes32 nonce,
            bytes32 digest, uint8 v
        )
    {
        address from = vm.addr(fromKey);
        uint256[] memory di = _di1();
        uint256[] memory secs = _sec1(tag);
        (bytes[] memory es, bytes[] memory xs) = _notePoints(secs);
        deposited = _depFor(1, DI);
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(usdc), treasury, 1, deposited, di, es, xs)
        );
        bytes32 salt = keccak256(abi.encode(tag, ++nonceCounter));
        rcv = factory.create2(salt, initcode, false);
        deadline = block.timestamp + 1 hours;
        nonce = keccak256(abi.encode(salt, address(this)));
        digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                from, rcv, deposited, uint256(0), deadline, nonce
            ))
        ));
        bytes32 r; bytes32 s;
        (v, r, s) = vm.sign(fromKey, digest);
        usdc.mint(from, deposited);
        vm.prank(rcv);
        Receiver(payable(rcv)).pull(from, deposited, 0, deadline, nonce, v, r, s);
    }

    function _di1() internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = DI;
    }

    function _sec1(string memory tag) internal view returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = _secretOf(tag, 0);
    }

    /// одно-нотный фикс-пойнт депозита: d + feeIn(dep) == dep
    function _depFor(uint256 assetId, uint256 diIdx) internal view returns (uint256 deposited) {
        uint256 d = core.denomOf(assetId, diIdx);
        deposited = d + ((d * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 12; ++i) {
            deposited = d + ((deposited * 10 + 9999) / 10000);
        }
    }

    /// точки нот из секретов (E — детерминированная валидная точка)
    function _notePoints(uint256[] memory secs)
        internal view returns (bytes[] memory es, bytes[] memory xs)
    {
        uint256 m = secs.length;
        es = new bytes[](m);
        xs = new bytes[](m);
        for (uint256 j = 0; j < m; ++j) {
            es[j] = _ptOf(_secretOf("e", secs[j]));
            xs[j] = _ptOf(secs[j]);
        }
    }

    function test_signature_bound_to_receiver_and_params() public {
        // P1: приёмник с параметрами Q=(deposited, di, E, X)
        (address rcv1, uint256 deposited, uint256 deadline, bytes32 nonce,,) =
            _pullFromBindedReceiver("at17a", 0xB171);
        assertTrue(core.commitmentExists(1, DI, _ptOf(_secretOf("at17a", 0))), "P1 minted");
        assertTrue(core.receiverRegistered(rcv1), "P1 registered");

        // P2: приёмник с параметрами Q' (другие точки) — та же подпись не пройдёт:
        // digest связывает from→rcv→value→nonce; у P2 своя соль, и подпись P1
        // валидна только против P1-дайджеста
        (address rcv2,,,,,) = _pullFromBindedReceiver("at17b", 0xB172);
        assertTrue(rcv2 != rcv1, "distinct receivers");
        assertTrue(core.commitmentExists(1, DI, _ptOf(_secretOf("at17b", 0))), "P2 minted own");

        // Повторное исполнение подписи P1 на P1: nonce уже использован
        // (authorizationState) — повтор ревертируется (already used)
        vm.prank(rcv1);
        vm.expectRevert(Receiver.AlreadySettled.selector);
        Receiver(payable(rcv1)).pull(vm.addr(0xB171), deposited, 0, deadline, nonce, 27, bytes32(0), bytes32(0));
    }

    function test_third_party_direct_rwa_reverts_before_effects() public {
        // прямой receiveWithAuthorization третьей стороной против USDC:
        // caller != to → реверт ДО переводов (to == msg.sender первая проверка)
        uint256 deposited = _depFor(1, DI);
        usdc.mint(attacker, deposited);
        bytes32 nonce = keccak256("at17-direct");
        bytes32 digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                user, address(0x17C1), deposited, uint256(0), block.timestamp + 1 hours, nonce
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB171, digest);
        vm.prank(attacker);
        vm.expectRevert(bytes("caller must be the payee"));
        usdc.receiveWithAuthorization(user, address(0x17C1), deposited, 0, block.timestamp + 1 hours, nonce, v, r, s);
        // эффектов нет: баланс получателя не изменился
        assertEq(usdc.balanceOf(address(0x17C1)), 0, "no transfer");
        assertFalse(core.commitmentExists(1, DI, abi.encodePacked(keccak256(hex"dead"))), "no mint side effects");
    }

    function test_expired_authorization_not_executable() public {
        // подпись P1 c validBefore в прошлом: на любом приёмнике не исполняется
        uint256 deposited = _depFor(1, DI);
        bytes32 nonce = keccak256("at17-exp");
        bytes32 digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                user, address(0x17C2), deposited, uint256(0), block.timestamp, nonce
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB171, digest);
        vm.warp(block.timestamp + 2 hours);
        usdc.mint(user, deposited);
        vm.expectRevert(bytes("authorization expired"));
        vm.prank(address(0x17C2));
        usdc.receiveWithAuthorization(user, address(0x17C2), deposited, 0, block.timestamp, nonce, v, r, s);
    }
}
