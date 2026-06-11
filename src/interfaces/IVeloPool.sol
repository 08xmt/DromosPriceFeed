// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";

//Compatible with aero/velodrome pools like https://basescan.org/address/0x8e9154ac849e839d60299e85156bcb589de2693a#code
interface IVeloPool is IERC20 {
    function metadata()
        external
        view
        returns (
            uint256 dec0,
            uint256 dec1,
            uint256 r0,
            uint256 r1,
            bool st,
            address t0,
            address t1
        );

    function decimals() external view returns (uint8);
}
