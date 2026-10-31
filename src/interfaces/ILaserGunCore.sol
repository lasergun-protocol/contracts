// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @dev Интерфейс ядра LaserGun Core v2 — фиксация раздела 11.2 ТЗ.
///      Сигнатуры целевые: допустимы только несмысловые правки типов
///      с сохранением имён и семантики.
interface ILaserGunCore {
    // ── минт (только зарегистрированные приёмники; INV-19/INV-20) ──
    // assetId: 1 = USDC, 2 = ETH; di — индекс номинала в сетке актива;
    // E — эфемерная точка ноты; X — её коммитмент;
    // deposited — полная сумма, поступившая на supply в приёмнике:
    // минтует ровно deposited − feeIn(deposited), комиссия ввода — 6.7
    function mintNotes(
        uint256 assetId, uint256 deposited, uint256[] calldata di,
        bytes[] calldata E, bytes[] calldata X
    ) external;

    // ── трата (LSAG; только executor — константная связка core↔executor) ──
    // recipient = адрес ядра (сдача/конверт), нулевой (стелс-доставка)
    // или зарегистрированный приёмник вывода (обналичивание, 10.2).
    // Все аргументы собраны в SpendArgs: несмысловая группировка полей 11.2
    // (имена и семантика сохранены); executor передаёт calldata байт-в-байт,
    // payload-хэш = keccak256(abi.encode(args)) — та же раскладка кортежа.
    function spend(SpendArgs calldata args) external;

    struct SpendArgs {
        uint256 assetId; uint256 di; address recipient;
        bytes[] ring;       // члены кольца — коммитменты реестра пары
        bytes[] hp;         // точки Hp(Y_i): 65 байт x‖y + счётчик (6.3)
        bytes I;            // key image
        bytes32 c1; uint256[] s;
        Change change;      // пустой — без сдачи
        Envelope env;       // пустой — при обычной трате
        Payee payee;        // пустой — без стелс-доставки
    }

    struct Change {
        uint256[] di;
        bytes[] E; bytes[] X;
    }

    struct Payee {
        uint256[] di;
        bytes[] E; bytes[] X;
    }

    struct Envelope {
        bytes32 id;
        uint256 assetId;
        uint256[] di;
        uint256 expiry;
        bool permitRequired;
        bytes E_r; bytes X_r;
        bytes E_s; bytes X_s;
    }

    // ── исполнение конверта ─────────────────────────────────────────
    // sig: пермишлес отправителя — Schnorr-подпись над id ключом y_s,
    // публичный ключ — X_s из эскроу-записи:
    // c = H("LG2-p" || X_s || R || id); валидна <=> s·G == R + c·X_s
    // sig = (R, s): 65 байт R (64) + s (32) — кодировки POINT_ENCODING
    function claimEnvelope(bytes32 id, bytes calldata sig) external;
    function refundEnvelope(bytes32 id) external;

    // ── регистрация приёмников входа и вывода (только factory) ──────
    function registerReceiver(address receiver) external;
    function registerPayoutReceiver(address receiver) external;

    // ── view для клиента и executor'а ───────────────────────────────
    function commitmentExists(uint256 assetId, uint256 di, bytes calldata X)
        external view returns (bool);
    function isSpent(bytes32 nullifier) external view returns (bool);
    function spentInfo(bytes32 nullifier)
        external view returns (bytes32 payloadHash, address recipient, uint256 amount);
    function denomOf(uint256 assetId, uint256 di) external view returns (uint256);
    function feesOf(uint256 assetId)
        external view returns (uint256 bpsIn, uint256 bpsTransfer, uint256 bpsOut);
    function feesAccrued(uint256 assetId) external view returns (uint256);
    function envelope(bytes32 id) external view returns (EnvelopeState memory);
    function receiverRegistered(address a) external view returns (bool);
    function payoutReceiverRegistered(address a) external view returns (bool);

    // адрес executor'а и фабрики — константы сборки (15.1): без конструктора
    function factory() external view returns (address);
    function executor() external view returns (address);
}

struct EnvelopeState {
    uint256 assetId; uint256[] di;
    uint256 openAt; uint256 expiry;
    bool open; bool claimed;
    bool permitRequired;
    bytes E_r; bytes X_r; bytes E_s; bytes X_s;
}
