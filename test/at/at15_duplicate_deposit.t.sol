// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-15 — DuplicateCommitment (реестр 13.3, INV-13).
///
/// Given: коммитмент X уже существует в реестре любой пары.
/// When: второй минт с тем же X — в ту же пару (даже с другим E)
///       или в другую пару актива/номинала.
/// Then: DuplicateCommitment; реестры и счётчики не изменились.
import {Receiver} from "../../src/Receiver.sol";
import {Points} from "../../src/lib/Points.sol";
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";

contract AT15_DuplicateDeposit is ATBase {
    // прямая подача минта от имени зарегистрированного приёмника
    function _mintDirect(
        address rcv, uint256 assetId, uint256 deposited,
        uint256[] memory di, bytes[] memory es, bytes[] memory xs
    ) internal {
        vm.prank(rcv);
        core.mintNotes(assetId, deposited, di, es, xs);
    }

    function test_same_pair_same_x_other_e() public {
        uint256[] memory di = new uint256[](1);
        di[0] = DI;
        uint256[] memory secs = new uint256[](1);
        secs[0] = _secretOf("at15", 0);
        address rcv = _enterUSDC(user, userKey, _depositedFor(1, DI), di, secs);

        // реестр: X существует; повторный минт той же X, но с другим E
        bytes memory x = _ptOf(secs[0]);
        bytes memory eOther = _ptOf(_secretOf("at15e", 1)); // валидная точка, иной E
        uint256 deposited = _depositedFor(1, DI);
        assertTrue(core.commitmentExists(1, DI, x), "x in pair before");
        uint256 feesBefore = core.feesAccrued(1);

        vm.prank(rcv);
        vm.expectRevert(LaserGunCore.DuplicateCommitment.selector);
        core.mintNotes(1, deposited, di, _arr(eOther), _arr(x));

        // реестры и счётчики не изменились
        assertTrue(core.commitmentExists(1, DI, x), "x still present");
        assertFalse(core.commitmentExists(1, DI, eOther), "eOther not inserted");
        assertEq(core.feesAccrued(1), feesBefore, "fees unchanged");
    }

    function test_other_asset_pair_same_x() public {
        // акт 1: X попадает в реестр пары (1, DI)
        uint256[] memory diA = new uint256[](1);
        diA[0] = DI;
        uint256[] memory secsA = new uint256[](1);
        secsA[0] = _secretOf("at15", 0);
        _enterUSDC(vm.addr(0xB151), 0xB151, _depositedFor(1, DI), diA, secsA);

        // акт 2: тот же X в ДРУГУЮ пару (актив 2, di12) — глобальный реестр бракует
        uint256 di2 = 6; // ETH 0.01 ETH: сетка di<21, d > 10×minDenom для живой комиссии
        bytes memory x = _ptOf(secsA[0]);
        bytes memory e = _ptOf(_secretOf("at15e2", 1));
        address rcv2 = _enterETH(_secretOf("at15w2", 0), di2);
        uint256 deposited2 = core.denomOf(2, di2) + 1e14; // тот же фикс-пойнт, что в _enterETH
        uint256 fees2Before = core.feesAccrued(2);

        vm.prank(rcv2);
        vm.expectRevert(LaserGunCore.DuplicateCommitment.selector);
        core.mintNotes(2, deposited2, _one(di2), _arr(e), _arr(x));

        assertFalse(core.commitmentExists(2, di2, x), "not inserted into pair2");
        assertEq(core.feesAccrued(2), fees2Before, "fees2 unchanged");
    }

    function test_other_denom_pair_same_x() public {
        // акт 1: X попадает в реестр пары (1, DI)
        uint256[] memory diA = new uint256[](1);
        diA[0] = DI;
        uint256[] memory secsA = new uint256[](1);
        secsA[0] = _secretOf("at15", 0);
        _enterUSDC(user, userKey, _depositedFor(1, DI), diA, secsA);

        // акт 2: тот же X, другой номинал того же актива
        uint256 diOther = DI + 1;
        bytes memory x = _ptOf(secsA[0]);
        bytes memory e = _ptOf(_secretOf("at15e3", 1));
        address rcv = _enterUSDC(vm.addr(0xB152), 0xB152, _depositedFor(1, diOther), _one(diOther), _oneSec(_secretOf("at15c", 0)));
        uint256 deposited = _depositedFor(1, diOther);

        vm.prank(rcv);
        vm.expectRevert(LaserGunCore.DuplicateCommitment.selector);
        core.mintNotes(1, deposited, _one(diOther), _arr(e), _arr(x));

        assertFalse(core.commitmentExists(1, diOther, x), "not inserted into other denom");
    }

    // ── хелперы ─────────────────────────────────────────────────────
    function _one(uint256 di) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = di;
    }

    function _oneSec(uint256 s) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = s;
    }

    // ── хелперы ─────────────────────────────────────────────────────
    function _arr(bytes memory b) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = b;
    }

    function _depositedFor(uint256 assetId, uint256 di) internal view returns (uint256) {
        uint256 d = core.denomOf(assetId, di);
        uint256 deposited = d + ((d * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 8; ++i) {
            uint256 f = (deposited * 10 + 9999) / 10000;
            if (d + f == deposited) break;
            deposited = d + f;
        }
        return deposited;
    }

    function _enterETH(uint256 secret, uint256 diIdx) internal returns (address rcv) {
        // ETH-ветка (8.2): value на предсказанный адрес до деплоя, затем settle.
        // depositAmount зашит в initcode: settle проверяет баланс и гонит минт.
        uint256[] memory di = new uint256[](1);
        di[0] = diIdx;
        uint256[] memory secs = new uint256[](1);
        secs[0] = secret;
        (bytes[] memory es, bytes[] memory xs) = _notePoints(secs);
        // feeIn grid-округляется вверх до кратности 1e14 (ETH_MIN_DENOM):
        // при депозите d + 1e14 комиссия ровно 1e14 — консервация сходится
        // (требуется d > 10×1e14, иначе порог 10% гасит комиссию — берём di=6)
        uint256 deposited = core.denomOf(2, diIdx) + 1e14;
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(weth), treasury, 2, deposited, di, es, xs)
        );
        bytes32 salt = keccak256(abi.encode("at15eth", di, es, xs, ++_rcvSaltNonce));
        address predicted = factory.predictAddress(salt, initcode);
        vm.deal(address(this), deposited);
        (bool ok, ) = predicted.call{value: deposited}("");
        require(ok, "seed transfer failed");
        rcv = factory.create2(salt, initcode, false);
        vm.prank(rcv);
        Receiver(payable(rcv)).settle();
    }

    function _notePoints(uint256[] memory secs)
        internal view returns (bytes[] memory es, bytes[] memory xs)
    {
        uint256 m = secs.length;
        es = new bytes[](m);
        xs = new bytes[](m);
        for (uint256 j = 0; j < m; ++j) {
            (uint256 ex, uint256 ey) = Points.mulG(
                (uint256(keccak256(abi.encode("e", secs[j]))) % (Points.N - 1)) + 1
            );
            es[j] = abi.encodePacked(ex, ey);
            xs[j] = _ptOf(secs[j]);
        }
    }

    function _seedOne(uint256 assetId, uint256 di, string memory tag) internal returns (address) {
        uint256[] memory dis = new uint256[](1);
        dis[0] = di;
        uint256[] memory secs = new uint256[](1);
        secs[0] = _secretOf(tag, 0);
        if (assetId == 1) {
            return _enterUSDC(makeAddr("at15u2"), 0xB152, _depositedFor(1, di), dis, secs);
        }
        return _enterETH(_secretOf("at15w2b", 0), di);
    }
}
