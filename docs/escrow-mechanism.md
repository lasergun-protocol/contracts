# Механизм Escrow в LaserGun

## Обзор

Механизм escrow в контракте LaserGun предоставляет безопасный способ хранения токенов в приватных расписках с требованием подтверждения от отправителя. Этот механизм позволяет отправителю создать escrow-расписку для получателя, но требует дополнительного подтверждения перед тем, как получатель сможет получить доступ к средствам.

### Назначение

Механизм escrow предназначен для:
- Защиты отправителя от случайных или мошеннических переводов
- Предоставления времени для проверки транзакции перед финализацией
- Обеспечения дополнительного уровня безопасности для крупных переводов
- Поддержки сценариев использования, где требуется двухэтапное подтверждение

## Архитектура и основные компоненты

### Структура данных

#### EscrowShield

```solidity
struct EscrowShield {
    address token;                    // Адрес токена ERC20
    uint256 amount;                   // Количество токенов
    uint256 timestamp;                // Время создания расписки
    bool exists;                      // Флаг существования расписки
    bool spent;                       // Флаг использования расписки
    bool isEscrow;                    // Флаг, указывающий на escrow-расписку
    address sender;                   // Адрес отправителя
    address recipient;                // Адрес получателя
    uint256 confirmationDeadline;     // Дедлайн для подтверждения
    bool confirmed;                   // Флаг подтверждения отправителем
    bool released;                    // Флаг выпуска средств получателю
    bool cancelled;                   // Флаг отмены escrow
}
```

### Хранилища

- `escrowShields`: маппинг хэшей обязательств на данные escrow-расписок
- `shields`: маппинг для обычных (не-escrow) расписок

### Константы

- `MIN_CONFIRMATION_PERIOD`: минимальный период подтверждения (1 час)
- `MAX_CONFIRMATION_PERIOD`: максимальный период подтверждения (30 дней)

## Функции механизма escrow

### createEscrowShield

Создает новую escrow-расписку с требованием подтверждения.

```solidity
function createEscrowShield(
    uint256 amount,
    address token,
    bytes32 commitment,
    address recipient,
    uint256 confirmationPeriod,
    bytes32 bloomFilter
) external nonReentrant whenNotPaused
```

**Параметры:**
- `amount`: количество токенов для депозита
- `token`: адрес токена ERC20
- `commitment`: уникальное обязательство, сгенерированное из секрета
- `recipient`: адрес предполагаемого получателя
- `confirmationPeriod`: период подтверждения в секундах
- `bloomFilter`: фильтр Блума для приватности

**Требования:**
- amount > 0
- token должен быть валидным контрактом ERC20
- commitment не должен существовать ранее
- recipient должен быть валидным адресом
- confirmationPeriod должен быть в диапазоне [MIN_CONFIRMATION_PERIOD, MAX_CONFIRMATION_PERIOD]

**Эффекты:**
- Токены переводятся на адрес контракта
- Создается новая escrow-расписка с указанными параметрами
- Взимается комиссия за операцию
- Генерируется событие EscrowShielded

### confirmEscrow

Подтверждает escrow-расписку отправителем.

```solidity
function confirmEscrow(bytes32 commitment) external nonReentrant whenNotPaused
```

**Параметры:**
- `commitment`: обязательство escrow-расписки для подтверждения

**Требования:**
- Вызывающий должен быть отправителем escrow
- Расписка должна существовать и быть активной
- Расписка не должна быть ранее подтверждена
- Дедлайн подтверждения не должен истечь

**Эффекты:**
- Устанавливает флаг confirmed в true
- Генерирует событие EscrowConfirmed

### releaseEscrow

Выпускает подтвержденные средства получателю.

```solidity
function releaseEscrow(bytes32 commitment, bytes32 secret) external nonReentrant whenNotPaused
```

**Параметры:**
- `commitment`: обязательство escrow-расписки
- `secret`: секрет, соответствующий обязательству

**Требования:**
- Секрет должен соответствовать обязательству и отправителю
- Расписка должна существовать и быть активной
- Расписка должна быть подтверждена
- Расписка не должна быть ранее выпущена

**Эффекты:**
- Переводит токены получателю
- Устанавливает флаги released и spent в true
- Генерирует событие EscrowReleased

### cancelEscrow

Отменяет escrow и возвращает средства отправителю.

```solidity
function cancelEscrow(bytes32 commitment, bytes32 secret) external nonReentrant whenNotPaused
```

