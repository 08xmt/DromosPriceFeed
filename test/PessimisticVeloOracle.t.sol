// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockChainlinkFeed} from "../src/MockChainlinkFeed.sol";
import {PessimisticVeloSingleOracle} from "../src/PessimisticVeloSingleOracle.sol";
import {PessimisticVeloStableLpPriceFeed} from "../src/PessimisticVeloStableLpPriceFeed.sol";
import {IChainLinkOracle} from "../src/interfaces/IChainLinkOracle.sol";

contract MockToken {
    uint8 public immutable decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }
}

contract MockVeloPool {
    address public immutable token0;
    address public immutable token1;
    bool public immutable stable;

    uint8 internal lpDecimals = 18;
    uint256 public totalSupply;
    uint256 internal decimals0;
    uint256 internal decimals1;
    uint256 internal reserve0;
    uint256 internal reserve1;
    bool public swapShouldRevert;

    constructor(address _token0, address _token1, bool _stable) {
        token0 = _token0;
        token1 = _token1;
        stable = _stable;
        decimals0 = 1e18;
        decimals1 = 1e18;
        totalSupply = 1e18;
        reserve0 = 1e18;
        reserve1 = 1e18;
    }

    function setState(
        uint256 _totalSupply,
        uint256 _reserve0,
        uint256 _reserve1
    ) external {
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

    function setSwapShouldRevert(bool _swapShouldRevert) external {
        swapShouldRevert = _swapShouldRevert;
    }

    function executeMockSwap(uint256 amountIn) external {
        if (swapShouldRevert) revert("swap failed");
        reserve0 += amountIn;
        reserve1 -= amountIn;
    }

    function quote(
        address tokenIn,
        uint256 amountIn,
        uint256
    ) external view returns (uint256) {
        if (tokenIn == token0) {
            return (amountIn * reserve1) / reserve0;
        }
        if (tokenIn == token1) {
            return (amountIn * reserve0) / reserve1;
        }
        revert("unknown token");
    }

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
        )
    {
        return (
            decimals0,
            decimals1,
            reserve0,
            reserve1,
            stable,
            token0,
            token1
        );
    }

    function decimals() external view returns (uint8) {
        return lpDecimals;
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

    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract StaticSingleOracleSource {
    address public immutable pool;
    uint256 public price;

    constructor(address _pool, uint256 _price) {
        pool = _pool;
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getCurrentPoolPrice(bool) external view returns (uint256) {
        return price;
    }
}

contract PessimisticVeloOracleTest is Test {
    address internal constant SEQUENCER_UPTIME_FEED =
        0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389;
    uint96 internal constant HEARTBEAT = 10 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_USD = 100_000_000;

    function setUp() public {
        vm.warp(10 days);
        _mockSequencerAnswer(0);
    }

    function testMockChainlinkFeedUpdates() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(int256(ONE_USD));

        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();
        assertEq(feed.decimals(), 8);
        assertEq(roundId, 1);
        assertEq(answer, int256(ONE_USD));
        assertEq(startedAt, updatedAt);
        assertEq(answeredInRound, 1);

        vm.warp(block.timestamp + 1);
        feed.setAnswer(95_000_000);
        (, int256 updatedAnswer, , uint256 secondUpdatedAt, ) = feed
            .latestRoundData();
        assertEq(feed.roundId(), 2);
        assertEq(updatedAnswer, 95_000_000);
        assertGt(secondUpdatedAt, updatedAt);

        vm.warp(block.timestamp + 1);
        feed.refresh();
        (, int256 refreshedAnswer, , uint256 refreshedAt, ) = feed
            .latestRoundData();
        assertEq(feed.roundId(), 3);
        assertEq(refreshedAnswer, 95_000_000);
        assertGt(refreshedAt, secondUpdatedAt);

        vm.expectRevert(bytes("Invalid answer"));
        feed.setAnswer(0);
    }

    function testStableLpPriceFeedAdapter() public {
        (
            ,
            MockChainlinkFeed feed0,
            MockChainlinkFeed feed1,
            PessimisticVeloSingleOracle source
        ) = _deployTwoFeedSource(true);
        source.setOperator(address(this), true);
        source.updatePrice();

        PessimisticVeloStableLpPriceFeed adapter = new PessimisticVeloStableLpPriceFeed(
                address(source)
            );

        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = adapter.latestRoundData();
        uint256 sourcePrice = source.getCurrentPoolPrice(true);

        assertEq(feed0.decimals(), 8);
        assertEq(feed1.decimals(), 8);
        assertEq(adapter.decimals(), 8);
        assertEq(roundId, 0);
        assertEq(answer, int256(sourcePrice));
        assertEq(startedAt, updatedAt);
        assertEq(answeredInRound, 0);
    }

    function testStableLpPriceFeedAdapterRevertsWithoutSourceUpdate() public {
        (, , , PessimisticVeloSingleOracle source) = _deployTwoFeedSource(
            true
        );
        PessimisticVeloStableLpPriceFeed adapter = new PessimisticVeloStableLpPriceFeed(
                address(source)
            );

        vm.expectRevert(bytes("!updates"));
        adapter.latestRoundData();
    }

    function testStableLpPriceFeedAdapterRejectsVolatilePool() public {
        (, , , PessimisticVeloSingleOracle source) = _deployTwoFeedSource(
            false
        );

        vm.expectRevert(bytes("Pool must be stable"));
        new PessimisticVeloStableLpPriceFeed(address(source));
    }

    function testStableLpPriceFeedAdapterRejectsZeroAndOverflowAnswers()
        public
    {
        MockVeloPool pool = _newPool(true);
        StaticSingleOracleSource source = new StaticSingleOracleSource(
            address(pool),
            0
        );
        PessimisticVeloStableLpPriceFeed adapter = new PessimisticVeloStableLpPriceFeed(
                address(source)
            );

        vm.expectRevert(bytes("Invalid price"));
        adapter.latestRoundData();

        source.setPrice(uint256(type(int256).max) + 1);
        vm.expectRevert(bytes("Price overflow"));
        adapter.latestRoundData();
    }

    function testSingleOracleOneChainlinkFeedSmoke() public {
        MockVeloPool pool = _newPool(false);
        MockChainlinkFeed feed0 = new MockChainlinkFeed(int256(ONE_USD));

        PessimisticVeloSingleOracle source = _deploySource(
            pool,
            address(feed0),
            address(0),
            false
        );

        (uint256 price0, uint256 price1) = source.getTokenPrices();
        assertEq(price0, ONE_USD);
        assertEq(price1, ONE_USD);
        assertEq(source.getCurrentPoolPrice(false), 2 * ONE_USD);

        source.setOperator(address(this), true);
        source.updatePrice();
        assertEq(source.getCurrentPoolPrice(true), 2 * ONE_USD);
    }

    function testPessimisticAdapterClampsUpwardMovesAndRecordsLowerLows()
        public
    {
        (
            ,
            MockChainlinkFeed feed0,
            MockChainlinkFeed feed1,
            PessimisticVeloSingleOracle source
        ) = _deployTwoFeedSource(true);
        source.setOperator(address(this), true);
        source.updatePrice();
        PessimisticVeloStableLpPriceFeed adapter = new PessimisticVeloStableLpPriceFeed(
                address(source)
            );

        uint256 baseline = _adapterAnswer(adapter);

        feed0.setAnswer(110_000_000);
        feed1.setAnswer(110_000_000);
        uint256 freshHigh = source.getCurrentPoolPrice(false);
        source.updatePrice();
        uint256 adapterHigh = _adapterAnswer(adapter);
        assertGt(freshHigh, baseline);
        assertEq(adapterHigh, baseline);

        feed0.setAnswer(90_000_000);
        feed1.setAnswer(90_000_000);
        uint256 freshLow = source.getCurrentPoolPrice(false);
        source.updatePrice();
        uint256 adapterLow = _adapterAnswer(adapter);
        assertLt(freshLow, baseline);
        assertEq(adapterLow, freshLow);
    }

    function testScenarioGridReturnsRowsAndCapturesSwapReverts() public {
        (
            MockVeloPool pool,
            MockChainlinkFeed feed0,
            MockChainlinkFeed feed1,
            PessimisticVeloSingleOracle source
        ) = _deployTwoFeedSource(true);
        source.setOperator(address(this), true);
        source.updatePrice();
        PessimisticVeloStableLpPriceFeed adapter = new PessimisticVeloStableLpPriceFeed(
                address(source)
            );

        uint256[2] memory price0Answers = [ONE_USD, uint256(99_000_000)];
        uint256[2] memory price1Answers = [ONE_USD, uint256(101_000_000)];
        uint256 rows;

        for (uint256 i = 0; i < price0Answers.length; i++) {
            for (uint256 j = 0; j < price1Answers.length; j++) {
                (
                    bool ok,
                    string memory error,
                    uint256 freshPrice,
                    uint256 adapterPrice
                ) = _runScenario(
                        address(feed0),
                        address(feed1),
                        address(source),
                        address(adapter),
                        price0Answers[i],
                        price1Answers[j],
                        false
                    );

                assertTrue(ok);
                assertEq(bytes(error).length, 0);
                assertGt(freshPrice, 0);
                assertGt(adapterPrice, 0);
                rows += 1;
            }
        }
        assertEq(rows, 4);

        pool.setSwapShouldRevert(true);
        (
            bool failureOk,
            string memory failureError,
            ,

        ) = _runScenario(
                address(feed0),
                address(feed1),
                address(source),
                address(adapter),
                ONE_USD,
                ONE_USD,
                true
            );
        assertFalse(failureOk);
        assertGt(bytes(failureError).length, 0);
    }

    function testConstructorRejectsInvalidFeedConfigurations() public {
        MockVeloPool pool = _newPool(true);
        MockChainlinkFeed feed = new MockChainlinkFeed(int256(ONE_USD));
        FlexibleChainlinkFeed badDecimalsFeed = new FlexibleChainlinkFeed(
            18,
            int256(ONE_USD)
        );

        vm.expectRevert(bytes("At least one token must have CL oracle"));
        _deploySource(pool, address(0), address(0), false);

        vm.expectRevert(bytes("Only Chainlink feeds supported"));
        _deploySource(pool, address(feed), address(0), true);

        vm.expectRevert(bytes("Must be 8 decimals"));
        _deploySource(pool, address(badDecimalsFeed), address(feed), false);
    }

    function testChainlinkPriceRejectsStaleNegativeAndSequencerDown()
        public
    {
        MockVeloPool pool = _newPool(true);
        FlexibleChainlinkFeed feed0 = new FlexibleChainlinkFeed(
            8,
            int256(ONE_USD)
        );
        MockChainlinkFeed feed1 = new MockChainlinkFeed(int256(ONE_USD));
        PessimisticVeloSingleOracle source = _deploySource(
            pool,
            address(feed0),
            address(feed1),
            true
        );

        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.expectRevert(bytes("Price is stale"));
        source.getChainlinkPrice(0);

        feed0.setAnswer(-1);
        vm.expectRevert(bytes("Invalid feed price"));
        source.getChainlinkPrice(0);

        feed0.setAnswer(int256(ONE_USD));
        _mockSequencerAnswer(1);
        vm.expectRevert(bytes("L2 sequencer down"));
        source.getChainlinkPrice(0);
    }

    function testUpdatePriceRequiresOperator() public {
        (, , , PessimisticVeloSingleOracle source) = _deployTwoFeedSource(
            true
        );

        vm.expectRevert(bytes("unauthorized"));
        source.updatePrice();
    }

    function testTwoAndThreeDayLowSelection() public {
        (
            ,
            MockChainlinkFeed feed0,
            MockChainlinkFeed feed1,
            PessimisticVeloSingleOracle source
        ) = _deployTwoFeedSource(false);
        source.setOperator(address(this), true);

        _setBoth(feed0, feed1, 90_000_000);
        source.updatePrice();

        vm.warp(11 days);
        _setBoth(feed0, feed1, 95_000_000);
        source.updatePrice();

        vm.warp(12 days);
        _setBoth(feed0, feed1, ONE_USD);
        source.updatePrice();

        assertEq(source.getCurrentPoolPrice(true), 190_000_000);

        source.setUseThreeDayLow(true);
        assertEq(source.getCurrentPoolPrice(true), 180_000_000);
    }

    function testFairReservePricingAtParityForStableAndVolatilePools()
        public
    {
        (, , , PessimisticVeloSingleOracle stableSource) = _deployTwoFeedSource(
            true
        );
        (
            ,
            ,
            ,
            PessimisticVeloSingleOracle volatileSource
        ) = _deployTwoFeedSource(false);

        assertApproxEqAbs(
            stableSource.getCurrentPoolPrice(false),
            2 * ONE_USD,
            10
        );
        assertEq(volatileSource.getCurrentPoolPrice(false), 2 * ONE_USD);
    }

    function testLpTokenMustHaveEighteenDecimals() public {
        (
            MockVeloPool pool,
            ,
            ,
            PessimisticVeloSingleOracle source
        ) = _deployTwoFeedSource(true);
        pool.setLpDecimals(6);

        vm.expectRevert(bytes("Lp token must have 18 decimals"));
        source.getCurrentPoolPrice(false);
    }

    function runScenarioOnce(
        address feed0,
        address feed1,
        address source,
        address adapter,
        uint256 answer0,
        uint256 answer1,
        bool executeSwap
    ) external returns (uint256 freshPrice, uint256 adapterPrice) {
        require(msg.sender == address(this), "only self");

        MockChainlinkFeed(feed0).setAnswer(int256(answer0));
        MockChainlinkFeed(feed1).setAnswer(int256(answer1));

        if (executeSwap) {
            MockVeloPool(PessimisticVeloSingleOracle(source).pool())
                .executeMockSwap(1);
        }

        freshPrice = PessimisticVeloSingleOracle(source).getCurrentPoolPrice(
            false
        );
        PessimisticVeloSingleOracle(source).updatePrice();
        adapterPrice = _adapterAnswer(PessimisticVeloStableLpPriceFeed(adapter));
    }

    function _runScenario(
        address feed0,
        address feed1,
        address source,
        address adapter,
        uint256 answer0,
        uint256 answer1,
        bool executeSwap
    )
        internal
        returns (
            bool ok,
            string memory error,
            uint256 freshPrice,
            uint256 adapterPrice
        )
    {
        try
            this.runScenarioOnce(
                feed0,
                feed1,
                source,
                adapter,
                answer0,
                answer1,
                executeSwap
            )
        returns (uint256 _freshPrice, uint256 _adapterPrice) {
            return (true, "", _freshPrice, _adapterPrice);
        } catch Error(string memory reason) {
            return (false, reason, 0, 0);
        } catch {
            return (false, "low-level revert", 0, 0);
        }
    }

    function _deployTwoFeedSource(bool stable)
        internal
        returns (
            MockVeloPool pool,
            MockChainlinkFeed feed0,
            MockChainlinkFeed feed1,
            PessimisticVeloSingleOracle source
        )
    {
        pool = _newPool(stable);
        feed0 = new MockChainlinkFeed(int256(ONE_USD));
        feed1 = new MockChainlinkFeed(int256(ONE_USD));
        source = _deploySource(pool, address(feed0), address(feed1), true);
    }

    function _deploySource(
        MockVeloPool pool,
        address feed0,
        address feed1,
        bool useChainlinkOnly
    ) internal returns (PessimisticVeloSingleOracle source) {
        source = new PessimisticVeloSingleOracle(
            address(pool),
            useChainlinkOnly,
            feed0,
            feed1,
            HEARTBEAT,
            HEARTBEAT,
            4,
            address(this)
        );
    }

    function _newPool(bool stable) internal returns (MockVeloPool pool) {
        MockToken token0 = new MockToken(18);
        MockToken token1 = new MockToken(18);
        pool = new MockVeloPool(address(token0), address(token1), stable);
    }

    function _setBoth(
        MockChainlinkFeed feed0,
        MockChainlinkFeed feed1,
        uint256 answer
    ) internal {
        feed0.setAnswer(int256(answer));
        feed1.setAnswer(int256(answer));
    }

    function _adapterAnswer(
        PessimisticVeloStableLpPriceFeed adapter
    ) internal view returns (uint256) {
        (, int256 answer, , , ) = adapter.latestRoundData();
        return uint256(answer);
    }

    function _mockSequencerAnswer(int256 answer) internal {
        vm.mockCall(
            SEQUENCER_UPTIME_FEED,
            abi.encodeWithSelector(IChainLinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
