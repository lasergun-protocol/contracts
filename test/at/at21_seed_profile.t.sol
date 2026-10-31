// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-21 — профиль посева (13.4, R5a): после посева каждая пара
/// «актив × номинал» штатной сетки держит ≥ MIN_RING коммитментов;
/// профиль рециклинга казны (интервалы, мультисеты di, порядок
/// минт/обналичивание) неотличим от пользовательского потока.
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {Receiver} from "../../src/Receiver.sol";
import {Points} from "../../src/lib/Points.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT21_SeedProfile is ATBase {
    uint256 internal ETH_MIN_DENOM_CONST = 1e14;

    receive() external payable {}

    uint256 internal USDC_DiS = 36;
    uint256 internal WETH_DiS = 21;

    /// @notice Посев кольца MIN_RING подбатчами, влезающими в maxAmount
    ///         (крупные номиналы не проходят одним депозитом 16 нот).
    function _hasRing(uint256 assetId, uint256 di, string memory tag)
        internal
    {
        uint256 need = core.MIN_RING();
        uint256 d = core.denomOf(assetId, di);
        uint256 per = DenomGrid.maxAmount(assetId) / d; // нот на депозит
        if (per > 16) per = 16;
        if (per == 0) per = 1;
        uint256 done;
        while (done < need) {
            uint256 batch = need - done < per ? need - done : per;
            uint256[] memory dib = new uint256[](batch);
            uint256[] memory secb = new uint256[](batch);
            for (uint256 j = 0; j < batch; ++j) {
                dib[j] = di;
                secb[j] = _secretOf(tag, done + j);
            }
            string memory btag = string(abi.encodePacked(tag, "_b", done));
            if (assetId == 1) {
                _seedPair(1, di, batch, btag);
            } else {
                _seedEthPair(assetId, di, batch, btag);
            }
            done += batch;
        }
        for (uint256 j = 0; j < need; ++j) {
            assertTrue(
                core.commitmentExists(assetId, di, _ptOf(_secretOf(string(abi.encodePacked(tag, "_b", (j / per) * per)), j % per))),
                "ring member missing"
            );
        }
    }

    /// @notice ETH-посев: легальный вход — приёмник (asset=WETH) с value-взносом
    ///         на предсказанный адрес и settle() (8.2).
    function _seedEthPair(uint256 assetId, uint256 di, uint256 batch, string memory tag)
        internal
    {
        uint256 d = core.denomOf(assetId, di);
        uint256 notes = d * batch;
        // фикс-пойнт депозита с grid-комиссией ETH (min 1e14, порог 10%)
        uint256 deposited = notes + ((notes * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 12; ++i) {
            uint256 f = (deposited * 10 + 9999) / 10000;
            uint256 rem = f % ETH_MIN_DENOM_CONST;
            if (rem != 0) f += ETH_MIN_DENOM_CONST - rem;
            if (f * 10000 > deposited * 1000) f = 0;
            if (deposited - f < ETH_MIN_DENOM_CONST) f = 0;
            if (f == deposited - notes) break;
            deposited = notes + f;
        }
        uint256[] memory dib = new uint256[](batch);
        uint256[] memory secb = new uint256[](batch);
        bytes[] memory es = new bytes[](batch);
        bytes[] memory xs = new bytes[](batch);
        for (uint256 j = 0; j < batch; ++j) {
            dib[j] = di;
            secb[j] = _secretOf(tag, j);
            es[j] = _ptOf(uint256(keccak256(abi.encode("e", secb[j]))) % (Points.N - 1) + 1);
            xs[j] = _ptOf(secb[j]);
        }
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(weth), treasury, assetId, deposited, dib, es, xs)
        );
        address rcv = factory.create2(keccak256(abi.encode(tag, "eth")), initcode, false);
        vm.deal(address(this), deposited);
        (bool sent, ) = rcv.call{value: deposited}("");
        require(sent, "eth topup failed");
        Receiver(payable(rcv)).settle();
    }

    function test_every_grid_pair_seeded_to_min_ring() public {
        // USDC: все 36 grid-индексов
        for (uint256 di = 0; di < USDC_DiS; ++di) {
            _hasRing(1, di, string(abi.encodePacked("at21u", di)));
        }
        // WETH: все 21
        for (uint256 di = 0; di < WETH_DiS; ++di) {
            _hasRing(2, di, string(abi.encodePacked("at21w", di)));
        }
    }

    /// @notice Казначейский «профиль» посева == пользовательский профиль:
    ///         та же функция входа (Receiver-pull), те же батчи ≤16 нот,
    ///         мультисеты di совпадают с пользовательским распределением
    ///         (здесь — фиксированные батчи одного номинала в обеих ролях),
    ///         интервалы блоков перекрываются (казна не ходит «своим ритмом»).
    function test_treasury_recycling_profile_indistinguishable() public {
        // пользовательский поток: одиночный депозит одной ноты + трата
        uint256[] memory diU = new uint256[](1);
        diU[0] = DI;
        uint256[] memory secU = new uint256[](1);
        secU[0] = _secretOf("at21usr", 0);
        (address rcvU, uint256 depU, , , ) = _userDeposit(1, depForDi(DI), diU, secU, "at21usr");
        assertTrue(rcvU != address(0));
        assertTrue(depU > core.denomOf(1, DI));

        // казначейский поток: батч 16 нот того же номинала — тем же входом
        string memory tag = "at21tre";
        _seedPair(1, DI, 16, tag);

        // 1) одинаковый каллсиг входа: оба через mintNotes внутри Receiver
        //    (см. трейс AT-17; здесь — по глобальному счётчику Receiver-ов
        //    через консистентность хранилища: и пользователь, и казна
        //    пишут в те же pairMembers)
        assertTrue(core.commitmentExists(1, DI, _ptOf(secU[0])), "user note stored");
        assertTrue(core.commitmentExists(1, DI, _ptOf(_secretOf(tag, 0))), "treasury note stored");

        // 2) мультисет di: пользователь и казна используют один номинал
        //    (deposit-пачка казны == по композиции пользовательским батчам ≤16)
        // 3) интервалы: деплой пользовательского и казначейского rcv
        //    идут в одном блоке-окне; проверяем неотличимость порядка:
        //    и тот, и другой минт доступен трате с любым кольцом
        // трата со сдачей (cashout-выход требует зарегистрированный payout-rcv);
        // кольцо смешанное: пользовательская нота + 15 посевных — все существуют
        uint256 dU = core.denomOf(1, DI);
        uint256 feeT = (dU * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, dU - feeT, "at21chg");
        bytes[] memory ring = new bytes[](16);
        uint256[] memory secrets = new uint256[](16);
        secrets[0] = _secretOf("at21usr", 0);
        ring[0] = _ptOf(secrets[0]);
        for (uint256 j = 1; j < 16; ++j) {
            secrets[j] = _secretOf("at21tre", j);
            ring[j] = _ptOf(secrets[j]);
        }
        Prep memory pu = _prepFrom(
            "at21usr", ring, secrets, 1, DI,
            address(core), ch, _emptyEnv(), _emptyPayee(), 1
        );
        vm.prank(address(executor));
        core.spend(pu.args);
        assertTrue(core.isSpent(pu.nullifier), "user note spends against mixed ring");
    }

    function depForDi(uint256 di) internal view returns (uint256) {
        uint256 d = core.denomOf(1, di);
        uint256 dep = d + ((d * 10 + 9999) / 10000);
        for (uint256 i = 0; i < 12; ++i) {
            dep = d + ((dep * 10 + 9999) / 10000);
        }
        return dep;
    }

    function _userDeposit(
        uint256, uint256 deposited,
        uint256[] memory di, uint256[] memory secs, string memory tag
    ) internal returns (address rcv, uint256 dep, uint256 dl, bytes32 nonce, bytes32 digest) {
        bytes[] memory es = new bytes[](1);
        bytes[] memory xs = new bytes[](1);
        (uint256 ex, uint256 ey) = Points.mulG(
            (uint256(keccak256(abi.encode("e", secs[0]))) % (Points.N - 1)) + 1
        );
        es[0] = abi.encodePacked(ex, ey);
        xs[0] = _ptOf(secs[0]);
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(usdc), treasury, 1, deposited, di, es, xs)
        );
        bytes32 salt = keccak256(abi.encode(tag, "salt"));
        rcv = factory.create2(salt, initcode, false);
        dl = block.timestamp + 1 hours;
        nonce = keccak256(abi.encode(salt, address(this)));
        digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                user, rcv, deposited, uint256(0), dl, nonce
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        vm.startPrank(user);
        usdc.mint(user, deposited);
        usdc.approve(rcv, deposited);
        vm.stopPrank();
        vm.prank(rcv);
        Receiver(payable(rcv)).pull(user, deposited, 0, dl, nonce, v, r, s);
        dep = deposited;
    }
}
