// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ILaserGunCore, EnvelopeState} from "./interfaces/ILaserGunCore.sol";
import {Points} from "./lib/Points.sol";
import {LSAG} from "./lib/LSAG.sol";
import {DenomGrid} from "./lib/DenomGrid.sol";
import {Fees} from "./lib/Fees.sol";

/// @title LaserGunCore
/// @notice Нотный реестр протокола LaserGun Core v2 (раздел 11 ТЗ): минт,
///          трата LSAG, конверты. Ядро не знает ни о Aave, ни о токенах,
///          не делает внешних вызовов кроме precompile 0x06/0x07 (INV-11),
///          не имеет owner, ролей, паузы, апгрейда (INV-5) и не двигает
///          базовые активы вовсе (INV-6).
/// @dev Адреса фабрики и executor'а — иммутабельные константы сборки (15.1):
///      контракт деплоится без конструктора-параметров; связки фиксируются
///      при деплое фиксированным порядком (ядро → фабрика → executor).
contract LaserGunCore is ILaserGunCore {
    using DenomGrid for uint256;

    // ── константы схемы (таблица 6 ТЗ) ─────────────────────────────
    uint256 public constant MAX_NOTES_PER_MINT = 64;
    uint256 public constant MIN_RING = 16;
    uint256 public constant MAX_RING = 64;
    uint256 public constant MAX_EXPIRY = 30 days;
    string public constant DOMAIN_W = "LG2-w";
    string public constant DOMAIN_E = "LG2-e";
    string public constant DOMAIN_P = "LG2-p";

    // ── адреса связок: деплоятся фиксированно (ядро знает их константами) ──
    address public immutable factory;
    address public immutable executor;

    // ── хранилище (11.2) ───────────────────────────────────────────
    /// глобальный реестр существования коммитментов: хэш точки → признак
    mapping(bytes32 => bool) public commitmentKnown;
    /// per-парные реестры членства (хэш точки → признак) — опора колец
    mapping(uint256 => mapping(bytes32 => bool)) internal pairMembers;
    /// реестр потраченных: nullifier → (payload-хэш, recipient, amount)
    mapping(bytes32 => bytes32) internal spentPayload;
    mapping(bytes32 => address) internal spentRecipient;
    mapping(bytes32 => uint256) internal spentAmount;
    /// эскроу-реестр конвертов
    mapping(bytes32 => EnvelopeState) internal envelopes;
    /// приёмники входа и вывода
    mapping(address => bool) public receiverRegistered;
    mapping(address => bool) public payoutReceiverRegistered;
    /// счётчики комиссий по активам
    mapping(uint256 => uint256) public feesAccrued;

    uint256 public totalNotes;

    // ── ошибки (реестр 11.2, текст байт-в-байт по 13.3) ────────────
    error UnknownAsset();
    error UnknownDenom();
    error InvalidPoint();
    error UnknownCommitment();
    error RingTooSmall();
    error RingTooLarge();
    error InvalidSignature();
    error NullifierSpent();
    error DuplicateCommitment();
    error DuplicateRingMember();
    error InvalidRecipient();
    error ChangeMismatch();
    error EnvelopeNotFound();
    error EnvelopeClosed();
    error ClaimWindowEmpty();
    error ClaimWindowClosed();
    error RefundWindowClosed();
    error ClaimPermissionInvalid();
    error ExpiryTooLong();
    error EnvelopeTooLarge();
    error EnvelopeAssetMismatch();
    error BatchTooLarge();
    error UnregisteredReceiver();
    error SenderNotFactory();
    error NotExecutor();
    error FeeMismatch();
    error FeeCapExceeded();
    error NotFeeOwner();
    error InsufficientFees();
    error AmountTooLarge();
    error PayeeMismatch();

    // ── события (11.2) ─────────────────────────────────────────────
    event Minted(uint256 indexed assetId, uint256 indexed di, bytes E, bytes X);
    event Spent(
        uint256 indexed assetId, uint256 indexed di, address indexed recipient,
        bytes32 nullifier, uint256 ringSize, bytes32 envelopeId
    );
    event DuplicateSpend(bytes32 indexed nullifier, bytes32 payloadHash);
    event EnvelopeOpened(
        bytes32 indexed id, uint256 assetId, uint256[] di, bool permitRequired,
        bytes E_r, bytes X_r, bytes E_s, bytes X_s, uint256 expiry
    );
    event EnvelopeClaimed(bytes32 indexed id, bytes X_r);
    event EnvelopeRefunded(bytes32 indexed id, bytes X_s);
    event ReceiverRegistered(address indexed receiver);
    event PayoutReceiverRegistered(address indexed receiver);

    /// @notice Проверка констант комиссий в конструкторе без параметров (INV-7).
    constructor(address factory_, address executor_) {
        if (
            Fees.FEE_IN_BPS > Fees.FEE_CAP_BPS
                || Fees.FEE_TRANSFER_BPS > Fees.FEE_CAP_BPS
                || Fees.FEE_OUT_BPS > Fees.FEE_CAP_BPS
        ) revert FeeCapExceeded();
        if (factory_ == address(0) || executor_ == address(0)) revert InvalidRecipient();
        factory = factory_;
        executor = executor_;
    }

    // ═══════════════════════════ МИНТ ═══════════════════════════════

    /// @inheritdoc ILaserGunCore
    function mintNotes(
        uint256 assetId, uint256 deposited, uint256[] calldata di,
        bytes[] calldata E, bytes[] calldata X
    ) external {
        if (!receiverRegistered[msg.sender]) revert UnregisteredReceiver();
        if (assetId != 1 && assetId != 2) revert UnknownAsset();
        uint256 m = di.length;
        if (E.length != m || X.length != m) revert InvalidPoint();
        if (m == 0 || m > MAX_NOTES_PER_MINT) revert BatchTooLarge();

        // консервация ввода: сумма di == deposited − feeIn(deposited) (6.7)
        uint256 minDenom_ = assetId.minDenom();
        uint256 fee = Fees.feeIn(assetId, deposited, minDenom_);
        uint256 notes = DenomGrid.sumOf(assetId, di);
        if (notes != deposited - fee) revert FeeMismatch();
        // суммы сверх декомпозируемого потолка невозможны (5.3)
        if (deposited > DenomGrid.maxAmount(assetId) + fee) revert AmountTooLarge();

        feesAccrued[assetId] += fee;

        for (uint256 j = 0; j < m; ++j) {
            _insertCommitment(assetId, di[j], E[j], X[j]);
        }
        totalNotes += m;
    }

    // ═══════════════════════════ ТРАТА ═══════════════════════════════

    /// @inheritdoc ILaserGunCore
    function spend(SpendArgs calldata a) external {
        if (msg.sender != executor) revert NotExecutor();
        _spend(a);
    }

    /// @notice Тело траты: вынесено из внешней функции ради лимита стека Yul.
    function _spend(SpendArgs calldata a) internal {
        uint256 assetId = a.assetId;
        if (assetId != 1 && assetId != 2) revert UnknownAsset();
        uint256 d = DenomGrid.denomOf(assetId, a.di); // UnknownDenom
        uint256 n = a.ring.length;
        if (n < MIN_RING) revert RingTooSmall();
        if (n > MAX_RING) revert RingTooLarge();
        if (a.s.length != n) revert InvalidSignature();
        if (uint256(a.c1) >= Points.N) revert InvalidSignature();

        // 1. дешёвый путь: nullifier и payload-хэш до всякой арифметики
        Points.decode(a.I); // InvalidPoint
        bytes32 nullifier = keccak256(a.I);
        bytes32 ph = keccak256(abi.encode(a)); // payload-хэш = раскладка кортежа
        bytes32 stored = spentPayload[nullifier];
        if (stored != bytes32(0)) {
            if (stored == ph) {
                emit DuplicateSpend(nullifier, ph); // ack — без изменений (INV-15)
                return;
            }
            revert NullifierSpent();
        }

        // 2. гейт получателя: ровно один из трёх взаимоисключающих выходов (INV-19)
        _recipientGate(assetId, a);

        // 3–4. кольцо: реестр, деривация hp, уникальность, LSAG-цепочка
        _verifyAgainstRegistry(assetId, a.di, a.ring, a.hp);
        bytes32 mHash = messageHash(assetId, a.di, a.recipient, a.change, a.env, a.payee);
        if (!LSAG.verify(mHash, a.ring, a.hp, a.I, a.c1, a.s)) revert InvalidSignature();

        // 5. консервация выходов с комиссией (6.7)
        uint256 fee;
        uint256 amount; // выплата executor'а — только обналичивание
        {
            uint256 minDenom_ = assetId.minDenom();
            bool hasChange = a.change.di.length > 0;
            bool hasEnv = a.env.di.length > 0;
            bool hasPayee = a.payee.di.length > 0;
            if (hasChange || hasEnv) {
                fee = Fees.feeTransfer(assetId, d, minDenom_);
                if (DenomGrid.sumOf(assetId, a.change.di) + DenomGrid.sumOf(assetId, a.env.di) + fee != d) {
                    revert ChangeMismatch();
                }
                _validateBatch(a.change);
                if (hasEnv) _validateEnvelopeOpen(assetId, a.env);
            } else if (hasPayee) {
                fee = Fees.feeTransfer(assetId, d, minDenom_);
                if (DenomGrid.sumOf(assetId, a.payee.di) + fee != d) revert PayeeMismatch();
                _validateBatch(a.payee);
            } else {
                fee = Fees.feeOut(d);
                amount = d - fee;
            }
        }

        // 6. эффекты — строго после всех проверок (CEI)
        feesAccrued[assetId] += fee;
        spentPayload[nullifier] = ph;
        spentRecipient[nullifier] = a.recipient;
        spentAmount[nullifier] = amount;
        _mintStealthChange(assetId, a.change);
        _mintStealth(assetId, a.payee);
        if (a.env.di.length > 0) _openOrTopUpEnvelope(assetId, a.env);

        emit Spent(assetId, a.di, a.recipient, nullifier, n, a.env.id);
    }

    /// @notice Гейт получателя: ровно один из трёх взаимоисключающих выходов (INV-19).
    function _recipientGate(uint256, SpendArgs calldata a) internal view {
        bool hasChange = a.change.di.length > 0;
        bool hasEnv = a.env.di.length > 0;
        bool hasPayee = a.payee.di.length > 0;
        if (hasChange || hasEnv) {
            if (a.recipient != address(this) || hasPayee) revert InvalidRecipient();
        } else if (hasPayee) {
            if (a.recipient != address(0)) revert InvalidRecipient();
        } else {
            // обналичивание — только на зарегистрированный приёмник вывода (AT-24);
            // трата «в ядро» без выходов — сожжение, отвергается
            if (
                a.recipient == address(0) || a.recipient == address(this)
                    || !payoutReceiverRegistered[a.recipient]
            ) revert InvalidRecipient();
        }
    }

    // ═══════════════════════ КОНВЕРТЫ ═══════════════════════════════

    /// @inheritdoc ILaserGunCore
    function claimEnvelope(bytes32 id, bytes calldata sig) external {
        EnvelopeState storage e = envelopes[id];
        if (e.openAt == 0) revert EnvelopeNotFound();
        if (!e.open) revert EnvelopeClosed();
        if (block.timestamp >= e.expiry) revert ClaimWindowClosed();

        // пермишлес — только при политике permitRequired, хранящейся в записи
        if (e.permitRequired) {
            _verifySchnorr(sig, e.X_s, id);
        }

        e.open = false;
        e.claimed = true;
        _mintEnvelopeNotes(e.assetId, e.di, e.X_r, id);
        emit EnvelopeClaimed(id, e.X_r);
    }

    /// @inheritdoc ILaserGunCore
    function refundEnvelope(bytes32 id) external {
        EnvelopeState storage e = envelopes[id];
        if (e.openAt == 0) revert EnvelopeNotFound();
        if (!e.open) revert EnvelopeClosed();
        if (block.timestamp < e.expiry) revert RefundWindowClosed();

        e.open = false;
        e.claimed = true;
        _mintEnvelopeNotes(e.assetId, e.di, e.X_s, id);
        emit EnvelopeRefunded(id, e.X_s);
    }

    // ══════════════════════ РЕГИСТРАЦИЯ ═════════════════════════════

    function registerReceiver(address receiver) external {
        if (msg.sender != factory) revert SenderNotFactory();
        receiverRegistered[receiver] = true;
        emit ReceiverRegistered(receiver);
    }

    function registerPayoutReceiver(address receiver) external {
        if (msg.sender != factory) revert SenderNotFactory();
        payoutReceiverRegistered[receiver] = true;
        emit PayoutReceiverRegistered(receiver);
    }

    // ══════════════════════════ VIEW ═════════════════════════════════

    function commitmentExists(uint256 assetId, uint256 di, bytes calldata X)
        external view returns (bool)
    {
        return pairMembers[pairKey(assetId, di)][keccak256(X)];
    }

    function isSpent(bytes32 nullifier) external view returns (bool) {
        return spentPayload[nullifier] != bytes32(0);
    }

    function spentInfo(bytes32 nullifier)
        external view returns (bytes32 payloadHash_, address recipient, uint256 amount)
    {
        return (spentPayload[nullifier], spentRecipient[nullifier], spentAmount[nullifier]);
    }

    function denomOf(uint256 assetId, uint256 di) external pure returns (uint256) {
        return DenomGrid.denomOf(assetId, di);
    }

    function feesOf(uint256)
        external pure returns (uint256 bpsIn, uint256 bpsTransfer, uint256 bpsOut)
    {
        return (Fees.FEE_IN_BPS, Fees.FEE_TRANSFER_BPS, Fees.FEE_OUT_BPS);
    }

    function envelope(bytes32 id) external view returns (EnvelopeState memory) {
        return envelopes[id];
    }

    // ═══════════════════ внутренние функции ═══════════════════════════

    function pairKey(uint256 assetId, uint256 di) internal pure returns (uint256) {
        return (assetId << 128) | di;
    }

    /// @notice Вставка коммитмента: глобальная уникальность (INV-13) +
    ///          членство в паре; излучает Minted.
    function _insertCommitment(uint256 assetId, uint256 di, bytes calldata e, bytes calldata x)
        internal
    {
        Points.decode(e); // InvalidPoint до изменений состояния
        Points.decode(x);
        bytes32 xh = keccak256(x);
        if (commitmentKnown[xh]) revert DuplicateCommitment(); // один SLOAD (11.2)
        pairMembers[pairKey(assetId, di)][xh] = true;
        commitmentKnown[xh] = true;
        emit Minted(assetId, di, e, x);
    }

    /// @notice Проверки кольца: валидность точек, деривация hp, уникальность,
    ///          принадлежность реестру пары.
    function _verifyAgainstRegistry(
        uint256 assetId, uint256 di,
        bytes[] calldata ring, bytes[] calldata hp
    ) internal view {
        LSAG.validateRing(ring, hp); // InvalidPoint / DuplicateRingMember / деривация hp
        uint256 key = pairKey(assetId, di);
        for (uint256 j = 0; j < ring.length; ++j) {
            if (!pairMembers[key][keccak256(ring[j])]) revert UnknownCommitment();
        }
    }

    /// @notice LSAG-пересчёт: M собирается на месте, верификация в библиотеке.
    function _verifySignature(
        uint256 assetId, uint256 di, address recipient,
        bytes[] calldata ring, bytes[] calldata hp, bytes calldata I,
        bytes32 c1, uint256[] calldata s,
        Change calldata change, Envelope calldata env, Payee calldata payee
    ) internal view returns (bool) {
        bytes32 mHash = messageHash(assetId, di, recipient, change, env, payee);
        return LSAG.verify(mHash, ring, hp, I, c1, s);
    }

    /// @notice Проверка минтового блока (сдача): длины, точки, уникальность.
    function _validateBatch(Change calldata batch) internal view {
        uint256 m = batch.di.length;
        if (batch.E.length != m || batch.X.length != m) revert InvalidPoint();
        if (m > MAX_NOTES_PER_MINT) revert BatchTooLarge();
        for (uint256 j = 0; j < m; ++j) {
            Points.decode(batch.E[j]);
            Points.decode(batch.X[j]);
            if (commitmentKnown[keccak256(batch.X[j])]) revert DuplicateCommitment();
        }
    }

    /// @notice Проверка блока доставки.
    function _validateBatch(Payee calldata batch) internal view {
        uint256 m = batch.di.length;
        if (batch.E.length != m || batch.X.length != m) revert InvalidPoint();
        if (m > MAX_NOTES_PER_MINT) revert BatchTooLarge();
        for (uint256 j = 0; j < m; ++j) {
            Points.decode(batch.E[j]);
            Points.decode(batch.X[j]);
            if (commitmentKnown[keccak256(batch.X[j])]) revert DuplicateCommitment();
        }
    }

    /// @notice Проверка env открытия/пополнения до эффектов.
    function _validateEnvelopeOpen(uint256 assetId, Envelope calldata env) internal view {
        if (env.assetId != assetId) revert EnvelopeAssetMismatch(); // INV-17
        if (env.expiry <= block.timestamp) revert ClaimWindowEmpty();
        if (env.expiry - block.timestamp > MAX_EXPIRY) revert ExpiryTooLong();
        if (env.di.length > MAX_NOTES_PER_MINT) revert EnvelopeTooLarge();
        uint256 edl = env.di.length;
        if (env.E_r.length != 64 || env.X_r.length != 64 || env.E_s.length != 64 || env.X_s.length != 64) {
            revert InvalidPoint();
        }
        Points.decode(env.E_r);
        Points.decode(env.X_r);
        Points.decode(env.E_s);
        Points.decode(env.X_s);
    }

    /// @notice Открытие или пополнение эскроу-записи (11.3).
    function _openOrTopUpEnvelope(uint256 assetId, Envelope calldata env) internal {
        EnvelopeState storage e = envelopes[env.id];
        if (e.openAt == 0) {
            e.assetId = assetId;
            e.di = env.di;
            e.openAt = block.timestamp;
            e.expiry = env.expiry;
            e.open = true;
            e.claimed = false;
            e.permitRequired = env.permitRequired;
            e.E_r = env.E_r;
            e.X_r = env.X_r;
            e.E_s = env.E_s;
            e.X_s = env.X_s;
        } else if (e.assetId != env.assetId) {
            revert EnvelopeAssetMismatch(); // топ-ап тратой другого актива (INV-17)
        } else if (
            e.expiry == env.expiry
                && e.permitRequired == env.permitRequired
                && keccak256(e.E_r) == keccak256(env.E_r)
                && keccak256(e.X_r) == keccak256(env.X_r)
                && keccak256(e.E_s) == keccak256(env.E_s)
                && keccak256(e.X_s) == keccak256(env.X_s)
        ) {
            if (!e.open) revert EnvelopeClosed();
            if (block.timestamp >= e.expiry) revert ClaimWindowEmpty(); // топ-ап только при активном окне
            if (e.di.length + env.di.length > MAX_NOTES_PER_MINT) revert EnvelopeTooLarge();
            uint256 base = e.di.length;
            uint256 add = env.di.length;
            for (uint256 j = 0; j < add; ++j) {
                e.di.push(env.di[j]);
            }
            // индексация j нот конверта — по итоговой конкатенации di (6.1);
            // точки уже учтённых нот не меняются
        } else {
            revert InvalidRecipient(); // чужие точки/expiry/политика
        }
        emit EnvelopeOpened(env.id, assetId, e.di, e.permitRequired, env.E_r, env.X_r, env.E_s, env.X_s, env.expiry);
    }

    /// @notice Минт нот конверта по формуле размножения (6.1): X_j = X + h_j·G.
    ///          Ядро вычисляет публичную часть; INV-13 внутри конверта
    ///          выполняется автоматически (различные (id, j) → различные точки).
    function _mintEnvelopeNotes(uint256 assetId, uint256[] storage di, bytes storage XBase, bytes32 id)
        internal
    {
        uint256 m = di.length;
        (uint256 bx, uint256 by) = Points.decode(XBase);
        for (uint256 j = 0; j < m; ++j) {
            uint256 h = Points.modN(keccak256(abi.encodePacked(bytes5("LG2-e"), id, uint256(j))));
            (uint256 gx, uint256 gy) = Points.mulG(h);
            (uint256 xj, uint256 yj) = Points.ecAdd(bx, by, gx, gy);
            bytes32 xh = keccak256(abi.encodePacked(xj, yj));
            if (commitmentKnown[xh]) revert DuplicateCommitment(); // пренебрежимо (6.1)
            pairMembers[pairKey(assetId, di[j])][xh] = true;
            commitmentKnown[xh] = true;
            // E конвертной ноты — эфемерная точка ветки (6.1)
            emit Minted(assetId, di[j], XBase, abi.encodePacked(xj, yj));
        }
        totalNotes += m;
    }

    /// @notice Минт сдачи при трате (тип Change).
    function _mintStealthChange(uint256 assetId, Change calldata batch) internal {
        uint256 m = batch.di.length;
        if (m == 0) return;
        for (uint256 j = 0; j < m; ++j) {
            Points.decode(batch.X[j]);
            bytes32 xh = keccak256(batch.X[j]);
            pairMembers[pairKey(assetId, batch.di[j])][xh] = true;
            commitmentKnown[xh] = true;
            emit Minted(assetId, batch.di[j], batch.E[j], batch.X[j]);
        }
        totalNotes += m;
    }

    /// @notice Минт сдачи/доставки при трате: точки уже проверены валидатором.
    function _mintStealth(uint256 assetId, Payee calldata batch) internal {
        uint256 m = batch.di.length;
        if (m == 0) return;
        for (uint256 j = 0; j < m; ++j) {
            Points.decode(batch.X[j]);
            bytes32 xh = keccak256(batch.X[j]);
            pairMembers[pairKey(assetId, batch.di[j])][xh] = true;
            commitmentKnown[xh] = true;
            emit Minted(assetId, batch.di[j], batch.E[j], batch.X[j]);
        }
        totalNotes += m;
    }

    /// @notice Schnorr-пермишлес: c = H("LG2-p" || X_s || R || id),
    ///          валидна ⟺ s·G == R + c·X_s (9.1, INV-8).
    function _verifySchnorr(bytes calldata sig, bytes storage pubXs, bytes32 id)
        internal view
    {
        // sig = R (64 байта) || s (32 байта)
        if (sig.length != 96) revert ClaimPermissionInvalid();
        (uint256 rx, uint256 ry) = Points.decode(sig[0:64]); // InvalidPoint до арифметики
        if (rx == 0 && ry == 0) revert InvalidPoint();
        uint256 sVal = uint256(bytes32(sig[64:96]));
        if (sVal >= Points.N) revert ClaimPermissionInvalid(); // каноничность скаляра

        (uint256 px, uint256 py) = Points.decode(pubXs);
        bytes32 c = keccak256(abi.encodePacked(bytes5("LG2-p"), pubXs, sig[0:64], id));
        (uint256 sGx, uint256 sGy) = Points.mulG(sVal);
        (uint256 cPx, uint256 cPy) = Points.ecMul(uint256(c), px, py);
        (uint256 rcx, uint256 rcy) = Points.ecAdd(rx, ry, cPx, cPy);
        if (sGx != rcx || sGy != rcy) revert ClaimPermissionInvalid();
    }

    // ═══════════════════════ ХЭШИ (6.3) ═══════════════════════════════

    /// @notice M = H("LG2-w" || assetId || di || recipient || chainId || H(change) || H(env) || H(payee)).
    ///          Пустые блоки — 32 нулевых байта; непустые — H(abi.encode структуры).
    function messageHash(
        uint256 assetId, uint256 di, address recipient,
        Change calldata change, Envelope calldata env, Payee calldata payee
    ) public view returns (bytes32) {
        bool hasChange = change.di.length > 0;
        bool hasEnv = env.di.length > 0;
        bool hasPayee = payee.di.length > 0;
        bytes32 hc = hasChange ? keccak256(abi.encode(change)) : bytes32(0);
        bytes32 he = hasEnv ? keccak256(abi.encode(env)) : bytes32(0);
        bytes32 hp_ = hasPayee ? keccak256(abi.encode(payee)) : bytes32(0);
        return keccak256(
            abi.encodePacked(
                bytes5("LG2-w"),
                bytes32(assetId),
                bytes32(di),
                bytes20(recipient),
                bytes32(block.chainid), // единственное блочное чтение (INV-2)
                hc,
                he,
                hp_
            )
        );
    }

    /// @notice Payload-хэш — ключ ack-идемпотентности (только ончейн).
    function payloadHash(
        uint256 assetId, uint256 di, address recipient,
        bytes[] calldata ring, bytes[] calldata hp, bytes calldata I,
        bytes32 c1, uint256[] calldata s,
        Change calldata change, Envelope calldata env, Payee calldata payee
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(assetId, di, recipient, ring, hp, I, c1, s, change, env, payee));
    }
}
