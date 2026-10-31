// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @dev Schnorr-пермишлес конверта (LG2-p): R‖s над id ключом y_s.
import {Points} from "../../src/lib/Points.sol";
import {ILaserGunCore} from "../../src/interfaces/ILaserGunCore.sol";

library EnvelopeKit {
    /// @notice Подпись Schnorr: R = r·G; s = r − H(pub‖R‖id)·y (mod N);
    ///         проверка ядра: sG == R + cP.
    function schnorrSign(uint256 ySecret, bytes32 id)
        internal view
        returns (bytes memory sig)
    {
        uint256 r = (uint256(keccak256(abi.encodePacked(id, "r"))) % (Points.N - 1)) + 1;
        (uint256 rx, uint256 ry) = Points.mulG(r);
        bytes memory R = abi.encodePacked(rx, ry);
        // публичный ключ отправителя
        (uint256 px, uint256 py) = Points.mulG(ySecret);
        bytes memory pub = abi.encodePacked(px, py);
        bytes32 c = keccak256(abi.encodePacked(bytes5("LG2-p"), pub, R, id));
        // проверка ядра: sG == R + cP → s = r + c·y (mod N)
        uint256 s = addmod(r, mulmod(uint256(c), ySecret, Points.N), Points.N);
        sig = abi.encodePacked(R, bytes32(s));
    }
}
