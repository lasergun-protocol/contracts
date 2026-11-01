// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ILaserGunCore, EnvelopeState} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {Executor} from "../../src/Executor.sol";
import {ReceiverFactory} from "../../src/ReceiverFactory.sol";
import {Receiver} from "../../src/Receiver.sol";
import {OutputReceiver} from "../../src/OutputReceiver.sol";
import {MockUSDC, MockWETH, MockAavePool, MockAToken} from "../mocks/Mocks.sol";
import {Points} from "../../src/lib/Points.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {SolLSAG} from "./SolLSAG.sol";
import {Fees} from "../../src/lib/Fees.sol";

/// @dev Общий контур adversarial-тестов AT-1…AT-25: та же связка, что Base,
///      плюс конструктор трат SpendArgs через тестового подписанта SolLSAG.
abstract contract ATBase is Test {
    MockUSDC internal usdc;
    MockWETH internal weth;
    MockAavePool internal pool;
    LaserGunCore internal core;
    ReceiverFactory internal factory;
    Executor internal executor;
    address internal treasury = makeAddr("treasury");
    address internal feesOwner = makeAddr("feesOwner");
    uint256 internal _rcvSaltNonce;
    uint256 internal userKey = 0xA11CE;
    address internal user;

    uint256 internal constant N16 = 16;

    function setUp() public virtual {
        user = vm.addr(userKey);
        usdc = new MockUSDC();
        weth = new MockWETH();
        pool = new MockAavePool(address(usdc), address(weth));

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

        // INV-20: фиксируем эталоны шаблонов (как в Base.t.sol/DeployLocal)
        factory.setTemplateHashes(
            keccak256(type(Receiver).creationCode),
            type(Receiver).creationCode.length,
            keccak256(type(OutputReceiver).creationCode),
            type(OutputReceiver).creationCode.length
        );

        // через типизированные переменные: связка «доступ-к-иммутабелю + вызов»
        // в via-IR может искажать каллдату цепочки
        MockAToken aU = pool.aUSDC();
        MockAToken aW = pool.aWETH();
        vm.prank(treasury);
        aU.approve(address(executor), type(uint256).max);
        vm.prank(treasury);
        aW.approve(address(executor), type(uint256).max);
    }

    // ── точки/секреты ────────────────────────────────────────────────
    function _secretOf(string memory tag, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(tag, i))) % Points.N;
    }

    function _ptOf(uint256 scalar) internal view returns (bytes memory) {
        (uint256 x, uint256 y) = Points.mulG(scalar);
        return abi.encodePacked(x, y);
    }

    // ── вход (легальный путь через приёмник) ─────────────────────────
    /// @param secrets секреты нот пачки; di параллелен
    function _enterUSDC(
        address from, uint256 fromKey, uint256 deposited,
        uint256[] memory di, uint256[] memory secrets
    ) internal returns (address rcv) {
        uint256 m = di.length;
        bytes[] memory es = new bytes[](m);
        bytes[] memory xs = new bytes[](m);
        for (uint256 j = 0; j < m; ++j) {
            (uint256 ex, uint256 ey) = Points.mulG(
                (uint256(keccak256(abi.encode("e", secrets[j]))) % (Points.N - 1)) + 1
            );
            es[j] = abi.encodePacked(ex, ey);
            xs[j] = _ptOf(secrets[j]);
        }
        return _deployAndPull(from, fromKey, 1, deposited, di, es, xs);
    }

    function _deployAndPull(
        address from, uint256 fromKey, uint256 assetId, uint256 deposited,
        uint256[] memory di, bytes[] memory es, bytes[] memory xs
    ) internal returns (address rcv) {
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(usdc), treasury, assetId, deposited, di, es, xs)
        );
        // счётчик в соли: повторные посевы одной пары в одном блоке
        // (50+ минтов в AT-10) не должны коллидировать по CREATE2
        bytes32 salt = keccak256(abi.encode("at", di, es, xs, from, block.number, ++_rcvSaltNonce));
        rcv = factory.create2(salt, initcode, false);
        // nonce пермишлеса уникален на каждый вызов (EIP-3009: повтор
        // authorization запрещён) — считаем от той же соли
        bytes32 nonce = keccak256(abi.encode("at", di, es, xs, from, block.number, _rcvSaltNonce));
        bytes32 digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            usdc.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                usdc.RECEIVE_WITH_AUTH_TYPE(),
                from, rcv, deposited, uint256(0), block.timestamp + 1 hours, nonce
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromKey, digest);
        usdc.mint(from, deposited);
        vm.prank(rcv);
        Receiver(payable(rcv)).pull(from, deposited, 0, block.timestamp + 1 hours, nonce, v, r, s);
    }

    function _deployPayout(address owner, bytes32 saltSeed) internal returns (address) {
        bytes memory initcode = abi.encodePacked(
            type(OutputReceiver).creationCode,
            abi.encode(owner, address(usdc), address(weth))
        );
        bytes32 salt = keccak256(abi.encodePacked("payout", saltSeed, owner));
        return factory.create2(salt, initcode, true);
    }

    // ── построение траты ─────────────────────────────────────────────
    struct Prep {
        ILaserGunCore.SpendArgs args;
        uint256 pi;
        uint256 secret;
        bytes32 nullifier;
        bytes[] ring;
        bytes[] hp;
    }

    /// @notice Полная легальная трата-подготовка: кольцо из seed-тега + тратимая
    ///         нота. requireExisting — члены должны быть в реестре (по умолчанию).
    function _prep(
        string memory tag,
        uint256 assetId, uint256 di,
        address recipient,
        ILaserGunCore.Change memory change, ILaserGunCore.Envelope memory env, ILaserGunCore.Payee memory payee,
        uint256 pi
    ) internal view returns (Prep memory p) {
        // кольцо: 16 членов тега (все зарегистрированы посевом)
        bytes[] memory ring = new bytes[](N16);
        uint256[] memory secrets = new uint256[](N16);
        for (uint256 j = 0; j < N16; ++j) {
            secrets[j] = _secretOf(tag, j);
            ring[j] = _ptOf(secrets[j]);
        }
        p = _prepFrom(tag, ring, secrets, assetId, di, recipient, change, env, payee, pi);
    }

    /// @notice Трата-подготовка из готового кольца (позиция pi = тратимая).
    function _prepFrom(
        string memory, // tag (для совместимости)
        bytes[] memory ring,
        uint256[] memory secrets,
        uint256 assetId, uint256 di,
        address recipient,
        ILaserGunCore.Change memory change, ILaserGunCore.Envelope memory env, ILaserGunCore.Payee memory payee,
        uint256 pi
    ) internal view returns (Prep memory p) {
        require(secrets.length == ring.length && pi < ring.length);
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        ILaserGunCore.SpendArgs memory a;
        a.assetId = assetId;
        a.di = di;
        a.recipient = recipient;
        a.ring = ring;
        a.hp = hp;
        a.change = change;
        a.env = env;
        a.payee = payee;
        bytes32 mHash = _mHash(assetId, di, recipient, change, env, payee);
        (bytes32 c1, uint256[] memory s, bytes memory I) =
            SolLSAG.sign(mHash, ring, pi, secrets[pi], hp);
        a.I = I;
        a.c1 = c1;
        a.s = s;
        p.args = a;
        p.pi = pi;
        p.secret = secrets[pi];
        p.nullifier = keccak256(I);
        p.ring = ring;
        p.hp = hp;
    }

    /// @notice M ядра — тот же расчёт (дубль messageHash).
    function _mHash(
        uint256 assetId, uint256 di, address recipient,
        ILaserGunCore.Change memory change, ILaserGunCore.Envelope memory env, ILaserGunCore.Payee memory payee
    ) internal view returns (bytes32) {
        bool hasChange = change.di.length > 0;
        bool hasEnv = env.di.length > 0;
        bool hasPayee = payee.di.length > 0;
        bytes32 hc = hasChange ? keccak256(abi.encode(change)) : bytes32(0);
        bytes32 he = hasEnv ? keccak256(abi.encode(env)) : bytes32(0);
        bytes32 hpp = hasPayee ? keccak256(abi.encode(payee)) : bytes32(0);
        return keccak256(abi.encodePacked(
            bytes5("LG2-w"), bytes32(assetId), bytes32(di), bytes20(recipient),
            bytes32(block.chainid), hc, he, hpp
        ));
    }

    // ── конструкторы блоков выхода ───────────────────────────────────
    /// @notice Разложение суммы по сетке {1,3,5}×10^k в change-батч
    ///         (неканоническое допустимо; секрета — по тегу).
    function _changeFor(uint256 assetId, uint256 amount, string memory tag)
        internal view returns (ILaserGunCore.Change memory)
    {
        uint256[36] memory dis;
        uint256 count;
        // значения grid-номиналов сверху вниз
        for (int256 idx = 35; idx >= 0 && amount > 0; --idx) {
            uint256 v = DenomGrid.denomOf(assetId, uint256(idx));
            if (v > amount) continue;
            uint256 q = amount / v;
            if (q > 3) q = 3; // до 3 нот на разряд
            for (uint256 t = 0; t < q && amount > 0; ++t) {
                dis[count++] = uint256(idx);
                amount -= v;
            }
        }
        require(amount == 0, "change decomposition failed");
        uint256[] memory diArr = new uint256[](count);
        uint256[] memory secs = new uint256[](count);
        for (uint256 j = 0; j < count; ++j) {
            diArr[j] = dis[j];
            secs[j] = _secretOf(tag, j);
        }
        return _batchOf(diArr, secs);
    }

    function _emptyChange() internal pure returns (ILaserGunCore.Change memory c) {
        c.di = new uint256[](0);
        c.E = new bytes[](0);
        c.X = new bytes[](0);
    }

    function _emptyEnv() internal pure returns (ILaserGunCore.Envelope memory e) {
        e.id = bytes32(0);
        e.di = new uint256[](0);
        e.E_r = new bytes(0);
        e.X_r = new bytes(0);
        e.E_s = new bytes(0);
        e.X_s = new bytes(0);
    }

    function _emptyPayee() internal pure returns (ILaserGunCore.Payee memory p) {
        p.di = new uint256[](0);
        p.E = new bytes[](0);
        p.X = new bytes[](0);
    }

    function _batchOf(uint256[] memory di, uint256[] memory secrets)
        internal view returns (ILaserGunCore.Change memory)
    {
        ILaserGunCore.Change memory c;
        uint256 m = di.length;
        c.di = di;
        c.E = new bytes[](m);
        c.X = new bytes[](m);
        for (uint256 j = 0; j < m; ++j) {
            (uint256 ex, uint256 ey) = Points.mulG(
                (uint256(keccak256(abi.encode("ce", secrets[j]))) % (Points.N - 1)) + 1
            );
            c.E[j] = abi.encodePacked(ex, ey);
            c.X[j] = _ptOf(secrets[j]);
        }
        return c;
    }


    // ── группы сценариев для повторного использования ────────────────
    uint256 internal constant DI = 27; // номинал 1000 USDC (3×27: 10^(27/3))

    /// @notice Посев + подготовка траты di; опционально исполнитель.
    function _seedAndPrep(
        string memory tag, uint256 assetId, uint256 di, address recipient,
        ILaserGunCore.Change memory change, ILaserGunCore.Envelope memory env,
        ILaserGunCore.Payee memory payee, uint256 pi
    ) internal returns (Prep memory p) {
        _seedPair(assetId, di, N16, tag);
        p = _prep(tag, assetId, di, recipient, change, env, payee, pi);
    }

    function _seedAndSpend(
        string memory tag, uint256 assetId, uint256 di, address recipient,
        ILaserGunCore.Change memory change, ILaserGunCore.Envelope memory env,
        ILaserGunCore.Payee memory payee
    ) internal returns (Prep memory p) {
        p = _seedAndPrep(tag, assetId, di, recipient, change, env, payee, 7);
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        return p;
    }

    /// @notice Простая обналичивающая трата: recipient=payout, без сдачи.
    function _cashoutSpend(string memory tag, address payoutRcv)
        internal returns (Prep memory p)
    {
        p = _seedAndPrep(tag, 1, DI, payoutRcv, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        return p;
    }

    /// @notice Подпись по готовым точкам (для AT-5, where ring уже посажен).
    function _signFor(
        bytes[] memory ring, uint256[] memory secrets, uint256 pi,
        uint256 assetId, uint256 di, address recipient,
        ILaserGunCore.Change memory change, ILaserGunCore.Envelope memory env,
        ILaserGunCore.Payee memory payee
    ) internal view returns (bytes32 c1, uint256[] memory s, bytes memory I) {
        bytes[] memory hp = SolLSAG.hpForAll(ring);
        bytes32 mHash = _mHash(assetId, di, recipient, change, env, payee);
        return SolLSAG.sign(mHash, ring, pi, secrets[pi], hp);
    }

    function _signArgs(
        ILaserGunCore.SpendArgs memory a, uint256 pi, uint256 secret
    ) internal view returns (bytes32, uint256[] memory, bytes memory) {
        bytes[] memory hp = SolLSAG.hpForAll(a.ring);
        bytes32 mHash = _mHash(a.assetId, a.di, a.recipient, a.change, a.env, a.payee);
        return SolLSAG.sign(mHash, a.ring, pi, secret, hp);
    }

    function _feeTransfer(uint256 d) internal pure returns (uint256) {
        return (d * 15 + 9999) / 10000;
    }


    // ── конверты: сборка env-блока траты ─────────────────────────────
    /// @notice env-блок с разложением amount по сетке; X_r/X_s из секретов.
    function _envFor(
        uint256 assetId, uint256 amount, bytes32 id, uint256 expiry,
        bool permitRequired, uint256 senderSecret
    ) internal view returns (ILaserGunCore.Envelope memory e) {
        e.id = id;
        e.assetId = assetId;
        e.expiry = expiry;
        e.permitRequired = permitRequired;
        ILaserGunCore.Change memory d = _changeFor(assetId, amount, string(abi.encodePacked(id)));
        e.di = d.di;
        // X_r — базис получателя: ноты выводятся X_j = X_r + h_j·G (6.1)
        uint256 recvSecret = uint256(keccak256(abi.encodePacked(id, "recv"))) % Points.N;
        (uint256 rxx, uint256 rxy) = Points.mulG(recvSecret);
        e.X_r = abi.encodePacked(rxx, rxy);
        // E_r — эфемерная точка ветки получателя
        (uint256 erx, uint256 ery) = Points.mulG(
            (uint256(keccak256(abi.encodePacked(id, "er"))) % (Points.N - 1)) + 1
        );
        e.E_r = abi.encodePacked(erx, ery);
        // X_s/E_s — базис отправителя (refund)
        (uint256 sx, uint256 sy) = Points.mulG(senderSecret);
        e.X_s = abi.encodePacked(sx, sy);
        (uint256 esx, uint256 esy) = Points.mulG(
            (uint256(keccak256(abi.encodePacked(id, "es"))) % (Points.N - 1)) + 1
        );
        e.E_s = abi.encodePacked(esx, esy);
    }

    /// @notice Секрет получателя конверта (для rebuild/claim-расчётов).
    function _recvSecretOf(bytes32 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(id, "recv"))) % Points.N;
    }

    /// @notice X_j конвертной ноты по формуле размножения 6.1.
    function _envNoteX(bytes memory XBase, bytes32 id, uint256 j)
        internal view returns (bytes memory)
    {
        (uint256 bx, uint256 by) = Points.decode(XBase);
        uint256 h = Points.modN(keccak256(abi.encodePacked(bytes5("LG2-e"), id, uint256(j))));
        (uint256 gx, uint256 gy) = Points.mulG(h);
        (uint256 xj, uint256 yj) = Points.ecAdd(bx, by, gx, gy);
        return abi.encodePacked(xj, yj);
    }

    // ── посев колец: легальный вход посевных нот (как казна, 10.3) ────
    /// @notice Минт count нот номинала di в пару (assetId, di) через приёмники
    ///         (тем же путём, что пользователи — 10.3), секреты — по тегу.
    function _seedPair(uint256 assetId, uint256 di, uint256 count, string memory tag)
        internal returns (bytes[] memory ring)
    {
        uint256 d = DenomGrid.denomOf(assetId, di);
        uint256 done;
        ring = new bytes[](count);
        while (done < count) {
            uint256 batch = count - done < 16 ? count - done : 16;
            uint256[] memory diBatch = new uint256[](batch);
            uint256[] memory secBatch = new uint256[](batch);
            for (uint256 j = 0; j < batch; ++j) {
                diBatch[j] = di;
                secBatch[j] = _secretOf(tag, done + j);
                ring[done + j] = _ptOf(secBatch[j]);
            }
            uint256 notes = d * batch;
            // deposited = notes + feeIn(deposited): итерация до фикспоинта
            uint256 fee = (notes * 10 + 9999) / 10000;
            uint256 deposited = notes + fee;
            for (uint256 it = 0; it < 8; ++it) {
                uint256 f2 = (deposited * 10 + 9999) / 10000; // USDC: minDenom=1, без grid-сдвига
                if (f2 == deposited - notes) break;
                deposited = notes + f2;
            }
            _enterUSDC(user, userKey, deposited, diBatch, secBatch);
            done += batch;
        }
    }

    /// @notice Трата-обналичивание через executor (легальный путь вывода).
    function _cashout(Prep memory p, address payoutRcv) internal {
        vm.prank(payoutRcv == address(0) ? user : address(0)); // не влияет: spend пускает только executor
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (p.args)));
    }
}