**Параметры:**
- `commitment`: обязательство escrow-расписки
- `secret`: секрет, соответствующий обязательству

**Требования:**
- Секрет должен соответствовать обязательству и отправителю
- Вызывающий должен быть отправителем escrow
- Расписка должна существовать и быть активной
- Расписка не должна быть ранее выпущена или отменена
- Расписка может быть отменена, если:
  - Она не подтверждена, ИЛИ
  - Дедлайн подтверждения истек

**Эффекты:**
- Возвращает токены отправителю
- Устанавливает флаги cancelled и spent в true
- Генерирует событие EscrowCancelled

## Функции просмотра

### getEscrowShieldInfo

Возвращает полную информацию об escrow-расписке.

```solidity
function getEscrowShieldInfo(bytes32 commitment) external view returns (EscrowShield memory escrowShield)
```

### isActiveEscrow

Проверяет, является ли обязательство активным escrow.

```solidity
function isActiveEscrow(bytes32 commitment) external view returns (bool)
```

### getEscrowStatus

Возвращает текущий статус escrow.

```solidity
function getEscrowStatus(bytes32 commitment) external view returns (string memory status)
```

**Возможные статусы:**
- "Nonexistent": расписка не существует
- "Pending": ожидает подтверждения
- "Confirmed": подтверждена, ожидает выпуска
- "Released": средства выпущены получателю
- "Cancelled": отменена
- "Expired": срок подтверждения истек

## События

### EscrowShielded

Генерируется при создании новой escrow-расписки.

```solidity
event EscrowShielded(
    bytes32 indexed commitment,
    address indexed token,
    uint256 amount,
    address indexed sender,
    address recipient,
    uint256 confirmationDeadline,
    uint256 fee,
    bytes32 bloomFilter
);
```

### EscrowConfirmed

Генерируется при подтверждении escrow отправителем.

```solidity
event EscrowConfirmed(bytes32 indexed commitment, address indexed sender);
```

### EscrowReleased

Генерируется при выпуске средств получателю.

```solidity
event EscrowReleased(bytes32 indexed commitment, address indexed recipient, uint256 amount);
```

### EscrowCancelled

Генерируется при отмене escrow.

```solidity
event EscrowCancelled(bytes32 indexed commitment, address indexed sender, uint256 amount);
```

### EscrowExpired

Генерируется при истечении срока подтверждения.

```solidity
event EscrowExpired(bytes32 indexed commitment, address indexed sender, uint256 amount);
```

## Примеры использования

### Пример 1: Создание и подтверждение escrow

```javascript
// Подключение к контракту
const laserGun = await ethers.getContractAt("LaserGun", contractAddress);
const token = await ethers.getContractAt("IERC20", tokenAddress);

// Параметры транзакции
const amount = ethers.utils.parseUnits("1000", 18); // 1000 токенов
const recipient = "0x1234567890123456789012345678901234567890";
const confirmationPeriod = 24 * 60 * 60; // 24 часа

// Генерация секрета и обязательства
const secret = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("my_secret"));
const commitment = await laserGun.generateCommitment(secret, senderAddress);

// Одобрение токенов для контракта
await token.approve(laserGun.address, amount);

// Создание escrow-расписки
await laserGun.createEscrowShield(
    amount,
    token.address,
    commitment,
    recipient,
    confirmationPeriod,
    ethers.constants.HashZero // пустой bloom filter
);

// Подтверждение escrow отправителем
await laserGun.confirmEscrow(commitment);

// Выпуск средств получателю
await laserGun.releaseEscrow(commitment, secret);
```

### Пример 2: Отмена escrow

```javascript
// Создание escrow-расписки (как в примере 1)
// ...

// Отмена escrow отправителем (до подтверждения)
await laserGun.cancelEscrow(commitment, secret);
```

### Пример 3: Проверка статуса escrow

```javascript
// Получение информации о статусе escrow
const status = await laserGun.getEscrowStatus(commitment);
console.log("Escrow status:", status);

// Получение полной информации о escrow
const escrowInfo = await laserGun.getEscrowShieldInfo(commitment);
console.log("Escrow info:", escrowInfo);

// Проверка активности escrow
const isActive = await laserGun.isActiveEscrow(commitment);
console.log("Is active escrow:", isActive);
```

## Диаграммы процессов

### Диаграмма создания и подтверждения escrow

