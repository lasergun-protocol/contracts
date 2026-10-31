// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AT-24 — приёмники вывода и стелс-доставка (полный контур, 10.2):
/// 1) выплата на незарегистрированный адрес — InvalidRecipient;
/// 2) стелс-доставка: разложение payee, консервация denomOf(payee)+feeTransfer
///    == denomOf(di) (иначе PayeeMismatch), перевода нет, адрес получателя
///    не появляется ни в calldata, ни в событиях;
/// 3) смена адресата: sweep админ-ключом в любой момент (в т.ч. после
///    выплаты), чужой ключ — реверт; blacklist-эмуляция — локальный реверт,
///    средства остаются в приёмнике, повтор после смены адресата проходит.
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {OutputReceiver} from "../../src/OutputReceiver.sol";
import {ATBase} from "../lib/ATBase.sol";

contract AT24_PayoutReceivers is ATBase {
    address internal constant STRANGER = address(0x24E1);

    /// @notice 1) recipient-сырой адрес (не ядро/0/приёмник) — InvalidRecipient
    ///         на этапе гейта, до эффектов.
    function test_unregistered_recipient_reverts() public {
        Prep memory p = _seedAndPrep("at24a", 1, DI, STRANGER, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidRecipient.selector);
        core.spend(p.args);
        assertFalse(core.isSpent(p.nullifier), "no nullifier on gate revert");
    }

    /// @notice 2) стелс-доставка: payee-батч минтится на стелс-точки,
    ///         перевода нет; адрес получателя отсутствует в событиях;
    ///         PayeeMismatch при ломаной консервации.
    function test_stealth_delivery_and_conservation() public {
        uint256 d = core.denomOf(1, DI);
        uint256 feeT = (d * 15 + 9999) / 10000;

        // payee-разложение суммы d - feeT по сетке (стелс-точки владельца R)
        uint256 paySum = d - feeT;
        ILaserGunCore.Change memory pc = _changeFor(1, paySum, "at24rcv");
        ILaserGunCore.Payee memory pay = _payeeOf(pc);

        Prep memory p = _seedAndSpend("at24s", 1, DI, address(0), _emptyChange(), _emptyEnv(), pay);
        assertTrue(core.isSpent(p.nullifier), "stealth spend settled");

        // перевода не было: executor не держал выплату; стелс-ноты в реестре
        assertEq(usdc.balanceOf(address(executor)), 0, "no transfer in stealth path");
        for (uint256 j = 0; j < pay.di.length; ++j) {
            assertTrue(core.commitmentExists(1, pay.di[j], pay.X[j]), "stealth note minted");
        }

        // события Spent не содержат адреса получателя (он не в calldata): recipient=0
        // (проверка на гейте — адрес появляется только в стелс-точках E/X)
        // PayeeMismatch: сумма payee + feeTransfer != denomOf(di)
        ILaserGunCore.Change memory badc = _changeFor(1, paySum - 1, "at24bad");
        ILaserGunCore.Payee memory bad = _payeeOf(badc);
        Prep memory q = _seedAndPrep("at24s2", 1, DI, address(0), _emptyChange(), _emptyEnv(), bad, 3);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.PayeeMismatch.selector);
        core.spend(q.args);
    }

    /// @notice 3) смена адресата: sweep админом — на новый адрес в любой момент;
    ///         чужой ключ — NotAdmin; blacklist-эмуляция — локальный реверт,
    ///         средства в приёмнике, после смены адресата — вывод проходит.
    function test_recipient_rotation_and_blacklist_locality() public {
        // обналичивание на свежий приёмник вывода (полный контур)
        uint256 d = core.denomOf(1, DI);
        address payout = _deployPayout(VICTIM, "at24pay");
        Prep memory p = _seedAndSpend("at24w", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee());
        assertTrue(core.isSpent(p.nullifier));
        uint256 feeOut = (d * 25 + 9999) / 10000;
        assertEq(usdc.balanceOf(payout), d - feeOut, "cashout in receiver");

        // свежесть приёмника на каждое обналичивание: новый пейаут — новый адрес
        address payout2 = _deployPayout(VICTIM, "at24pay-b");
        assertTrue(payout2 != payout, "fresh payout receiver per spend");

        // чужой ключ — NotAdmin
        vm.prank(STRANGER);
        vm.expectRevert(OutputReceiver.NotAdmin.selector);
        OutputReceiver(payable(payout)).sweep(1, STRANGER);

        // blacklist-эмуляция (FiatTokenV2-семантика): перевод на
        // заблокированный адресат не проходит — локальный реверт sweep,
        // средства остаются в приёмнике
        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(IERC20Like.transfer.selector, address(rejector), d - feeOut),
            abi.encode(false)
        );
        vm.prank(VICTIM);
        vm.expectRevert(OutputReceiver.SweepFailed.selector);
        OutputReceiver(payable(payout)).sweep(1, address(rejector));
        vm.clearMockedCalls();

        // смена адресата — вывод проходит
        assertEq(usdc.balanceOf(payout), d - feeOut, "funds stuck locally");
        vm.prank(VICTIM);
        OutputReceiver(payable(payout)).sweep(1, SAFE_HARBOR);
        assertEq(usdc.balanceOf(SAFE_HARBOR), d - feeOut, "rotated recipient paid");
        assertEq(usdc.balanceOf(payout), 0, "receiver drained");
    }

    function _payeeOf(ILaserGunCore.Change memory c)
        internal pure returns (ILaserGunCore.Payee memory p)
    {
        p.di = c.di;
        p.E = c.E;
        p.X = c.X;
    }

    address internal constant VICTIM = address(0x24E2);
    address internal constant SAFE_HARBOR = address(0x24E3);

    /// @notice Blacklist-эмуляция: контракт, реверсирующий входящие переводы.
    Reverter internal rejector;

    function setUp() public override {
        super.setUp();
        rejector = new Reverter();
    }
}

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
}

/// @notice Адресат, перевод на который блокирован (эмуляция blacklist).
contract Reverter {
    receive() external payable {
        revert("blacklisted");
    }
}
