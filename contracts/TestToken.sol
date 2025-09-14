// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestToken
 * @dev Простой ERC20 токен для тестирования LaserGun в Amoy тестнете
 * Особенности:
 * - Владелец может минтить токены
 * - Фиксированный supply при деплое
 * - Публичный faucet для тестов
 */
contract TestToken is ERC20, Ownable {
    uint8 private _decimals;
    uint256 public constant FAUCET_AMOUNT = 1000; // 1000 токенов за запрос
    mapping(address => uint256) public lastFaucetClaim;
    uint256 public constant FAUCET_COOLDOWN = 1 hours; // Cooldown между запросами

    event FaucetClaimed(address indexed user, uint256 amount);

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _decimals = decimals_;
        
        // Минтим начальный supply владельцу
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply * 10**decimals_);
        }
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Минт токенов владельцем
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Публичный faucet для получения тестовых токенов
     * Любой может получить FAUCET_AMOUNT токенов раз в час
     */
    function faucet() external {
        require(
            block.timestamp >= lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN,
            "Faucet cooldown not expired"
        );
        
        lastFaucetClaim[msg.sender] = block.timestamp;
        uint256 amount = FAUCET_AMOUNT * 10**_decimals;
        
        _mint(msg.sender, amount);
        emit FaucetClaimed(msg.sender, amount);
    }

    /**
     * @dev Проверить когда можно снова использовать faucet
     */
    function nextFaucetTime(address user) external view returns (uint256) {
        uint256 lastClaim = lastFaucetClaim[user];
        if (lastClaim == 0) {
            return block.timestamp; // Можно сразу
        }
        
        uint256 nextTime = lastClaim + FAUCET_COOLDOWN;
        return nextTime > block.timestamp ? nextTime : block.timestamp;
    }

    /**
     * @dev Можно ли сейчас использовать faucet
     */
    function canUseFaucet(address user) external view returns (bool) {
        return block.timestamp >= lastFaucetClaim[user] + FAUCET_COOLDOWN;
    }

    /**
     * @dev Burn токенов (для тестов)
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Владелец может забрать токены обратно (для тестов)
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = balanceOf(address(this));
        if (balance > 0) {
            _transfer(address(this), owner(), balance);
        }
    }
}