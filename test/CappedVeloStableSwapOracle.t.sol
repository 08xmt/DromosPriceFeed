// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockChainlinkFeed} from "../src/MockChainlinkFeed.sol";
import {CappedVeloStableSwapOracle} from "../src/CappedVeloStableSwapOracle.sol";
import {IChainLinkOracle} from "../src/interfaces/IChainLinkOracle.sol";

contract MockToken {
    uint8 public immutable decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }
}

contract MockVeloPool {
    bytes32 internal constant STABLE_POOL_TYPE = "V2_STABLE";
    bytes32 internal constant VOLATILE_POOL_TYPE = "V2_VOLATILE";

    address public immutable token0;
    address public immutable token1;
    bytes32 public immutable POOL_TYPE;

    uint8 internal lpDecimals = 18;
    uint256 public totalSupply;
    uint256 internal decimals0;
    uint256 internal decimals1;
    uint256 internal reserve0;
    uint256 internal reserve1;

    constructor(address _token0, address _token1, bool _stable) {
        token0 = _token0;
        token1 = _token1;
        POOL_TYPE = _stable ? STABLE_POOL_TYPE : VOLATILE_POOL_TYPE;
        decimals0 = 1e18;
        decimals1 = 1e18;
        totalSupply = 1e18;
        reserve0 = 1e18;
        reserve1 = 1e18;
    }

    function setState(uint256 _totalSupply, uint256 _reserve0, uint256 _reserve1) external {
        totalSupply = _totalSupply;
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    function setTokenDecimals(uint256 _decimals0, uint256 _decimals1) external {
        decimals0 = _decimals0;
        decimals1 = _decimals1;
    }

    function setLpDecimals(uint8 _lpDecimals) external {
        lpDecimals = _lpDecimals;
    }

    function metadata()
        external
        view
        returns (uint256 dec0, uint256 dec1, uint256 r0, uint256 r1, address t0, address t1)
    {
        return (decimals0, decimals1, reserve0, reserve1, token0, token1);
    }

    function decimals() external view returns (uint8) {
        return lpDecimals;
    }
}

/// @dev Velodrome/Aerodrome V2 metadata() shape: seven fields, with `bool stable` at index 4.
/// Decoded against the six-field IVeloPool signature this silently yields token0 = address(1).
contract SevenFieldVeloPool {
    address public immutable token0;
    address public immutable token1;
    bytes32 public constant POOL_TYPE = "V2_STABLE";

    uint256 public totalSupply = 1e18;
    uint256 internal reserve0 = 1e18;
    uint256 internal reserve1 = 1e18;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function metadata() external view returns (uint256, uint256, uint256, uint256, bool, address, address) {
        return (1e18, 1e18, reserve0, reserve1, true, token0, token1);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract FlexibleChainlinkFeed is IChainLinkOracle {
    uint8 internal immutable feedDecimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        feedDecimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        roundId += 1;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract RevertingChainlinkFeed is IChainLinkOracle {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed unavailable");
    }
}

contract CappedVeloStableSwapOracleTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_USD = 100_000_000;

    function setUp() public {
        vm.warp(10 days);
    }

    function testMockChainlinkFeedUpdates() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(int256(ONE_USD));

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(feed.decimals(), 8);
        assertEq(roundId, 1);
        assertEq(answer, int256(ONE_USD));
        assertEq(startedAt, updatedAt);
        assertEq(answeredInRound, 1);

        vm.warp(block.timestamp + 1);
        feed.setAnswer(95_000_000);
        (, int256 updatedAnswer,, uint256 secondUpdatedAt,) = feed.latestRoundData();
        assertEq(feed.roundId(), 2);
        assertEq(updatedAnswer, 95_000_000);
        assertGt(secondUpdatedAt, updatedAt);

        vm.warp(block.timestamp + 1);
        feed.refresh();
        (, int256 refreshedAnswer,, uint256 refreshedAt,) = feed.latestRoundData();
        assertEq(feed.roundId(), 3);
        assertEq(refreshedAnswer, 95_000_000);
        assertGt(refreshedAt, secondUpdatedAt);

        vm.expectRevert(bytes("Invalid answer"));
        feed.setAnswer(0);
    }

    function testStableLpOracleExposesPriceFeed() public {
        (, MockChainlinkFeed feed0, MockChainlinkFeed feed1, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            source.latestRoundData();
        uint256 sourcePrice = _currentPoolPrice(source);

        assertEq(feed0.decimals(), 8);
        assertEq(feed1.decimals(), 8);
        assertEq(source.decimals(), 8);
        assertEq(roundId, 0);
        assertEq(answer, int256(sourcePrice));
        assertEq(source.latestRoundAnswer(), answer);
        assertEq(startedAt, updatedAt);
        assertEq(answeredInRound, 0);
    }

    function testStableLpOraclePassesThroughZeroAnswer() public {
        (MockVeloPool pool,,, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        pool.setState(0, WAD, WAD);
        (, int256 zeroAnswer,, uint256 zeroUpdatedAt,) = source.latestRoundData();
        assertEq(zeroAnswer, 0);
        assertEq(source.latestRoundAnswer(), zeroAnswer);
        assertEq(zeroUpdatedAt, block.timestamp);
    }

    function testTokenPricesAreCappedAtOneUsd() public {
        (, MockChainlinkFeed feed0, MockChainlinkFeed feed1, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        _set(feed0, feed1, 110_000_000, 120_000_000);

        (uint256 price0, uint256 price1) = source.getTokenPrices();
        assertEq(price0, ONE_USD);
        assertEq(price1, ONE_USD);
        assertApproxEqAbs(_currentPoolPrice(source), 2 * ONE_USD, 10);
    }

    function testTokenPriceCapPreservesBelowOneUsdPrices() public {
        (, MockChainlinkFeed feed0, MockChainlinkFeed feed1, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        _set(feed0, feed1, 110_000_000, 95_000_000);

        (uint256 price0, uint256 price1) = source.getTokenPrices();
        assertEq(price0, ONE_USD);
        assertEq(price1, 95_000_000);
        assertLt(_currentPoolPrice(source), 2 * ONE_USD);
    }

    function testScenarioGridReturnsRows() public {
        (, MockChainlinkFeed feed0, MockChainlinkFeed feed1, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        uint256[2] memory price0Answers = [ONE_USD, uint256(99_000_000)];
        uint256[2] memory price1Answers = [ONE_USD, uint256(101_000_000)];
        uint256 rows;

        for (uint256 i = 0; i < price0Answers.length; i++) {
            for (uint256 j = 0; j < price1Answers.length; j++) {
                (bool ok, string memory error, uint256 freshPrice, uint256 feedPrice) =
                    _runScenario(address(feed0), address(feed1), address(source), price0Answers[i], price1Answers[j]);

                assertTrue(ok);
                assertEq(bytes(error).length, 0);
                assertGt(freshPrice, 0);
                assertEq(feedPrice, freshPrice);
                rows += 1;
            }
        }
        assertEq(rows, 4);
    }

    function testConstructorRejectsInvalidFeedConfigurations() public {
        MockVeloPool pool = _newPool();
        MockVeloPool nonStablePool = _newPool(false);
        MockChainlinkFeed feed = new MockChainlinkFeed(int256(ONE_USD));
        FlexibleChainlinkFeed badDecimalsFeed = new FlexibleChainlinkFeed(18, int256(ONE_USD));

        vm.expectRevert(bytes("Pool must be stable"));
        _deploySource(nonStablePool, address(feed), address(feed));

        vm.expectRevert(bytes("Both tokens must have CL oracle"));
        _deploySource(pool, address(0), address(0));

        vm.expectRevert(bytes("Both tokens must have CL oracle"));
        _deploySource(pool, address(feed), address(0));

        vm.expectRevert(bytes("Must be 8 decimals"));
        _deploySource(pool, address(badDecimalsFeed), address(feed));
    }

    function testConstructorRejectsRawDecimalCountsInMetadata() public {
        // dec0/dec1 as the raw decimal count instead of 10 ** decimals. Left unchecked this
        // inflates the normalized reserves, and the LP price with them, by 1e6 / 6 = 166,666x.
        MockVeloPool pool = _newPoolWithTokenDecimals(6, 6, 6);
        MockChainlinkFeed feed0 = new MockChainlinkFeed(int256(ONE_USD));
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));

        vm.expectRevert(bytes("Bad metadata decimals"));
        _deploySource(pool, address(feed0), address(feed1));
    }

    function testConstructorRejectsHalfMismatchedMetadataDecimals() public {
        MockVeloPool pool = _newPoolWithTokenDecimals(6, 1e6, 6);
        MockChainlinkFeed feed0 = new MockChainlinkFeed(int256(ONE_USD));
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));

        vm.expectRevert(bytes("Bad metadata decimals"));
        _deploySource(pool, address(feed0), address(feed1));
    }

    function testConstructorRejectsSevenFieldMetadataLayout() public {
        MockToken token0 = new MockToken(18);
        MockToken token1 = new MockToken(18);
        SevenFieldVeloPool pool = new SevenFieldVeloPool(address(token0), address(token1));
        MockChainlinkFeed feed0 = new MockChainlinkFeed(int256(ONE_USD));
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));

        // The `bool stable` word decodes as address(1), which holds no code.
        vm.expectRevert(bytes("Bad metadata layout"));
        new CappedVeloStableSwapOracle(address(pool), address(feed0), address(feed1));
    }

    function testFairReservePricingWithSixDecimalTokens() public {
        // The normalization branch at fairReservesPriceData() is only exercised when dec0 != 1e18.
        MockVeloPool pool = _newPoolWithTokenDecimals(6, 1e6, 1e6);
        MockChainlinkFeed feed0 = new MockChainlinkFeed(int256(ONE_USD));
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));
        CappedVeloStableSwapOracle source = _deploySource(pool, address(feed0), address(feed1));

        pool.setState(50_000e18, 50_000e6, 50_000e6);

        assertApproxEqAbs(_currentPoolPrice(source), 2 * ONE_USD, 10);
    }

    function testChainlinkPricePassesThroughStaleAndBadData() public {
        MockVeloPool pool = _newPool();
        FlexibleChainlinkFeed feed0 = new FlexibleChainlinkFeed(8, int256(ONE_USD));
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));
        CappedVeloStableSwapOracle source = _deploySource(pool, address(feed0), address(feed1));
        uint256 staleUpdatedAt = feed0.updatedAt();

        vm.warp(block.timestamp + 10 days + 1);
        assertEq(source.getChainlinkPrice(0), ONE_USD);
        (, int256 staleAnswer,, uint256 oracleUpdatedAt,) = source.latestRoundData();
        assertGt(staleAnswer, 0);
        assertEq(oracleUpdatedAt, staleUpdatedAt);

        feed0.setAnswer(-1);
        assertEq(source.getChainlinkPrice(0), 0);
        assertEq(_currentPoolPrice(source), 0);
        (, int256 badAnswer,,,) = source.latestRoundData();
        assertEq(badAnswer, 0);
    }

    function testChainlinkTokenIndexMustBeZeroOrOne() public {
        (,,, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        vm.expectRevert(bytes("bad index"));
        source.getChainlinkPrice(2);

        vm.expectRevert(bytes("bad index"));
        source.chainlinkPriceLastUpdated(2);
    }

    function testChainlinkPriceRevertsWhenFeedCallReverts() public {
        MockVeloPool pool = _newPool();
        RevertingChainlinkFeed feed0 = new RevertingChainlinkFeed();
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));
        CappedVeloStableSwapOracle source = _deploySource(pool, address(feed0), address(feed1));

        vm.expectRevert(bytes("feed unavailable"));
        source.getChainlinkPrice(0);

        vm.expectRevert(bytes("feed unavailable"));
        source.chainlinkPriceLastUpdated(0);

        vm.expectRevert(bytes("feed unavailable"));
        _currentPoolPrice(source);

        vm.expectRevert(bytes("feed unavailable"));
        source.latestRoundData();
    }

    function testFairReservePricingAtParity() public {
        (,,, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        assertApproxEqAbs(_currentPoolPrice(source), 2 * ONE_USD, 10);
    }

    function testFairReservePricingReturnsZeroWhenTotalSupplyIsZero() public {
        (MockVeloPool pool,,, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        pool.setState(0, WAD, WAD);

        assertEq(_currentPoolPrice(source), 0);
        (, int256 answer,,,) = source.latestRoundData();
        assertEq(answer, 0);
    }

    function testFairReservePricingStableAcrossInvariantPreservingReserveEdges() public {
        (MockVeloPool pool,,, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();
        uint256 baselinePrice = _currentPoolPrice(source);
        uint256 targetK = _stableK(WAD, WAD);
        uint256[4] memory scarceReserves = [uint256(1), uint256(1e6), uint256(1e9), uint256(1e12)];

        assertApproxEqAbs(baselinePrice, 2 * ONE_USD, 10);

        for (uint256 i = 0; i < scarceReserves.length; i++) {
            uint256 scarceReserve = scarceReserves[i];
            uint256 pairedReserve = _reserveForStableK(scarceReserve, targetK);

            pool.setState(WAD, scarceReserve, pairedReserve);
            assertApproxEqAbs(_currentPoolPrice(source), baselinePrice, 1_000);

            pool.setState(WAD, pairedReserve, scarceReserve);
            assertApproxEqAbs(_currentPoolPrice(source), baselinePrice, 1_000);
        }
    }

    function testFairReservePricingDoesNotOverstateValueAtReserveBoundaries() public {
        (MockVeloPool pool,,, CappedVeloStableSwapOracle source) = _deployTwoFeedSource();

        _assertDoesNotOverstateReserveValue(pool, source, 0, WAD);
        _assertDoesNotOverstateReserveValue(pool, source, WAD, 0);
        _assertDoesNotOverstateReserveValue(pool, source, 1, WAD);
        _assertDoesNotOverstateReserveValue(pool, source, WAD, 1);
        _assertDoesNotOverstateReserveValue(pool, source, 1, 1e30);
        _assertDoesNotOverstateReserveValue(pool, source, 1e30, 1);
    }

    function testLpTokenMustHaveEighteenDecimals() public {
        MockVeloPool pool = _newPool();
        MockChainlinkFeed feed0 = new MockChainlinkFeed(int256(ONE_USD));
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));
        pool.setLpDecimals(6);

        vm.expectRevert(bytes("Lp token must have 18 decimals"));
        _deploySource(pool, address(feed0), address(feed1));
    }

    function runScenarioOnce(address feed0, address feed1, address source, uint256 answer0, uint256 answer1)
        external
        returns (uint256 freshPrice, uint256 feedPrice)
    {
        require(msg.sender == address(this), "only self");

        MockChainlinkFeed(feed0).setAnswer(int256(answer0));
        MockChainlinkFeed(feed1).setAnswer(int256(answer1));

        freshPrice = _currentPoolPrice(CappedVeloStableSwapOracle(source));
        feedPrice = _feedAnswer(CappedVeloStableSwapOracle(source));
    }

    function _runScenario(address feed0, address feed1, address source, uint256 answer0, uint256 answer1)
        internal
        returns (bool ok, string memory error, uint256 freshPrice, uint256 feedPrice)
    {
        try this.runScenarioOnce(feed0, feed1, source, answer0, answer1) returns (
            uint256 _freshPrice, uint256 _feedPrice
        ) {
            return (true, "", _freshPrice, _feedPrice);
        } catch Error(string memory reason) {
            return (false, reason, 0, 0);
        } catch {
            return (false, "low-level revert", 0, 0);
        }
    }

    function _deployTwoFeedSource()
        internal
        returns (MockVeloPool pool, MockChainlinkFeed feed0, MockChainlinkFeed feed1, CappedVeloStableSwapOracle source)
    {
        pool = _newPool();
        feed0 = new MockChainlinkFeed(int256(ONE_USD));
        feed1 = new MockChainlinkFeed(int256(ONE_USD));
        source = _deploySource(pool, address(feed0), address(feed1));
    }

    function _deploySource(MockVeloPool pool, address feed0, address feed1)
        internal
        returns (CappedVeloStableSwapOracle source)
    {
        source = new CappedVeloStableSwapOracle(address(pool), feed0, feed1);
    }

    function _newPool() internal returns (MockVeloPool pool) {
        return _newPool(true);
    }

    function _newPool(bool stable) internal returns (MockVeloPool pool) {
        MockToken token0 = new MockToken(18);
        MockToken token1 = new MockToken(18);
        pool = new MockVeloPool(address(token0), address(token1), stable);
    }

    function _newPoolWithTokenDecimals(uint8 tokenDecimals, uint256 metadataDecimals0, uint256 metadataDecimals1)
        internal
        returns (MockVeloPool pool)
    {
        MockToken token0 = new MockToken(tokenDecimals);
        MockToken token1 = new MockToken(tokenDecimals);
        pool = new MockVeloPool(address(token0), address(token1), true);
        pool.setTokenDecimals(metadataDecimals0, metadataDecimals1);
    }

    function _setBoth(MockChainlinkFeed feed0, MockChainlinkFeed feed1, uint256 answer) internal {
        _set(feed0, feed1, answer, answer);
    }

    function _set(MockChainlinkFeed feed0, MockChainlinkFeed feed1, uint256 answer0, uint256 answer1) internal {
        feed0.setAnswer(int256(answer0));
        feed1.setAnswer(int256(answer1));
    }

    function _assertDoesNotOverstateReserveValue(
        MockVeloPool pool,
        CappedVeloStableSwapOracle source,
        uint256 reserve0,
        uint256 reserve1
    ) internal {
        pool.setState(WAD, reserve0, reserve1);

        uint256 price = _currentPoolPrice(source);
        uint256 reserveValue = ((reserve0 * ONE_USD) / WAD) + ((reserve1 * ONE_USD) / WAD);

        assertLe(price, reserveValue);
        if (reserve0 == 0 || reserve1 == 0) {
            assertEq(price, 0);
        }
    }

    function _reserveForStableK(uint256 fixedReserve, uint256 targetK) internal pure returns (uint256 reserve) {
        uint256 low;
        uint256 high = WAD;

        while (_stableK(fixedReserve, high) < targetK) {
            high *= 2;
        }

        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_stableK(fixedReserve, mid) < targetK) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        reserve = low;
    }

    function _stableK(uint256 reserve0, uint256 reserve1) internal pure returns (uint256) {
        uint256 a = (reserve0 * reserve1) / WAD;
        uint256 b = ((reserve0 * reserve0) / WAD) + ((reserve1 * reserve1) / WAD);
        return (a * b) / WAD;
    }

    function _currentPoolPrice(CappedVeloStableSwapOracle source) internal view returns (uint256 price) {
        (price,) = source.fairReservesPriceData();
    }

    function _feedAnswer(CappedVeloStableSwapOracle source) internal view returns (uint256) {
        (, int256 answer,,,) = source.latestRoundData();
        return uint256(answer);
    }
}
