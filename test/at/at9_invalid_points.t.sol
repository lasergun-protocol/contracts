// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// AT-9 — InvalidPoint / InvalidSignature / InvalidRecipient до изменений состояния:
/// неканонические точки (вне кривой, (0,0), координата ≥ p, длина), hp с
/// нарушением деривации, recipient=0 без стелс-доставки (минт и трата).
import {ATBase} from "../lib/ATBase.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";
import {LaserGunCore} from "../../src/LaserGunCore.sol";
import {Points} from "../../src/lib/Points.sol";
import {SolLSAG} from "../lib/SolLSAG.sol";
import {Receiver} from "../../src/Receiver.sol";

contract AT9_InvalidPoints is ATBase {
    uint256 internal constant P = Points.P;

    function test_point_off_curve() public {
        address payout = _deployPayout(address(0xA9), "at9a");
        Prep memory p = _seedAndPrep("at9a", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        p.args.ring[3] = abi.encodePacked(uint256(5), uint256(5)); // не on-curve
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.spend(p.args);
    }

    function test_point_zero() public {
        address payout = _deployPayout(address(0xA9), "at9b");
        Prep memory p = _seedAndPrep("at9b", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        p.args.ring[0] = abi.encodePacked(uint256(0), uint256(0)); // бесконечность
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.spend(p.args);
    }

    function test_coordinate_ge_p() public {
        address payout = _deployPayout(address(0xA9), "at9c");
        Prep memory p = _seedAndPrep("at9c", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        p.args.ring[1] = abi.encodePacked(P, uint256(2)); // x ≥ p
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.spend(p.args);
    }

    function test_wrong_length_point() public {
        address payout = _deployPayout(address(0xA9), "at9d");
        Prep memory p = _seedAndPrep("at9d", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        p.args.ring[2] = hex"010203"; // не 64 байта
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.spend(p.args);
    }

    function test_hp_derivation_violated() public {
        address payout = _deployPayout(address(0xA9), "at9e");
        Prep memory p = _seedAndPrep("at9e", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        // hp[4] не является деривацией Hp(ring[4]) (валидная точка, но чужая)
        p.args.hp[4] = _ptOf(_secretOf("other", 9));
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.spend(p.args);
    }

    function test_noncanonical_scalar() public {
        address payout = _deployPayout(address(0xA9), "at9f");
        Prep memory p = _seedAndPrep("at9f", 1, DI, payout, _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        p.args.c1 = bytes32(Points.N); // ≥ порядок кривой
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidSignature.selector);
        core.spend(p.args);
    }

    function test_recipient_zero_without_stealth() public {
        // трата «в никуда» без payee: InvalidRecipient
        Prep memory p = _seedAndPrep("at9g", 1, DI, address(0), _emptyChange(), _emptyEnv(), _emptyPayee(), 7);
        vm.prank(address(executor));
        vm.expectRevert(LaserGunCore.InvalidRecipient.selector);
        core.spend(p.args);
    }

    function test_mint_invalid_point_no_state() public {
        // минт с неканонической точкой — InvalidPoint, счётчики не изменились
        uint256 totalBefore = core.totalNotes();
        uint256[] memory di = new uint256[](1);
        di[0] = 0; // номинал 0.000001 USDC → notes=1; feeIn(2)=0 (меньше мин. номинала)

        bytes[] memory es = new bytes[](1);
        bytes[] memory xs = new bytes[](1);
        es[0] = _ptOf(3);
        xs[0] = abi.encodePacked(uint256(7), uint256(7)); // вне кривой
        address rcv = _deployReceiverRaw(1, di, es, xs);
        vm.prank(rcv);
        vm.expectRevert(LaserGunCore.InvalidPoint.selector);
        core.mintNotes(1, 1, di, es, xs); // deposited=1 микро, di[0]=0 → notes=1, fee=0... подберём: feeIn(1000)=1 → notes=999; di=[27]=1000 → FeeMismatch
        assertEq(core.totalNotes(), totalBefore, "no state change");
    }

    /// @dev Приёмник без легального pull — только регистрация адреса для минта.
    function _deployReceiverRaw(uint256 assetId, uint256[] memory di, bytes[] memory es, bytes[] memory xs)
        internal returns (address)
    {
        bytes memory initcode = abi.encodePacked(
            type(Receiver).creationCode,
            abi.encode(address(core), address(pool), address(usdc), treasury, assetId, uint256(0), di, es, xs)
        );
        bytes32 salt = keccak256(abi.encode("at9raw", es, xs));
        return factory.create2(salt, initcode, false);
    }
}
