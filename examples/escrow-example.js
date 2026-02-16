const { ethers } = require("hardhat");
const { expect } = require("chai");

/**
 * Пример использования механизма escrow в контракте LaserGun
 * 
 * Этот пример демонстрирует полный жизненный цикл escrow-расписки:
 * 1. Создание escrow-расписки
 * 2. Подтверждение отправителем
 * 3. Выпуск средств получателю
 * 
 * Также показан сценарий отмены escrow-расписки
 */
async function main() {
  // Получение аккаунтов
  const [sender, recipient, feeRecipient] = await ethers.getSigners();
  
  console.log("Отправитель:", sender.address);
  console.log("Получатель:", recipient.address);
  console.log("Получатель комиссий:", feeRecipient.address);
  
  // Развертывание контрактов
  console.log("\nРазвертывание контрактов...");
  
  // Развертывание тестового токена
  const TestToken = await ethers.getContractFactory("TestToken");
  const token = await TestToken.deploy("Test Token", "TEST", 18);
  await token.deployed();
  console.log("Токен развернут по адресу:", token.address);
  
  // Развертывание контракта LaserGun
  const LaserGun = await ethers.getContractFactory("LaserGun");
  const laserGun = await LaserGun.deploy();
  await laserGun.deployed();
  
  // Инициализация контракта
  await laserGun.initialize(
    sender.address, // admin
    25, // shieldFeePercent (0.25%)
    25, // unshieldFeePercent (0.25%)
    25  // transferFeePercent (0.25%)
  );
  console.log("LaserGun развернут по адресу:", laserGun.address);
  
  // Установка ролей
  const PAUSER_ROLE = await laserGun.PAUSER_ROLE();
  await laserGun.grantRole(PAUSER_ROLE, sender.address);
  
  // Создание токенов для отправителя
  const amount = ethers.utils.parseUnits("1000", 18); // 1000 токенов
  await token.mint(sender.address, amount);
  console.log("Отправителю создано", ethers.utils.formatUnits(amount, 18), "токенов");
  
  // Одобрение токенов для контракта LaserGun
  await token.connect(sender).approve(laserGun.address, amount);
  console.log("Токены одобрены для контракта LaserGun");
  
  // Параметры escrow
  const confirmationPeriod = 24 * 60 * 60; // 24 часа
  const recipientAddress = recipient.address;
  
  // Генерация секрета и обязательства
  const secret = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("my_escrow_secret"));
  const commitment = await laserGun.generateCommitment(secret, sender.address);
  console.log("\nСгенерирован секрет:", secret);
  console.log("Сгенерировано обязательство:", commitment);
  
  // Проверка начальных балансов
  const senderBalanceBefore = await token.balanceOf(sender.address);
  const recipientBalanceBefore = await token.balanceOf(recipient.address);
  console.log("\nНачальный баланс отправителя:", ethers.utils.formatUnits(senderBalanceBefore, 18));
  console.log("Начальный баланс получателя:", ethers.utils.formatUnits(recipientBalanceBefore, 18));
  
  // Создание escrow-расписки
  console.log("\n=== Создание escrow-расписки ===");
  const createTx = await laserGun.connect(sender).createEscrowShield(
    amount,
    token.address,
    commitment,
    recipientAddress,
    confirmationPeriod,
    ethers.constants.HashZero // пустой bloom filter
  );
  const createReceipt = await createTx.wait();
  
  console.log("Gas использовано для создания escrow:", createReceipt.gasUsed.toString());
  
  // Проверка состояния escrow
  const escrowStatus = await laserGun.getEscrowStatus(commitment);
  console.log("Статус escrow после создания:", escrowStatus);
  
  const escrowInfo = await laserGun.getEscrowShieldInfo(commitment);
  console.log("Информация о escrow:", {
    token: escrowInfo.token,
    amount: ethers.utils.formatUnits(escrowInfo.amount, 18),
    sender: escrowInfo.sender,
    recipient: escrowInfo.recipient,
    confirmed: escrowInfo.confirmed,
    released: escrowInfo.released,
    cancelled: escrowInfo.cancelled,
    confirmationDeadline: new Date(escrowInfo.confirmationDeadline.toNumber() * 1000).toISOString()
  });
  
  // Попытка выпуска средств без подтверждения (должна провалиться)
  console.log("\n=== Попытка выпуска средств без подтверждения ===");
  try {
    await laserGun.connect(sender).releaseEscrow(commitment, secret);
    console.log("Ошибка: выпуск средств прошел без подтверждения!");
  } catch (error) {
    console.log("Ожидаемая ошибка:", error.message);
  }
  
  // Подтверждение escrow отправителем
  console.log("\n=== Подтверждение escrow отправителем ===");
  const confirmTx = await laserGun.connect(sender).confirmEscrow(commitment);
  const confirmReceipt = await confirmTx.wait();
  
  console.log("Gas использовано для подтверждения:", confirmReceipt.gasUsed.toString());
  
  // Проверка состояния после подтверждения
  const escrowStatusAfterConfirm = await laserGun.getEscrowStatus(commitment);
  console.log("Статус escrow после подтверждения:", escrowStatusAfterConfirm);
  
  // Выпуск средств получателю
  console.log("\n=== Выпуск средств получателю ===");
  const releaseTx = await laserGun.connect(sender).releaseEscrow(commitment, secret);
  const releaseReceipt = await releaseTx.wait();
  
  console.log("Gas использовано для выпуска средств:", releaseReceipt.gasUsed.toString());
  
  // Проверка конечных балансов
  const senderBalanceAfter = await token.balanceOf(sender.address);
  const recipientBalanceAfter = await token.balanceOf(recipient.address);
  console.log("\nКонечный баланс отправителя:", ethers.utils.formatUnits(senderBalanceAfter, 18));
  console.log("Конечный баланс получателя:", ethers.utils.formatUnits(recipientBalanceAfter, 18));
  
  // Проверка состояния escrow после выпуска
  const escrowStatusAfterRelease = await laserGun.getEscrowStatus(commitment);
  console.log("Статус escrow после выпуска:", escrowStatusAfterRelease);
  
  // Демонстрация отмены escrow
  console.log("\n=== Демонстрация отмены escrow ===");
  
  // Создание нового escrow для демонстрации отмены
  const amount2 = ethers.utils.parseUnits("500", 18); // 500 токенов
  await token.mint(sender.address, amount2);
  await token.connect(sender).approve(laserGun.address, amount2);
  
  const secret2 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("cancel_secret"));
  const commitment2 = await laserGun.generateCommitment(secret2, sender.address);
  
  console.log("Создание второго escrow для демонстрации отмены...");
  await laserGun.connect(sender).createEscrowShield(
    amount2,
    token.address,
    commitment2,
    recipientAddress,
    confirmationPeriod,
    ethers.constants.HashZero
  );
  
  const escrow2StatusBefore = await laserGun.getEscrowStatus(commitment2);
  console.log("Статус второго escrow до отмены:", escrow2StatusBefore);
  
  // Отмена escrow без подтверждения
  console.log("Отмена второго escrow...");
  const cancelTx = await laserGun.connect(sender).cancelEscrow(commitment2, secret2);
  const cancelReceipt = await cancelTx.wait();
  
  console.log("Gas использовано для отмены:", cancelReceipt.gasUsed.toString());
  
  const escrow2StatusAfter = await laserGun.getEscrowStatus(commitment2);
  console.log("Статус второго escrow после отмены:", escrow2StatusAfter);
  
  // Демонстрация отмены после истечения срока
  console.log("\n=== Демонстрация отмены после истечения срока ===");
  
  // Создание escrow с коротким сроком подтверждения
  const amount3 = ethers.utils.parseUnits("300", 18); // 300 токенов
  await token.mint(sender.address, amount3);
  await token.connect(sender).approve(laserGun.address, amount3);
  
  const secret3 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("expire_secret"));
  const commitment3 = await laserGun.generateCommitment(secret3, sender.address);
  
  // Минимальный период подтверждения (1 час)
  const shortConfirmationPeriod = 3600;
  
  console.log("Создание escrow с коротким сроком подтверждения...");
  await laserGun.connect(sender).createEscrowShield(
    amount3,
    token.address,
    commitment3,
    recipientAddress,
    shortConfirmationPeriod,
    ethers.constants.HashZero
  );
  
  // Подтверждение escrow
  await laserGun.connect(sender).confirmEscrow(commitment3);
  
  const escrow3StatusBefore = await laserGun.getEscrowStatus(commitment3);
  console.log("Статус третьего escrow после подтверждения:", escrow3StatusBefore);
  
  // В реальном сценарии здесь нужно было бы подождать истечения срока
  // Для демонстрации мы просто покажем, что отмена после подтверждения невозможна
  console.log("Попытка отмены подтвержденного escrow (должна провалиться)...");
  try {
    await laserGun.connect(sender).cancelEscrow(commitment3, secret3);
    console.log("Ошибка: отмена подтвержденного escrow прошла успешно!");
  } catch (error) {
    console.log("Ожидаемая ошибка:", error.message);
  }
  
  console.log("\n=== Демонстрация завершена ===");
}

