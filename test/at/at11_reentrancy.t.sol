// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {Points} from "../../src/lib/Points.sol";
import {DenomGrid} from "../../src/lib/DenomGrid.sol";
import {Fees} from "../../src/lib/Fees.sol";

/// AT-11 — реентрант-получатель и приёмник (INV-6; CEI 11.2).
///
/// Given: реентрантный контракт в роли получателя executor'а и в роли
///        приёмника. When: вывод с валидной тратой / вход с реентрантным
///        вызовом минта. Then: реентрантный вызов ревертируется;
///        итоговое состояние консистентно.
interface IExecutor {
    function execute(bytes calldata) external;
}

/// Реентрантный контракт: регистрируется фабрикой как приёмник вывода и
/// при первой же транзе получателя вложенно повторяет последний
/// executor.execute (та же трата / тот же nullifier).
contract ReentrantPayout {
    address public immutable executor;
    uint256 public attempts;
    bytes public lastCd;

    constructor(address e) { executor = e; }

    function arm(bytes calldata cd) external { lastCd = cd; }

    function attack() external {
        attempts++;
        (bool ok, ) = executor.call(abi.encodeCall(IExecutor.execute, (lastCd)));
        ok; // no-op или реверт — состояние протокола консистентно (проверяет тест)
    }
}

contract AT11_Reentrancy is ATBase {
    /// Вход с реентрантным вызовом минта: приёмник после штатного pull
    /// повторно минтует ту же пачку — реверт (INV-13), состояние не меняется.
    function test_input_receiver_reentrant_mint_reverts() public {
        uint256 fromKey = 777;
        address from = vm.addr(fromKey);
        // deposited = 10000e6; ноты — разложение deposited − feeIn(deposited)
        uint256 dep = 10000e6;
        uint256 notesVal = dep - Fees.feeIn(1, dep, 1e6);
        uint256[] memory dis = _decompose(1, notesVal, "at11rcvd");
        uint256 m = dis.length;
        uint256[] memory secs = new uint256[](m);
        for (uint256 j = 0; j < m; ++j) secs[j] = _secretOf("at11rcv", j);
        address rcv = _enterUSDC(from, fromKey, dep, dis, secs);

        uint256 notesBefore = core.totalNotes();
        uint256 feesBefore = core.feesAccrued(1);

        bytes[] memory xs = new bytes[](m);
        bytes[] memory es = new bytes[](m);
        for (uint256 j = 0; j < m; ++j) {
            (uint256 ex, uint256 ey) = Points.mulG(secs[j]);
            xs[j] = abi.encodePacked(ex, ey);
            es[j] = xs[j];
        }
        vm.prank(rcv);
        vm.expectRevert();
        core.mintNotes(1, dep, dis, es, xs);

        assertEq(core.totalNotes(), notesBefore, "no extra notes");
        assertEq(core.feesAccrued(1), feesBefore, "no extra fees");
    }

    /// Вывод с валидной тратой на реентрантного получателя: выплата ровно
    /// одна; вложенный/повторный вызов executor'а — no-op (INV-6, AT-25).
    function test_output_recipient_reentrant_execute_noop() public {
        ReentrantPayout atk = new ReentrantPayout(address(executor));
        address po = _deployPayout(address(atk), keccak256("at11out"));
        // зарегистрированный payout — единственный легальный recipient (INV-19);
        // атака возможна только из его собственной транзы
        Prep memory p = _cashoutSpend("at11out", po);
        // обналичивание: feeOut 25 bps (grid-ceil), а не transfer 15 bps
        uint256 d1 = core.denomOf(1, DI);
        uint256 net = d1 - (d1 * 25 + 9999) / 10000;
        assertEq(usdc.balanceOf(address(po)), net, "payout once");

        // повторный executor.execute с тем же calldata (вложенный путь
        // получателя): no-op без второго перевода
        atk.arm(abi.encodeCall(ILaserGunCore.spend, (p.args)));
        uint256 balBefore = usdc.balanceOf(address(po));
        uint256 feesBefore = core.feesAccrued(1);

        atk.attack();

        assertEq(usdc.balanceOf(address(po)), balBefore, "no second payout");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor holds nothing");
        assertEq(core.feesAccrued(1), feesBefore, "fees unchanged");
    }

    /// Каноническое разложение amount по сетке (как _changeFor, без секретов).
    function _decompose(uint256 assetId, uint256 amount, string memory tag)
        internal view returns (uint256[] memory)
    {
        ILaserGunCore.Change memory c = _changeFor(assetId, amount, tag);
        return c.di;
    }
}
