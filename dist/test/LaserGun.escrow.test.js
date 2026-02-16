"use strict";
// test/LaserGun.escrow.fixed.test.js - Комплексные тесты для escrow-функциональности (исправленные)
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
describe("LaserGun Escrow", function () {
    let contract, mockUSDC;
    let admin, user1, user2, user3;
    const SHIELD_FEE = 25n; // BigInt для ethers v6
    const UNSHIELD_FEE = 25n;
    const TRANSFER_FEE = 25n;
    const FEE_DENOMINATOR = 10000n;
    before(async function () {
        // Сброс состояния сети перед всеми тестами
        await network.provider.send("hardhat_reset", []);
    });
    beforeEach(async function () {
        try {
            [admin, user1, user2, user3] = await ethers.getSigners();
            // Deploy mock USDC token
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6);
            await mockUSDC.waitForDeployment(); // v6: вместо deployed()
            // Mint tokens to users - ethers v6 синтаксис
            const amount = ethers.parseUnits("10000", 6); // БЕЗ .utils
            await mockUSDC.mint(user1.address, amount);
            await mockUSDC.mint(user2.address, amount);
            await mockUSDC.mint(user3.address, amount);
            // Deploy LaserGun proxy
            const LaserGun = await ethers.getContractFactory("LaserGun");
            contract = await upgrades.deployProxy(LaserGun, [admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE], {
                initializer: 'initialize',
                kind: 'uups',
                timeout: 60000
            });
            await contract.waitForDeployment(); // v6: вместо deployed()
            // Обеспечиваем консистентность состояния
            await network.provider.send("evm_mine", []);
        }
        catch (error) {
            console.error("BeforeEach setup failed:", error);
            throw error;
        }
    });
    // Helper functions для ethers v6
    async function waitForTransaction(txPromise) {
        const tx = await txPromise;
        const receipt = await tx.wait();
        await network.provider.send("evm_mine", []);
        return receipt;
    }
    async function createTestShield(user, amount, token = mockUSDC) {
        const secret = ethers.randomBytes(32); // БЕЗ .utils
        // Получаем текущие данные блока для генерации коммитмента
        const block = await ethers.provider.getBlock("latest");
        const commitment = ethers.keccak256(ethers.solidityPacked(["bytes32", "address", "uint256", "uint256", "address", "uint256"], [secret, user.address, block.timestamp, block.prevrandao, await contract.getAddress(), 0] // nonce = 0 для нового пользователя
        ));
        const bloomFilter = ethers.randomBytes(32); // 32 байта bloom filter
        await token.connect(user).approve(await contract.getAddress(), amount);
        await waitForTransaction(contract.connect(user).shield(amount, await token.getAddress(), commitment, bloomFilter));
        return { secret, commitment, amount, bloomFilter };
    }
    async function createTestEscrowShield(user, amount, recipient, confirmationPeriod, token = mockUSDC) {
        const secret = ethers.randomBytes(32);
        // Получаем текущие данные блока для генерации коммитмента
        const block = await ethers.provider.getBlock("latest");
        const commitment = ethers.keccak256(ethers.solidityPacked(["bytes32", "address", "uint256", "uint256", "address", "uint256"], [secret, user.address, block.timestamp, block.prevrandao, await contract.getAddress(), 0] // nonce = 0 для нового пользователя
        ));
        const bloomFilter = ethers.randomBytes(32);
        await token.connect(user).approve(await contract.getAddress(), amount);
        await waitForTransaction(contract.connect(user).createEscrowShield(amount, await token.getAddress(), commitment, recipient, confirmationPeriod, bloomFilter));
        return { secret, commitment, amount, bloomFilter, recipient, confirmationPeriod };
    }
    describe("Create Escrow Shield", function () {
        it("Should create escrow shield successfully", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600; // 1 час
            const { secret, commitment, bloomFilter } = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            // Calculate expected fee and net amount
            const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
            const expectedNetAmount = amount - expectedFee;
            // Check escrow shield info
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.exists).to.be.true;
            expect(escrowShield.isEscrow).to.be.true;
            expect(escrowShield.amount).to.equal(expectedNetAmount);
            expect(escrowShield.token).to.equal(await mockUSDC.getAddress());
            expect(escrowShield.sender).to.equal(user1.address);
            expect(escrowShield.recipient).to.equal(user2.address);
            // Check that deadline is approximately correct (within 2 seconds tolerance)
            const expectedDeadlineMin = escrowShield.timestamp + BigInt(confirmationPeriod);
            const expectedDeadlineMax = escrowShield.timestamp + BigInt(confirmationPeriod) + 2n;
            expect(escrowShield.confirmationDeadline).to.be.gte(expectedDeadlineMin);
            expect(escrowShield.confirmationDeadline).to.be.lte(expectedDeadlineMax);
            expect(escrowShield.confirmed).to.be.false;
            expect(escrowShield.released).to.be.false;
            expect(escrowShield.cancelled).to.be.false;
            expect(escrowShield.spent).to.be.false;
            // Check collected fees
            expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(expectedFee);
            // Check escrow status
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Pending");
        });
        it("Should reject zero amounts", async function () {
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 3600;
            await mockUSDC.connect(user1).approve(await contract.getAddress(), 100);
            await expect(contract.connect(user1).createEscrowShield(0n, await mockUSDC.getAddress(), commitment, user2.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "ZeroAmount");
        });
        it("Should reject invalid token address", async function () {
            const amount = ethers.parseUnits("100", 6);
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 3600;
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            await expect(contract.connect(user1).createEscrowShield(amount, ethers.ZeroAddress, commitment, user2.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "EmptyToken");
        });
        it("Should reject invalid commitment", async function () {
            const amount = ethers.parseUnits("100", 6);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 3600;
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            await expect(contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), ethers.ZeroHash, user2.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject duplicate commitments", async function () {
            const amount = ethers.parseUnits("100", 6);
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 3600;
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount * 2n);
            // First escrow shield
            await contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, user2.address, confirmationPeriod, bloomFilter);
            // Try to create another escrow shield with same commitment
            await expect(contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, user3.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "CommitmentAlreadyExists");
        });
        it("Should reject invalid recipient", async function () {
            const amount = ethers.parseUnits("100", 6);
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 3600;
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            await expect(contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, ethers.ZeroAddress, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "InvalidRecipient");
        });
        it("Should reject confirmation period that's too short", async function () {
            const amount = ethers.parseUnits("100", 6);
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 1800; // 30 минут - меньше минимального
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            await expect(contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, user2.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "InvalidConfirmationPeriod");
        });
        it("Should reject confirmation period that's too long", async function () {
            const amount = ethers.parseUnits("100", 6);
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 31 * 24 * 60 * 60; // 31 день - больше максимального
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            await expect(contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, user2.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "InvalidConfirmationPeriod");
        });
        it("Should reject when paused", async function () {
            await contract.connect(admin).pause();
            const amount = ethers.parseUnits("100", 6);
            const commitment = ethers.randomBytes(32);
            const bloomFilter = ethers.randomBytes(32);
            const confirmationPeriod = 3600;
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            await expect(contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, user2.address, confirmationPeriod, bloomFilter)).to.be.revertedWithCustomError(contract, "EnforcedPause");
        });
        it("Should handle zero fee correctly", async function () {
            // Set fees to zero
            await contract.connect(admin).setFees(0n, 0n, 0n);
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const { secret, commitment, bloomFilter } = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.amount).to.equal(amount);
            expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(0n);
        });
    });
    describe("Confirm Escrow", function () {
        let commitment, secret, amount;
        beforeEach(async function () {
            amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600; // 1 час
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            commitment = escrow.commitment;
            secret = escrow.secret;
        });
        it("Should confirm escrow successfully", async function () {
            await expect(contract.connect(user1).confirmEscrow(commitment))
                .to.emit(contract, "EscrowConfirmed")
                .withArgs(commitment, user1.address);
            // Check escrow state
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.confirmed).to.be.true;
            expect(escrowShield.released).to.be.false;
            expect(escrowShield.cancelled).to.be.false;
            expect(escrowShield.spent).to.be.false;
            // Check escrow status
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Confirmed");
        });
        it("Should reject confirmation from non-sender", async function () {
            await expect(contract.connect(user2).confirmEscrow(commitment)).to.be.revertedWithCustomError(contract, "NotEscrowSender");
        });
        it("Should reject confirmation of non-existent escrow", async function () {
            const nonExistentCommitment = ethers.randomBytes(32);
            await expect(contract.connect(user1).confirmEscrow(nonExistentCommitment)).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
        });
        it("Should reject confirmation of regular shield", async function () {
            // Create regular shield
            const regularShield = await createTestShield(user1, amount);
            await expect(contract.connect(user1).confirmEscrow(regularShield.commitment)).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
        });
        it("Should reject double confirmation", async function () {
            // First confirmation
            await contract.connect(user1).confirmEscrow(commitment);
            // Try to confirm again
            await expect(contract.connect(user1).confirmEscrow(commitment)).to.be.revertedWithCustomError(contract, "EscrowAlreadyConfirmed");
        });
        it("Should reject confirmation after deadline", async function () {
            // Fast forward time beyond deadline
            await ethers.provider.send("evm_increaseTime", [3601]);
            await ethers.provider.send("evm_mine", []);
            await expect(contract.connect(user1).confirmEscrow(commitment)).to.be.revertedWithCustomError(contract, "ConfirmationDeadlinePassed");
        });
        it("Should reject confirmation of cancelled escrow", async function () {
            // Cancel escrow first
            await contract.connect(user1).cancelEscrow(commitment, secret);
            // Try to confirm
            await expect(contract.connect(user1).confirmEscrow(commitment)).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
        });
        it("Should reject confirmation of released escrow", async function () {
            // Confirm escrow first
            await contract.connect(user1).confirmEscrow(commitment);
            // Release escrow
            await contract.connect(user1).releaseEscrow(commitment, secret);
            // Try to confirm
            await expect(contract.connect(user1).confirmEscrow(commitment)).to.be.revertedWithCustomError(contract, "EscrowAlreadyConfirmed");
        });
        it("Should reject when paused", async function () {
            await contract.connect(admin).pause();
            await expect(contract.connect(user1).confirmEscrow(commitment)).to.be.revertedWithCustomError(contract, "EnforcedPause");
        });
    });
    describe("Release Escrow", function () {
        let commitment, secret, amount, expectedNetAmount;
        beforeEach(async function () {
            amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600; // 1 час
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            commitment = escrow.commitment;
            secret = escrow.secret;
            const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
            expectedNetAmount = amount - expectedFee;
            // Confirm escrow first
            await contract.connect(user1).confirmEscrow(commitment);
        });
        it("Should release escrow successfully", async function () {
            const initialBalance = await mockUSDC.balanceOf(user2.address);
            await expect(contract.connect(user1).releaseEscrow(commitment, secret))
                .to.emit(contract, "EscrowReleased")
                .withArgs(commitment, user2.address, expectedNetAmount);
            // Check recipient balance increased
            const finalBalance = await mockUSDC.balanceOf(user2.address);
            expect(finalBalance - initialBalance).to.equal(expectedNetAmount);
            // Check escrow state
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.released).to.be.true;
            expect(escrowShield.spent).to.be.true;
            // Check escrow status
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Released");
        });
        it("Should reject release with wrong secret", async function () {
            const wrongSecret = ethers.randomBytes(32);
            await expect(contract.connect(user1).releaseEscrow(commitment, wrongSecret)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject release of non-existent escrow", async function () {
            const nonExistentCommitment = ethers.randomBytes(32);
            const randomSecret = ethers.randomBytes(32);
            await expect(contract.connect(user1).releaseEscrow(nonExistentCommitment, randomSecret)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject release of regular shield", async function () {
            // Create regular shield
            const regularShield = await createTestShield(user1, amount);
            await expect(contract.connect(user1).releaseEscrow(regularShield.commitment, regularShield.secret)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject release without confirmation", async function () {
            // Create new escrow without confirmation
            const newEscrow = await createTestEscrowShield(user1, amount, user2.address, 3600);
            await expect(contract.connect(user1).releaseEscrow(newEscrow.commitment, newEscrow.secret)).to.be.revertedWithCustomError(contract, "EscrowNotConfirmed");
        });
        it("Should reject double release", async function () {
            // First release
            await contract.connect(user1).releaseEscrow(commitment, secret);
            // Try to release again
            await expect(contract.connect(user1).releaseEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "EscrowAlreadyReleased");
        });
        it("Should reject release of cancelled escrow", async function () {
            // Create new escrow and cancel it
            const newEscrow = await createTestEscrowShield(user1, amount, user2.address, 3600);
            await contract.connect(user1).cancelEscrow(newEscrow.commitment, newEscrow.secret);
            // Try to release
            await expect(contract.connect(user1).releaseEscrow(newEscrow.commitment, newEscrow.secret)).to.be.revertedWithCustomError(contract, "EscrowNotConfirmed");
        });
        it("Should reject when paused", async function () {
            await contract.connect(admin).pause();
            await expect(contract.connect(user1).releaseEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "EnforcedPause");
        });
    });
    describe("Cancel Escrow", function () {
        let commitment, secret, amount, expectedNetAmount;
        beforeEach(async function () {
            amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600; // 1 час
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            commitment = escrow.commitment;
            secret = escrow.secret;
            const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
            expectedNetAmount = amount - expectedFee;
        });
        it("Should cancel unconfirmed escrow successfully", async function () {
            const initialBalance = await mockUSDC.balanceOf(user1.address);
            await expect(contract.connect(user1).cancelEscrow(commitment, secret))
                .to.emit(contract, "EscrowCancelled")
                .withArgs(commitment, user1.address, expectedNetAmount);
            // Check sender balance increased
            const finalBalance = await mockUSDC.balanceOf(user1.address);
            expect(finalBalance - initialBalance).to.equal(expectedNetAmount);
            // Check escrow state
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.cancelled).to.be.true;
            expect(escrowShield.spent).to.be.true;
            // Check escrow status
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Cancelled");
        });
        it("Should cancel expired escrow successfully", async function () {
            // Confirm escrow first
            await contract.connect(user1).confirmEscrow(commitment);
            // Fast forward time beyond deadline
            await ethers.provider.send("evm_increaseTime", [3601]);
            await ethers.provider.send("evm_mine", []);
            const initialBalance = await mockUSDC.balanceOf(user1.address);
            await expect(contract.connect(user1).cancelEscrow(commitment, secret))
                .to.emit(contract, "EscrowCancelled")
                .withArgs(commitment, user1.address, expectedNetAmount);
            // Check sender balance increased
            const finalBalance = await mockUSDC.balanceOf(user1.address);
            expect(finalBalance - initialBalance).to.equal(expectedNetAmount);
            // Check escrow state
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.cancelled).to.be.true;
            expect(escrowShield.spent).to.be.true;
            // Check escrow status
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Cancelled");
        });
        it("Should reject cancel with wrong secret", async function () {
            const wrongSecret = ethers.randomBytes(32);
            await expect(contract.connect(user1).cancelEscrow(commitment, wrongSecret)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject cancel of non-existent escrow", async function () {
            const nonExistentCommitment = ethers.randomBytes(32);
            const randomSecret = ethers.randomBytes(32);
            await expect(contract.connect(user1).cancelEscrow(nonExistentCommitment, randomSecret)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject cancel of regular shield", async function () {
            // Create regular shield
            const regularShield = await createTestShield(user1, amount);
            await expect(contract.connect(user1).cancelEscrow(regularShield.commitment, regularShield.secret)).to.be.revertedWithCustomError(contract, "InvalidCommitment");
        });
        it("Should reject cancel from non-sender", async function () {
            await expect(contract.connect(user2).cancelEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "NotEscrowSender");
        });
        it("Should reject cancel of confirmed escrow before deadline", async function () {
            // Confirm escrow first
            await contract.connect(user1).confirmEscrow(commitment);
            // Try to cancel before deadline
            await expect(contract.connect(user1).cancelEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
        });
        it("Should reject double cancel", async function () {
            // First cancel
            await contract.connect(user1).cancelEscrow(commitment, secret);
            // Try to cancel again
            await expect(contract.connect(user1).cancelEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
        });
        it("Should reject cancel of released escrow", async function () {
            // Confirm and release escrow first
            await contract.connect(user1).confirmEscrow(commitment);
            await contract.connect(user1).releaseEscrow(commitment, secret);
            // Try to cancel
            await expect(contract.connect(user1).cancelEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
        });
        it("Should reject when paused", async function () {
            await contract.connect(admin).pause();
            await expect(contract.connect(user1).cancelEscrow(commitment, secret)).to.be.revertedWithCustomError(contract, "EnforcedPause");
        });
    });
    describe("Integration with Regular Shield Functions", function () {
        it("Should reject direct unshield of escrow shield", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            await expect(contract.connect(user1).unshield(escrow.secret, amount, user3.address, ethers.randomBytes(32))).to.be.revertedWithCustomError(contract, "CannotUnshieldEscrowDirectly");
        });
        it("Should reject direct transfer of escrow shield", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            const recipientCommitment = ethers.randomBytes(32);
            const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));
            const bloomFilter = ethers.randomBytes(32);
            await expect(contract.connect(user1).transfer(escrow.secret, amount, recipientCommitment, encryptedSecret, bloomFilter)).to.be.revertedWithCustomError(contract, "CannotTransferEscrowDirectly");
        });
        it("Should maintain backward compatibility with regular shields", async function () {
            // Create regular shield
            const amount = ethers.parseUnits("100", 6);
            const regularShield = await createTestShield(user1, amount);
            // Verify regular shield works normally
            const shieldInfo = await contract.getShieldInfo(regularShield.commitment);
            expect(shieldInfo.exists).to.be.true;
            expect(shieldInfo.amount).to.equal(amount - amount * SHIELD_FEE / FEE_DENOMINATOR);
            // Verify it's not an escrow
            const isActiveEscrow = await contract.isActiveEscrow(regularShield.commitment);
            expect(isActiveEscrow).to.be.false;
            // Regular unshield should work
            const newCommitment = ethers.randomBytes(32);
            const netAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;
            await expect(contract.connect(user1).unshield(regularShield.secret, netAmount, user2.address, newCommitment)).to.emit(contract, "Unshielded");
        });
        it("Should handle both regular and escrow shields simultaneously", async function () {
            // Create regular shield
            const regularAmount = ethers.parseUnits("100", 6);
            const regularShield = await createTestShield(user1, regularAmount);
            // Create escrow shield
            const escrowAmount = ethers.parseUnits("200", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, escrowAmount, user2.address, confirmationPeriod);
            // Verify both exist
            const regularShieldInfo = await contract.getShieldInfo(regularShield.commitment);
            expect(regularShieldInfo.exists).to.be.true;
            const escrowInfo = await contract.getEscrowShieldInfo(escrow.commitment);
            expect(escrowInfo.exists).to.be.true;
            expect(escrowInfo.isEscrow).to.be.true;
            // Verify different statuses
            const isActiveRegularEscrow = await contract.isActiveEscrow(regularShield.commitment);
            expect(isActiveRegularEscrow).to.be.false;
            const isActiveEscrow = await contract.isActiveEscrow(escrow.commitment);
            expect(isActiveEscrow).to.be.true;
            // Operations on regular shield should work
            const newCommitment = ethers.randomBytes(32);
            const netRegularAmount = regularAmount - regularAmount * SHIELD_FEE / FEE_DENOMINATOR;
            await contract.connect(user1).unshield(regularShield.secret, netRegularAmount, user3.address, newCommitment);
            // Operations on escrow should work
            await contract.connect(user1).confirmEscrow(escrow.commitment);
            await contract.connect(user1).releaseEscrow(escrow.commitment, escrow.secret);
        });
    });
    describe("Escrow View Functions", function () {
        let commitment, secret, amount, expectedNetAmount;
        beforeEach(async function () {
            amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            commitment = escrow.commitment;
            secret = escrow.secret;
            const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
            expectedNetAmount = amount - expectedFee;
        });
        it("Should return correct escrow shield info", async function () {
            const escrowShield = await contract.getEscrowShieldInfo(commitment);
            expect(escrowShield.exists).to.be.true;
            expect(escrowShield.isEscrow).to.be.true;
            expect(escrowShield.token).to.equal(await mockUSDC.getAddress());
            expect(escrowShield.amount).to.equal(expectedNetAmount);
            expect(escrowShield.sender).to.equal(user1.address);
            expect(escrowShield.recipient).to.equal(user2.address);
            expect(escrowShield.confirmed).to.be.false;
            expect(escrowShield.released).to.be.false;
            expect(escrowShield.cancelled).to.be.false;
            expect(escrowShield.spent).to.be.false;
            expect(escrowShield.timestamp).to.be.gt(0);
            expect(escrowShield.confirmationDeadline).to.be.gt(escrowShield.timestamp);
        });
        it("Should correctly identify active escrow", async function () {
            const isActive = await contract.isActiveEscrow(commitment);
            expect(isActive).to.be.true;
            // Cancel escrow
            await contract.connect(user1).cancelEscrow(commitment, secret);
            // Should no longer be active
            const isActiveAfterCancel = await contract.isActiveEscrow(commitment);
            expect(isActiveAfterCancel).to.be.false;
        });
        it("Should return correct status at different stages", async function () {
            // Initial status should be "Pending"
            let status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Pending");
            // Confirm escrow
            await contract.connect(user1).confirmEscrow(commitment);
            // Status should be "Confirmed"
            status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Confirmed");
            // Release escrow
            await contract.connect(user1).releaseEscrow(commitment, secret);
            // Status should be "Released"
            status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Released");
        });
        it("Should return 'Expired' status after deadline", async function () {
            // Fast forward time beyond deadline
            await ethers.provider.send("evm_increaseTime", [3601]);
            await ethers.provider.send("evm_mine", []);
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Expired");
        });
        it("Should return 'Nonexistent' for non-existent escrow", async function () {
            const nonExistentCommitment = ethers.randomBytes(32);
            const status = await contract.getEscrowStatus(nonExistentCommitment);
            expect(status).to.equal("Nonexistent");
            const isActive = await contract.isActiveEscrow(nonExistentCommitment);
            expect(isActive).to.be.false;
            const escrowInfo = await contract.getEscrowShieldInfo(nonExistentCommitment);
            expect(escrowInfo.exists).to.be.false;
            expect(escrowInfo.isEscrow).to.be.false;
        });
        it("Should return 'Cancelled' status for cancelled escrow", async function () {
            // Cancel escrow
            await contract.connect(user1).cancelEscrow(commitment, secret);
            const status = await contract.getEscrowStatus(commitment);
            expect(status).to.equal("Cancelled");
        });
    });
    describe("Security Tests", function () {
        it("Should prevent unauthorized access to escrow operations", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            // User3 should not be able to confirm
            await expect(contract.connect(user3).confirmEscrow(escrow.commitment)).to.be.revertedWithCustomError(contract, "NotEscrowSender");
            // User3 should not be able to release
            await expect(contract.connect(user3).releaseEscrow(escrow.commitment, escrow.secret)).to.be.revertedWithCustomError(contract, "EscrowNotConfirmed");
        });
        it("Should prevent replay attacks", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            // Confirm escrow
            await contract.connect(user1).confirmEscrow(escrow.commitment);
            // Release escrow
            await contract.connect(user1).releaseEscrow(escrow.commitment, escrow.secret);
            // Try to release again (replay attack)
            await expect(contract.connect(user1).releaseEscrow(escrow.commitment, escrow.secret)).to.be.revertedWithCustomError(contract, "EscrowAlreadyReleased");
        });
        it("Should handle edge cases with timing", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600; // 1 час
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            // Confirm escrow
            await contract.connect(user1).confirmEscrow(escrow.commitment);
            // Fast forward to just before deadline
            await ethers.provider.send("evm_increaseTime", [3599]);
            await ethers.provider.send("evm_mine", []);
            // Should still be able to release
            await expect(contract.connect(user1).releaseEscrow(escrow.commitment, escrow.secret)).to.emit(contract, "EscrowReleased");
            // Create new escrow for timing test
            const newEscrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            await contract.connect(user1).confirmEscrow(newEscrow.commitment);
            // Fast forward to exactly deadline
            await ethers.provider.send("evm_increaseTime", [1]);
            await ethers.provider.send("evm_mine", []);
            // Should still be able to release
            await expect(contract.connect(user1).releaseEscrow(newEscrow.commitment, newEscrow.secret)).to.emit(contract, "EscrowReleased");
        });
        it("Should handle multiple escrows for same users", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            // Create multiple escrows
            const escrow1 = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            const escrow2 = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            const escrow3 = await createTestEscrowShield(user1, amount, user3.address, confirmationPeriod);
            // Confirm all escrows
            await contract.connect(user1).confirmEscrow(escrow1.commitment);
            await contract.connect(user1).confirmEscrow(escrow2.commitment);
            await contract.connect(user1).confirmEscrow(escrow3.commitment);
            // Release all escrows
            await contract.connect(user1).releaseEscrow(escrow1.commitment, escrow1.secret);
            await contract.connect(user1).releaseEscrow(escrow2.commitment, escrow2.secret);
            await contract.connect(user1).releaseEscrow(escrow3.commitment, escrow3.secret);
            // Check final balances
            const user2Balance = await mockUSDC.balanceOf(user2.address);
            const user3Balance = await mockUSDC.balanceOf(user3.address);
            const expectedNetAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;
            // Users start with 10000 tokens, so we need to check the increase from that
            const initialBalance = ethers.parseUnits("10000", 6);
            expect(user2Balance - initialBalance).to.equal(expectedNetAmount * 2n); // Two escrows for user2
            expect(user3Balance - initialBalance).to.equal(expectedNetAmount); // One escrow for user3
        });
        it("Should handle minimum and maximum confirmation periods", async function () {
            const amount = ethers.parseUnits("100", 6);
            // Test minimum confirmation period (1 hour)
            const minEscrow = await createTestEscrowShield(user1, amount, user2.address, 3600);
            const minEscrowInfo = await contract.getEscrowShieldInfo(minEscrow.commitment);
            expect(minEscrowInfo.confirmationDeadline - minEscrowInfo.timestamp).to.equal(3600);
            // Test maximum confirmation period (30 days)
            const maxEscrow = await createTestEscrowShield(user1, amount, user2.address, 30 * 24 * 60 * 60);
            const maxEscrowInfo = await contract.getEscrowShieldInfo(maxEscrow.commitment);
            expect(maxEscrowInfo.confirmationDeadline - maxEscrowInfo.timestamp).to.equal(30 * 24 * 60 * 60);
        });
    });
    describe("Gas Optimization Tests", function () {
        it("Should use reasonable gas for escrow operations", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const escrow = await createTestEscrowShield(user1, amount, user2.address, confirmationPeriod);
            // Test confirmEscrow gas
            const confirmTx = await contract.connect(user1).confirmEscrow(escrow.commitment);
            const confirmReceipt = await confirmTx.wait();
            console.log(`confirmEscrow gas used: ${confirmReceipt.gasUsed}`);
            // Test releaseEscrow gas
            const releaseTx = await contract.connect(user1).releaseEscrow(escrow.commitment, escrow.secret);
            const releaseReceipt = await releaseTx.wait();
            console.log(`releaseEscrow gas used: ${releaseReceipt.gasUsed}`);
            // Gas should be reasonable (adjust based on actual implementation)
            expect(confirmReceipt.gasUsed).to.be.lt(100000n); // Less than 100k gas
            expect(releaseReceipt.gasUsed).to.be.lt(120000n); // Less than 120k gas
        });
        it("Should use reasonable gas for createEscrowShield", async function () {
            const amount = ethers.parseUnits("100", 6);
            const confirmationPeriod = 3600;
            const secret = ethers.randomBytes(32);
            const commitment = ethers.keccak256(ethers.solidityPacked(["bytes32", "address"], [secret, user1.address]));
            const bloomFilter = ethers.randomBytes(32);
            await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
            const tx = await contract.connect(user1).createEscrowShield(amount, await mockUSDC.getAddress(), commitment, user2.address, confirmationPeriod, bloomFilter);
            const receipt = await tx.wait();
            console.log(`createEscrowShield gas used: ${receipt.gasUsed}`);
            // Gas should be reasonable (adjust based on actual implementation)
            expect(receipt.gasUsed).to.be.lt(300000n); // Less than 300k gas
        });
    });
});
//# sourceMappingURL=LaserGun.escrow.test.js.map