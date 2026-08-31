// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";

// Compatible with Dromos V3 V2_STABLE pools.
interface IVeloPool is IERC20 {
    function metadata()
        external
        view
        returns (uint256 dec0, uint256 dec1, uint256 r0, uint256 r1, address t0, address t1);

    function POOL_TYPE() external view returns (bytes32);

    function decimals() external view returns (uint8);
}
