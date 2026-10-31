// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IWETHLike {
    function withdraw(uint256) external;
}

/// @title OutputReceiver
/// @notice Персональный иммутабельный counterfactual-приёмник вывода (10.2 ТЗ).
///          Единственная операция — sweep(assetId, to) по админ-ключу владельца:
///          адресат в состоянии не хранится и задаётся при каждом выводе,
///          поэтому смена адресата — очередной sweep, доступный в любой момент,
///          в том числе после выплаты (AT-24).
/// @dev Адреса активов — константы сборки (immutables), админ-ключ — immutable,
///          per-instance: входит в полный initcode и CREATE2-binding
///          (константный initcode дал бы всем приёмникам один ключ).
contract OutputReceiver {
    address public immutable admin; // админ-ключ владельца (аргумент конструктора)
    address public immutable usdc;
    address public immutable weth;

    error NotAdmin();
    error UnknownAsset();
    error SweepFailed();

    constructor(address admin_, address usdc_, address weth_) {
        admin = admin_;
        usdc = usdc_;
        weth = weth_;
    }

    /// @notice Вывод накопленного на сменный адресат to.
    /// @param assetId 1 = USDC (underlying), 2 = ETH (развёртка WETH в эфир
    ///          по выбору владельца — 10.2)
    function sweep(uint256 assetId, address to) external {
        if (msg.sender != admin) revert NotAdmin();
        if (assetId == 1) {
            _sweepToken(usdc, to);
        } else if (assetId == 2) {
            // ETH-ветка: приёмник хранит WETH; развёртка в эфир по выбору (10.2)
            uint256 bal = IERC20Like(weth).balanceOf(address(this));
            if (bal > 0) IWETHLike(weth).withdraw(bal);
            (bool ok, ) = to.call{value: address(this).balance}("");
            if (!ok) revert SweepFailed(); // blacklist адресата — локальный реверт (7.3)
        } else {
            revert UnknownAsset();
        }
    }

    function _sweepToken(address token, address to) internal {
        uint256 bal = IERC20Like(token).balanceOf(address(this));
        if (bal > 0) {
            if (!IERC20Like(token).transfer(to, bal)) revert SweepFailed();
        }
    }

    receive() external payable {} // прямые эфирные переводы — не путь протокола
}