// Демонстрация обработки событий
async function demonstrateEvents() {
  console.log("\n=== Демонстрация обработки событий ===");
  
  // Получение аккаунтов
  const [sender, recipient] = await ethers.getSigners();
  
  // Развертывание контрактов
  const TestToken = await ethers.getContractFactory("TestToken");
  const token = await TestToken.deploy("Test Token", "TEST", 18);
  await token.deployed();
  
  const LaserGun = await ethers.getContractFactory("LaserGun");
  const laserGun = await LaserGun.deploy();
  await laserGun.deployed();
  
  await laserGun.initialize(sender.address, 25, 25, 25);
  
  // Создание токенов
  const amount = ethers.utils.parseUnits("1000", 18);
  await token.mint(sender.address, amount);
  await token.connect(sender).approve(laserGun.address, amount);
  
  // Генерация секрета и обязательства
  const secret = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("events_secret"));
  const commitment = await laserGun.generateCommitment(secret, sender.address);
  
  // Установка слушателей событий
  laserGun.on("EscrowShielded", (commitment, token, amount, sender, recipient, deadline, fee, event) => {
    console.log("Событие EscrowShielded:");
    console.log("  Обязательство:", commitment);
    console.log("  Токен:", token);
    console.log("  Сумма:", ethers.utils.formatUnits(amount, 18));
    console.log("  Отправитель:", sender);
    console.log("  Получатель:", recipient);
    console.log("  Дедлайн:", new Date(deadline.toNumber() * 1000).toISOString());
    console.log("  Комиссия:", ethers.utils.formatUnits(fee, 18));
  });
  
  laserGun.on("EscrowConfirmed", (commitment, sender, event) => {
    console.log("Событие EscrowConfirmed:");
    console.log("  Обязательство:", commitment);
    console.log("  Отправитель:", sender);
  });
  
  laserGun.on("EscrowReleased", (commitment, recipient, amount, event) => {
    console.log("Событие EscrowReleased:");
    console.log("  Обязательство:", commitment);
    console.log("  Получатель:", recipient);
    console.log("  Сумма:", ethers.utils.formatUnits(amount, 18));
  });
  
  laserGun.on("EscrowCancelled", (commitment, sender, amount, event) => {
    console.log("Событие EscrowCancelled:");
    console.log("  Обязательство:", commitment);
    console.log("  Отправитель:", sender);
    console.log("  Сумма:", ethers.utils.formatUnits(amount, 18));
  });
  
  // Выполнение операций с escrow
  console.log("Создание escrow-расписки...");
  await laserGun.connect(sender).createEscrowShield(
    amount,
    token.address,
    commitment,
    recipient.address,
    24 * 60 * 60, // 24 часа
    ethers.constants.HashZero
  );
  
  console.log("Подтверждение escrow...");
  await laserGun.connect(sender).confirmEscrow(commitment);
  
  console.log("Выпуск средств...");
  await laserGun.connect(sender).releaseEscrow(commitment, secret);
  
  // Создание еще одного escrow для демонстрации отмены
  const amount2 = ethers.utils.parseUnits("500", 18);
  await token.mint(sender.address, amount2);
  await token.connect(sender).approve(laserGun.address, amount2);
  
  const secret2 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("cancel_events_secret"));
  const commitment2 = await laserGun.generateCommitment(secret2, sender.address);
  
  console.log("Создание второго escrow для демонстрации отмены...");
  await laserGun.connect(sender).createEscrowShield(
    amount2,
    token.address,
    commitment2,
    recipient.address,
    24 * 60 * 60,
    ethers.constants.HashZero
  );
  
  console.log("Отмена второго escrow...");
  await laserGun.connect(sender).cancelEscrow(commitment2, secret2);
  
  console.log("Демонстрация событий завершена");
}

// Запуск примеров
async function runExamples() {
  try {
    await main();
    await demonstrateEvents();
  } catch (error) {
    console.error("Ошибка при выполнении примеров:", error);
    process.exit(1);
  }
}

// Экспорт функций для использования в тестах
module.exports = {
  main,
  demonstrateEvents,
  runExamples
};

// Запуск при прямом вызове файла
if (require.main === module) {
  runExamples();
}