```
Отправитель                      Контракт                     Получатель
    |                               |                            |
    |--- createEscrowShield -------->|                            |
    |                               |--- Создает escrow-расписку --|
    |                               |                            |
    |<-- EscrowShielded (event) ----|                            |
    |                               |                            |
    |--- confirmEscrow ------------>|                            |
    |                               |--- Подтверждает escrow -----|
    |                               |                            |
    |<-- EscrowConfirmed (event) ---|                            |
    |                               |                            |
    |--- releaseEscrow ------------>|                            |
    |                               |--- Переводит токенты ------>|
    |                               |                            |
    |<-- EscrowReleased (event) ---|                            |
```

### Диаграмма отмены escrow

```
Отправитель                      Контракт
    |                               |
    |--- createEscrowShield -------->|
    |                               |
    |<-- EscrowShielded (event) ----|
    |                               |
    |--- cancelEscrow -------------->|
    |                               |
    |<-- EscrowCancelled (event) ---|
    |                               |
    |<-- Возврат токенов -----------|
```

## Соображения безопасности

### Защита от реентерантности

Все функции механизма escrow используют модификатор `nonReentrant` для защиты от атак реентерантности.

### Контроль доступа

- Только отправитель может подтвердить или отменить escrow
- Только отправитель может выпустить средства после подтверждения
- Секрет необходим для подтверждения владения escrow

### Ограничения времени

- Минимальный период подтверждения: 1 час
- Максимальный период подтверждения: 30 дней
- После истечения дедлайна escrow может быть отменен

### Валидация параметров

- Проверка на нулевые адреса
- Проверка на нулевые суммы
- Проверка существования обязательств
- Проверка состояния escrow

### Обработка ошибок

Механизм использует кастомные ошибки для четкой идентификации проблем:
- `InvalidEscrowState`: неверное состояние escrow
- `NotEscrowSender`: вызывающий не является отправителем
- `InvalidConfirmationPeriod`: недопустимый период подтверждения
- `ConfirmationDeadlinePassed`: дедлайн подтверждения истек
- `EscrowNotConfirmed`: escrow не подтвержден
- `EscrowAlreadyConfirmed`: escrow уже подтвержден

## Газовая эффективность

### Стоимость операций

- `createEscrowShield`: ~180k-230k gas
- `confirmEscrow`: ~50k-70k gas
- `releaseEscrow`: ~80k-100k gas
- `cancelEscrow`: ~80k-100k gas

### Оптимизации

- Использование storage указателей для минимизации операций записи
- Пакетирование обновлений состояния
- Эффективная структура данных EscrowShield

## Часто задаваемые вопросы

### В: Что происходит, если отправитель не подтверждает escrow до истечения дедлайна?

О: После истечения дедлайна отправитель может отменить escrow и вернуть средства. Получатель не сможет получить доступ к средствам без подтверждения.

### В: Может ли получатель отменить escrow?

О: Нет, только отправитель может отменить escrow. Это обеспечивает контроль отправителя над средствами.

### В: Что произойдет, если отправитель подтвердит escrow, но никогда не вызовет releaseEscrow?

О: Средства останутся в escrow до тех пор, пока отправитель не вызовет releaseEscrow. Получатель не может получить средства без этого действия.

### В: Можно ли изменить получателя после создания escrow?

О: Нет, получатель указывается при создании escrow и не может быть изменен.

### В: Можно ли изменить период подтверждения после создания escrow?

О: Нет, период подтверждения устанавливается при создании и не может быть изменен.

### В: В чем разница между обычной распиской и escrow-распиской?

О: Escrow-расписка требует дополнительного подтверждения от отправителя перед тем, как получатель сможет получить доступ к средствам. Обычная расписка позволяет немедленный доступ к средствам с помощью секрета.

### В: Какова минимальная и максимальная комиссия за escrow-операции?

О: Комиссия за escrow-операции такая же, как и за обычные операции shield/unshield/transfer, и определяется параметрами shieldFeePercent и unshieldFeePercent контракта.

### В: Можно ли использовать escrow-механизм для NFT или других нестандартных токенов?

О: Текущая реализация поддерживает только стандартные токены ERC20. Для поддержки других типов токенов потребуются модификации контракта.

### В: Как escrow-механизм взаимодействует с функцией pause контракта?

О: При активации pause все escrow-операции приостанавливаются, как и другие функции контракта с модификатором whenNotPaused.

### В: Можно ли создать escrow с нулевым периодом подтверждения?

О: Нет, минимальный период подтверждения составляет 1 час (3600 секунд) для обеспечения достаточного времени на проверку транзакции.