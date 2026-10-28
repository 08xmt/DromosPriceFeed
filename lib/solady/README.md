# Solady math dependency

`src/utils/FixedPointMathLib.sol` is vendored from the current upstream
[Solady library](https://github.com/Vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol).
The upstream source is included without modifications, alongside its license.

The oracle calls its minimum, full-precision multiplication and division, rounding-up division,
integer square root, cube root and full-precision product square root directly.
