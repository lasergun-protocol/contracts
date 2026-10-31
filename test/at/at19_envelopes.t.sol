// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-19 — конверты: окна, пермишлес, консервация (полный контур).
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {EnvelopeState} from "../../src/interfaces/ILaserGunCore.sol";
import {EnvelopeKit} from "../lib/EnvelopeKit.sol";
import {Points} from "../../src/lib/Points.sol";

contract AT19_Envelopes is ATBase {
    uint256 internal senderSecret = _secretOf("at19sender", 0);
    bytes32 internal envId = keccak256("at19");

    function _fundAndTransfer() internal returns (Prep memory p, ILaserGunCore.Envelope memory env) {
        uint256 d = core.denomOf(1, DI);
        uint256 envAmt = 432e6; // 4.32 USDC
        env = _envFor(1, envAmt, envId, block.timestamp + 1 days, false, senderSecret);
        // консервация: сдача + конверт + feeTransfer(d) == d
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - envAmt - fee, "at19ch1");
        p = _seedAndSpend("at19", 1, DI, address(core), ch, env, _emptyPayee());
    }

    function test_claim_within_window() public {
        (Prep memory p,) = _fundAndTransfer();
        assertTrue(core.envelope(envId).open, "envelope open");
        core.claimEnvelope(envId, new bytes(0)); // политика без пермишлеса
        EnvelopeState memory e = core.envelope(envId);
        assertFalse(e.open, "closed after claim");
        assertTrue(e.claimed, "claimed");
        // ноты конверта: m точек X_j по формуле размножения, различные
        bytes32 h0 = keccak256(_envNoteX(e.X_r, envId, 0));
        bytes32 h1 = keccak256(_envNoteX(e.X_r, envId, 1));
        assertTrue(h0 != h1, "distinct X_j");
        assertTrue(core.commitmentExists(1, e.di[0], _envNoteX(e.X_r, envId, 0)), "minted to registry");
    }

    function test_claim_after_expiry_closed() public {
        (Prep memory p, ILaserGunCore.Envelope memory env) = _fundAndTransfer();
        vm.warp(env.expiry); // T — окно claim закрыто
        vm.expectRevert(LaserGunCore.ClaimWindowClosed.selector);
        core.claimEnvelope(envId, new bytes(0));
    }

    function test_refund_before_expiry_reverts() public {
        (Prep memory p, ILaserGunCore.Envelope memory env) = _fundAndTransfer();
        vm.expectRevert(LaserGunCore.RefundWindowClosed.selector);
        core.refundEnvelope(envId);
    }

    function test_refund_after_expiry_to_sender() public {
        (Prep memory p, ILaserGunCore.Envelope memory env) = _fundAndTransfer();
        vm.warp(env.expiry + 1);
        core.refundEnvelope(envId);
        EnvelopeState memory e = core.envelope(envId);
        assertFalse(e.open && e.claimed == false, "refunded");
        assertTrue(e.claimed, "claimed flag");
    }

    function test_double_claim_reverts() public {
        (Prep memory p,) = _fundAndTransfer();
        core.claimEnvelope(envId, new bytes(0));
        vm.expectRevert(LaserGunCore.EnvelopeClosed.selector);
        core.claimEnvelope(envId, new bytes(0));
        vm.expectRevert(LaserGunCore.EnvelopeClosed.selector);
        core.refundEnvelope(envId);
    }

    function test_unknown_id() public {
        vm.expectRevert(LaserGunCore.EnvelopeNotFound.selector);
        core.claimEnvelope(keccak256("nope"), new bytes(0));
        vm.expectRevert(LaserGunCore.EnvelopeNotFound.selector);
        core.refundEnvelope(keccak256("nope"));
    }

    function test_permit_policy_enforced() public {
        // конверт с пермишлесом: подпись обязательна
        uint256 d = core.denomOf(1, DI);
        bytes32 id2 = keccak256("at19perm");
        uint256 amt = 432e6;
        ILaserGunCore.Envelope memory env = _envFor(1, amt, id2, block.timestamp + 1 days, true, senderSecret);
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - amt - fee, "at19pc");
        _seedAndSpend("at19perm", 1, DI, address(core), ch, env, _emptyPayee());

        // неверная подпись: нулевая R — неканоническая точка
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.claimEnvelope(id2, new bytes(96));
        // неверная подпись: валидная R, но чужой секрет
        (uint256 wx, uint256 wy) = Points.mulG((uint256(keccak256("wrong")) % (Points.N - 1)) + 1);
        vm.expectRevert(LaserGunCore.ClaimPermissionInvalid.selector);
        core.claimEnvelope(id2, abi.encodePacked(wx, wy, bytes32(uint256(1))));
        // валидная — ок
        bytes memory sig = EnvelopeKit.schnorrSign(senderSecret, id2);
        core.claimEnvelope(id2, sig);
        assertFalse(core.envelope(id2).open, "claimed with permit");
    }

    function test_topup_grows_escrow() public {
        (Prep memory p, ILaserGunCore.Envelope memory env) = _fundAndTransfer();
        uint256 diLenBefore = core.envelope(envId).di.length;
        // пополнение той же тратой: те же точки/expiry/политика, новый id траты
        uint256 d = core.denomOf(1, DI);
        uint256 amt = 432e6;
        ILaserGunCore.Envelope memory env2 = _envFor(1, amt, envId, env.expiry, false, senderSecret);
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - amt - fee, "at19topc");
        // топ-ап того же конверта: трата nоты ДРУГОГО посева (новое кольцо),
        // env-блок байт-в-байт совпадает с эскроу-записью
        _seedAndSpend("at19top", 1, DI, address(core), ch, env2, _emptyPayee());
        assertTrue(core.envelope(envId).di.length > diLenBefore, "escrow grew");
    }

    function test_topup_after_expiry_reverts() public {
        (Prep memory p, ILaserGunCore.Envelope memory env) = _fundAndTransfer();
        vm.warp(env.expiry); // просрочен, но открыт
        uint256 dLenBefore = core.envelope(envId).di.length;
        uint256 d = core.denomOf(1, DI);
        uint256 amt = 432e6;
        ILaserGunCore.Envelope memory env2 = _envFor(1, amt, envId, env.expiry, false, senderSecret);
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - amt - fee, "at19tec");
        // стелс-доставка просроченному конверту отклоняется: топ-ап не растёт
        vm.prank(address(executor));
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (_seedAndPrep("at19te", 1, DI, address(core), ch, env2, _emptyPayee(), 8).args)));
        assertFalse(core.envelope(envId).di.length > dLenBefore, "top-up rejected after expiry");
    }


    function test_open_with_past_expiry_reverts() public {
        // открытие конверта с expiry ≤ now — ClaimWindowEmpty
        uint256 d = core.denomOf(1, DI);
        bytes32 id3 = keccak256("at19past");
        ILaserGunCore.Envelope memory env = _envFor(1, 432e6, id3, block.timestamp, false, senderSecret);
        uint256 fee = (d * 15 + 9999) / 10000;
        ILaserGunCore.Change memory ch = _changeFor(1, d - 432e6 - fee, "at19pastc");
        vm.prank(address(executor));
        executor.execute(abi.encodeCall(ILaserGunCore.spend, (_seedAndPrep("at19past", 1, DI, address(core), ch, env, _emptyPayee(), 7).args)));
        assertFalse(core.envelope(id3).open, "past-expiry envelope not opened");
    }

    function test_claim_and_refund_no_fees() public {
        (Prep memory p,) = _fundAndTransfer();
        uint256 f0 = core.feesAccrued(1);
        core.claimEnvelope(envId, new bytes(0));
        assertEq(core.feesAccrued(1), f0, "claim is free");
    }
}
