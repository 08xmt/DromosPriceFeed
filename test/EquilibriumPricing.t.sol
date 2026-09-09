// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockToken, MockVeloPool} from "./CappedVeloStableSwapOracle.t.sol";
import {MockChainlinkFeed} from "../src/MockChainlinkFeed.sol";
import {CappedVeloStableSwapOracle} from "../src/CappedVeloStableSwapOracle.sol";

contract EquilibriumHarness is CappedVeloStableSwapOracle {
    constructor(address _pool, address _feed) CappedVeloStableSwapOracle(_pool, _feed, _feed) {}

    function calculate(uint256 supply, uint256 p0, uint256 p1, uint256 x, uint256 y) external pure returns (uint256) {
        return _calculate_stable_lp_token_price(supply, p0, p1, x, y);
    }

    function cubeRootUp(uint256 n) external pure returns (uint256) {
        return _cbrtUp(n);
    }

    function invariant(uint256 x, uint256 y) external pure returns (uint256) {
        return _getK(x, y);
    }
}

contract EquilibriumPricingTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_USD = 1e8;
    uint256 internal constant RESERVE = 1_000_000e18;

    EquilibriumHarness internal oracle;

    function setUp() public {
        MockVeloPool pool = new MockVeloPool(address(new MockToken(18)), address(new MockToken(18)), true);
        MockChainlinkFeed feed = new MockChainlinkFeed(100_000_000);
        oracle = new EquilibriumHarness(address(pool), address(feed));
    }

    function testIndependentCanonicalReferences() public view {
        uint256[] memory cases = _references(".canonical");
        assertEq(cases.length % 3, 0);
        assertGt(cases.length / 3, 324);
        for (uint256 i; i < cases.length; i += 3) {
            uint256 answer = oracle.calculate(RESERVE, cases[i], cases[i + 1], RESERVE, RESERVE);
            uint256 expected = cases[i + 2];
            assertLe(answer, expected, "above equilibrium reference");
            assertApproxEqAbs(answer, expected, 1, "lost more than one output unit");
            // The smallest possible answer in this canonical pool is 2.
            assertGt(answer, 0, "positive feeds collapsed to zero");
        }
    }

    function testIndependentScaledReferences() public view {
        uint256[] memory cases = _references(".scaled");
        assertEq(cases.length % 6, 0);
        assertGt(cases.length, 0);
        for (uint256 i; i < cases.length; i += 6) {
            uint256 answer = oracle.calculate(cases[i + 4], cases[i], cases[i + 1], cases[i + 2], cases[i + 3]);
            uint256 expected = cases[i + 5];
            // max(1 output unit, ceil(reference * 1e-8)), for larger LP units.
            uint256 tolerance = (expected + ONE_USD - 1) / ONE_USD;
            if (tolerance == 0) tolerance = 1;
            assertLe(answer, expected, "above scaled equilibrium reference");
            assertApproxEqAbs(answer, expected, tolerance, "scaled error exceeds bound");
        }
    }

    function testSingleTokenDepegUsesEquilibriumValue() public view {
        assertEq(oracle.calculate(RESERVE, 50_000_000, ONE_USD, RESERVE, RESERVE), 123_164_345);
    }

    function testExactEquilibriumDoesNotOvervalueRedeemableReserves() public view {
        // x/y=3 gives a marginal price ratio of 7/9, matching $0.70/$0.90.
        uint256 answer = oracle.calculate(RESERVE, 70_000_000, 90_000_000, 3 * RESERVE, RESERVE);
        assertLe(answer, 300_000_000);
        assertApproxEqAbs(answer, 300_000_000, 1);
    }

    function testSharpDepegRegressions() public view {
        assertEq(oracle.calculate(RESERVE, 99_999, 99_999, RESERVE, RESERVE), 199_998);
        assertEq(oracle.calculate(RESERVE, 100_000, 100_000, RESERVE, RESERVE), 200_000);
        assertEq(oracle.calculate(RESERVE, 112_200, 112_200, RESERVE, RESERVE), 224_400);
        assertEq(oracle.calculate(RESERVE, 79, ONE_USD, RESERVE, RESERVE), 5_529);
        assertEq(oracle.calculate(RESERVE, 1, ONE_USD, RESERVE, RESERVE), 208);
        assertEq(oracle.calculate(RESERVE, 1, 1, RESERVE, RESERVE), 2);
    }

    function testRecoveryDoesNotMoveQuotesBackwards() public view {
        uint256[28] memory prices = [
            uint256(1),
            2,
            10,
            50,
            79,
            80,
            90,
            100,
            110,
            125,
            126,
            150,
            200,
            1_000,
            99_998,
            99_999,
            100_000,
            100_001,
            105_000,
            110_000,
            112_200,
            112_246,
            112_300,
            120_093,
            200_000,
            1_000_000,
            50_000_000,
            ONE_USD
        ];
        uint256 previousSingle;
        uint256 previousBoth;
        for (uint256 i; i < prices.length; ++i) {
            uint256 single = oracle.calculate(RESERVE, prices[i], ONE_USD, RESERVE, RESERVE);
            uint256 both = oracle.calculate(RESERVE, prices[i], prices[i], RESERVE, RESERVE);
            assertGe(single, previousSingle);
            assertGe(both, previousBoth);
            assertEq(both, 2 * prices[i]);
            previousSingle = single;
            previousBoth = both;
        }
    }

    function testInvariantPreservingReserveChangeLeavesQuoteUnchanged() public view {
        // The second state is the $0.50/$1.00 equilibrium on the same curve.
        uint256 balanced = oracle.calculate(1_000e18, 50_000_000, ONE_USD, 1_000e18, 1_000e18);
        uint256 skewed =
            oracle.calculate(1_000e18, 50_000_000, ONE_USD, 1_808_360626466468856376, 327_463138795830260795);
        assertEq(balanced, skewed);
    }

    function testMixedTokenDecimalsAndPublicFeedDuringDepeg() public {
        uint8[2] memory tokenDecimals = [uint8(6), uint8(18)];
        for (uint256 i; i < tokenDecimals.length; ++i) {
            for (uint256 j; j < tokenDecimals.length; ++j) {
                MockToken token0 = new MockToken(tokenDecimals[i]);
                MockToken token1 = new MockToken(tokenDecimals[j]);
                MockVeloPool pool = new MockVeloPool(address(token0), address(token1), true);
                uint256 scalar0 = 10 ** uint256(tokenDecimals[i]);
                uint256 scalar1 = 10 ** uint256(tokenDecimals[j]);
                pool.setTokenDecimals(scalar0, scalar1);
                pool.setState(RESERVE, 1_000_000 * scalar0, 1_000_000 * scalar1);
                MockChainlinkFeed feed0 = new MockChainlinkFeed(50_000_000);
                MockChainlinkFeed feed1 = new MockChainlinkFeed(100_000_000);
                CappedVeloStableSwapOracle source =
                    new CappedVeloStableSwapOracle(address(pool), address(feed0), address(feed1));
                assertEq(source.latestRoundAnswer(), 123_164_345);
                feed0.setAnswer(1);
                assertEq(source.latestRoundAnswer(), 208);
                feed1.setAnswer(1);
                assertEq(source.latestRoundAnswer(), 2);
            }
        }
    }

    function testZeroPricesSupplyAndReserves() public view {
        assertEq(oracle.calculate(0, ONE_USD, ONE_USD, RESERVE, RESERVE), 0);
        assertEq(oracle.calculate(RESERVE, 0, ONE_USD, RESERVE, RESERVE), 0);
        assertEq(oracle.calculate(RESERVE, ONE_USD, 0, RESERVE, RESERVE), 0);
        assertEq(oracle.calculate(RESERVE, ONE_USD, ONE_USD, 0, RESERVE), 0);
        assertEq(oracle.calculate(RESERVE, ONE_USD, ONE_USD, RESERVE, 0), 0);
    }

    function testLargestPositiveFeedAnswerIsCappedBeforeMath() public {
        MockVeloPool pool = new MockVeloPool(address(new MockToken(18)), address(new MockToken(18)), true);
        pool.setState(RESERVE, RESERVE, RESERVE);
        MockChainlinkFeed feed0 = new MockChainlinkFeed(type(int256).max);
        MockChainlinkFeed feed1 = new MockChainlinkFeed(1);
        CappedVeloStableSwapOracle source =
            new CappedVeloStableSwapOracle(address(pool), address(feed0), address(feed1));
        assertEq(source.latestRoundAnswer(), 208);
        feed1.setAnswer(type(int256).max);
        assertEq(source.latestRoundAnswer(), 200_000_000);
    }

    function testSmallInvariantAndFinalOutputQuantization() public view {
        // These zeros arise from invariant/output resolution, not low feed prices.
        uint256 tinyReserve = 26_700_000_000_000;
        assertEq(oracle.invariant(tinyReserve, tinyReserve), 1);
        assertEq(oracle.calculate(tinyReserve, ONE_USD, ONE_USD, tinyReserve, tinyReserve), 0);
        tinyReserve = 32_000_000_000_000;
        assertEq(oracle.invariant(tinyReserve, tinyReserve), 2);
        uint256 answer = oracle.calculate(tinyReserve, ONE_USD, ONE_USD, tinyReserve, tinyReserve);
        assertGt(answer, 0);
        assertLe(answer, 2 * ONE_USD);
        assertEq(oracle.calculate(1e40, ONE_USD, ONE_USD, RESERVE, RESERVE), 0);
    }

    function testFuzzCeilingCubeRoot(uint256 n) public view {
        n = bound(n, 0, 1e54);
        uint256 root = oracle.cubeRootUp(n);
        assertGe(root * root * root, n);
        if (root > 0) assertLt((root - 1) * (root - 1) * (root - 1), n);
    }

    function testCubeRootEndpoints() public view {
        assertEq(oracle.cubeRootUp(0), 0);
        assertEq(oracle.cubeRootUp(1), 1);
        assertEq(oracle.cubeRootUp(2), 2);
        assertEq(oracle.cubeRootUp(1e54 - 1), 1e18);
        assertEq(oracle.cubeRootUp(1e54), 1e18);
    }

    function testFuzzCubeRootAroundPerfectCubes(uint256 root) public view {
        root = bound(root, 2, 1e18 - 1);
        uint256 cube = root * root * root;
        assertEq(oracle.cubeRootUp(cube - 1), root);
        assertEq(oracle.cubeRootUp(cube), root);
        assertEq(oracle.cubeRootUp(cube + 1), root + 1);
    }

    function testFuzzInvariantMatchesPool(uint256 x, uint256 y) public view {
        x = bound(x, 0, 10_000_000e18);
        y = bound(y, 0, 10_000_000e18);
        uint256 a = x * y / WAD;
        uint256 b = x * x / WAD + y * y / WAD;
        assertEq(oracle.invariant(x, y), a * b / WAD);
    }

    function testFuzzSymmetricPricesAndReserves(uint256 p0, uint256 p1, uint256 x, uint256 y) public view {
        p0 = bound(p0, 1, ONE_USD);
        p1 = bound(p1, 1, ONE_USD);
        x = bound(x, 0, 10_000_000e18);
        y = bound(y, 0, 10_000_000e18);
        assertEq(oracle.calculate(RESERVE, p0, p1, x, y), oracle.calculate(RESERVE, p1, p0, y, x));
    }

    function testFuzzPriceMonotonicity(uint256 p0, uint256 p1, uint256 increasedP0) public view {
        p0 = bound(p0, 1, ONE_USD);
        p1 = bound(p1, 1, ONE_USD);
        increasedP0 = bound(increasedP0, p0, ONE_USD);
        assertGe(
            oracle.calculate(RESERVE, increasedP0, p1, RESERVE, RESERVE),
            oracle.calculate(RESERVE, p0, p1, RESERVE, RESERVE)
        );
    }

    function testFuzzAdjacentFeedAnswersAreMonotonic(uint256 p0, uint256 p1) public view {
        p0 = bound(p0, 1, ONE_USD - 1);
        p1 = bound(p1, 1, ONE_USD);
        // Small raw LP supply amplifies arithmetic errors in the per-LP quote.
        uint256 supply = RESERVE / 1e12;
        assertGe(
            oracle.calculate(supply, p0 + 1, p1, RESERVE, RESERVE), oracle.calculate(supply, p0, p1, RESERVE, RESERVE)
        );
    }

    function testFuzzProportionalLiquidityPreservesQuote(uint256 p0, uint256 p1, uint256 scale) public view {
        p0 = bound(p0, 1, ONE_USD);
        p1 = bound(p1, 1, ONE_USD);
        scale = bound(scale, 1, 100);
        assertApproxEqAbs(
            oracle.calculate(RESERVE, p0, p1, RESERVE, RESERVE),
            oracle.calculate(RESERVE * scale, p0, p1, RESERVE * scale, RESERVE * scale),
            1
        );
    }

    function testFuzzInvariantGrowthCannotLowerQuote(uint256 p0, uint256 p1, uint256 x, uint256 y, uint256 growth)
        public
        view
    {
        p0 = bound(p0, 1, ONE_USD);
        p1 = bound(p1, 1, ONE_USD);
        x = bound(x, 0, 10_000_000e18);
        y = bound(y, 0, 10_000_000e18);
        growth = bound(growth, 0, 10_000_000e18);
        assertGe(oracle.calculate(RESERVE, p0, p1, x + growth, y), oracle.calculate(RESERVE, p0, p1, x, y));
    }

    function testGasPricingSamples() public {
        uint256[4] memory prices = [uint256(ONE_USD), 99_000_000, 50_000_000, 1];
        for (uint256 i; i < prices.length; ++i) {
            oracle.calculate(RESERVE, prices[i], ONE_USD, RESERVE, RESERVE);
            uint256 start = gasleft();
            uint256 answer = oracle.calculate(RESERVE, prices[i], ONE_USD, RESERVE, RESERVE);
            uint256 used = start - gasleft();
            emit log_named_uint("token0 feed answer", prices[i]);
            emit log_named_uint("warm math call gas", used);
            emit log_named_uint("LP answer", answer);
        }
    }

    function _references(string memory key) internal view returns (uint256[] memory) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/equilibrium_reference.json"));
        return vm.parseJsonUintArray(json, key);
    }
}
