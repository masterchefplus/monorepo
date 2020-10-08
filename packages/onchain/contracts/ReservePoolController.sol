// SPDX-License-Identifier: MPL-2.0

pragma solidity 0.6.6;

// Imports
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "./Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/lib/contracts/libraries/Babylonian.sol";
import "./uniswap/UniswapV2Library.sol";
import "./uniswap/IUniswapV2Router01.sol";
import "./IBtcPriceOracle.sol";
import "./balancer/IBFactory.sol";
import "./balancer/IBPool.sol";
import "./balancer/IConfigurableRightsPool.sol";
import "./balancer/ICRPFactory.sol";
import "./IBorrower.sol";
import "./IFlashERC20.sol";

contract ReservePoolController is IBorrower, Ownable {
  using SafeMath for uint256;

  uint256 internal constant DEFAULT_WEIGHT = 5 * 10**18;
  uint256 internal constant BONE = 10**18;
  uint256 internal constant MIN_POOL_SUPPLY = BONE * 100;
  uint256 internal constant MAX_UINT = uint256(-1);

  // Event declarations
  event Trade(bool indexed direction, uint256 amount);

  // immutable
  IERC20 private immutable vBtc;
  IERC20 private immutable wEth;

  // goverance params
  IUniswapV2Router01 private uniRouter; // IUniswapV2Router01
  address private oracle; // 24 hour price feed for BTC
  uint256 private maxVbtcWeight; // denormmalized, like in Balancer

  // working memory
  IConfigurableRightsPool private crp;
  uint32 private blockTimestampLast;

  constructor(
    address _vBtcAddr,
    address _wEthAddr,
    IUniswapV2Router01 _uniRouter,
    address _oracle
  ) public {
    vBtc = IERC20(_vBtcAddr);
    wEth = IERC20(_wEthAddr);
    uniRouter = _uniRouter;
    oracle = _oracle;
    maxVbtcWeight = 3 * DEFAULT_WEIGHT;
  }

  function initialize(
    address _bPoolFactory,
    ICRPFactory _crpFactory,
    uint256 initialSwapFee
  ) external {
    require(address(crp) == address(0), "already initialized");

    uint256[] memory balances = new uint256[](2);
    // get price
    balances[1] = vBtc.balanceOf(address(this));
    require(balances[1] > 0, "missing initial vBtc bal");
    uint256 wEthBal = wEth.balanceOf(address(this));
    require(wEthBal > 0, "missing initial wEth bal");
    // check denorm amount
    balances[0] = IBtcPriceOracle(oracle).consult(balances[1]);
    require(wEthBal == balances[0], "missing initial WETH bal");

    address[] memory tokens = new address[](2);
    tokens[0] = address(wEth);
    tokens[1] = address(vBtc);
    uint256[] memory weights = new uint256[](2);
    weights[0] = DEFAULT_WEIGHT;
    weights[1] = DEFAULT_WEIGHT;
    IConfigurableRightsPool.PoolParams memory poolParams = IConfigurableRightsPool.PoolParams({
      poolTokenSymbol: // Balancer Pool Token (representing shares of the pool)
      "vBTC++",
      poolTokenName: "Strudel vBTC++",
      constituentTokens: // Tokens inside the Pool
      tokens,
      tokenBalances: balances,
      tokenWeights: weights,
      swapFee: initialSwapFee
    });

    IConfigurableRightsPool.Rights memory rights = IConfigurableRightsPool.Rights({
      canPauseSwapping: true,
      canChangeSwapFee: true,
      canChangeWeights: true,
      canAddRemoveTokens: false,
      canWhitelistLPs: false,
      canChangeCap: false
    });

    crp = _crpFactory.newCrp(_bPoolFactory, poolParams, rights);

    // approve tokens and create pool
    vBtc.approve(address(crp), balances[1]);
    wEth.approve(address(crp), balances[0]);
    crp.createPool(MIN_POOL_SUPPLY);
    IBPool bPool = crp.bPool();

    // for future trading
    vBtc.approve(address(bPool), MAX_UINT);
    vBtc.approve(address(uniRouter), MAX_UINT);
    wEth.approve(address(bPool), MAX_UINT);
    wEth.approve(address(uniRouter), MAX_UINT);
  }

  // computes the direction and magnitude of the profit-maximizing trade
  function computeProfitMaximizingTrade(
    uint256 truePriceTokenA,
    uint256 truePriceTokenB,
    uint256 reserveA,
    uint256 reserveB
  ) internal pure returns (bool aToB, uint256 amountIn) {
    aToB = reserveA.mul(truePriceTokenB) / reserveB < truePriceTokenA;

    uint256 invariant = reserveA.mul(reserveB);

    uint256 leftSide = Babylonian.sqrt(
      invariant.mul(aToB ? truePriceTokenA : truePriceTokenB).mul(1000) /
        uint256(aToB ? truePriceTokenB : truePriceTokenA).mul(997)
    );
    uint256 rightSide = (aToB ? reserveA.mul(1000) : reserveB.mul(1000)) / 997;

    // compute the amount that must be sent to move the price to the profit-maximizing price
    amountIn = leftSide.sub(rightSide);
  }

  function getParams()
    external
    view
    returns (
      address,
      address,
      uint256,
      uint32
    )
  {
    return (address(uniRouter), oracle, maxVbtcWeight, blockTimestampLast);
  }

  /**
   * @notice Update the weight of a token without changing the price (or transferring tokens)
   * @dev Checks if the token's current pool balance has deviated from cached balance,
   *      if so it adjusts the token's weights proportional to the deviation.
   *      The underlying BPool enforces bounds on MIN_WEIGHTS=1e18, MAX_WEIGHT=50e18 and TOTAL_WEIGHT=50e18.
   *      NOTE: The BPool.rebind function CAN REVERT if the updated weights go beyond the enforced bounds.
   */
  function resyncWeights() external {
    // simple check for re-entrancy
    require(msg.sender == tx.origin, "caller not EOA");
    // read FEED price of BTC ()
    uint256 truePriceBtc = 10**18;
    uint256 truePriceEth = IBtcPriceOracle(oracle).consult(truePriceBtc);

    // true price is expressed as a ratio, so both values must be non-zero
    require(truePriceBtc != 0, "ReservePool: ZERO_PRICE");

    // deal with spot pool
    bool ethToBtc;
    uint256 tradeAmount;
    {
      // read SPOT price of vBTC
      (uint256 reserveWeth, uint256 reserveVbtc) = UniswapV2Library.getReserves(
        uniRouter.factory(),
        address(wEth),
        address(vBtc)
      );
      // how much ETH (including UNI fee) is needed to lift SPOT to FEED?
      (ethToBtc, tradeAmount) = computeProfitMaximizingTrade(
        truePriceEth,
        truePriceBtc,
        reserveWeth,
        reserveVbtc
      );
    }

    // deal with reserve pool
    uint256 vBtcToBorrow = tradeAmount;
    IBPool bPool = crp.bPool();
    uint256 vBtcWeight = bPool.getDenormalizedWeight(address(vBtc));
    if (ethToBtc) {
      // calculate amount vBTC to get the needed ETH from reserve pool
      {
        uint256 tokenBalanceIn = bPool.getBalance(address(vBtc));
        uint256 tokenBalanceOut = bPool.getBalance(address(wEth));
        uint256 tokenWeightOut = bPool.getDenormalizedWeight(address(wEth));
        uint256 swapFee = bPool.getSwapFee();
        vBtcToBorrow = bPool.calcInGivenOut(
          tokenBalanceIn,
          vBtcWeight,
          tokenBalanceOut,
          tokenWeightOut,
          tradeAmount, // amount of ETH we want to get out
          swapFee
        );
      }
    }
    // ecode diruction and old Weight together
    bytes32 data = bytes32((uint256(ethToBtc ? 1 : 0) << 248) | vBtcWeight);
    // get the loan
    IFlashERC20(address(vBtc)).flashMint(vBtcToBorrow, data);
  }

  function executeOnFlashMint(uint256 amount, bytes32 data) external override {
    // check sender
    require(msg.sender == address(vBtc), "who are you?!");
    // check amount
    require(vBtc.balanceOf(address(this)) >= amount, "loan error");
    // we received a bunch of vBTC here
    // read direction, then do the trade, trust that amounts were calculated correctly
    bool ethToBtc = (uint256(data) >> 248) != 0;
    uint256 oldVbtcWeight = (uint256(data) << 8) >> 8;
    address tokenIn = ethToBtc ? address(wEth) : address(vBtc);
    address tokenOut = ethToBtc ? address(vBtc) : address(wEth);
    uint256 tradeAmount = amount;
    emit Trade(ethToBtc, tradeAmount);

    IBPool bPool = crp.bPool();
    if (ethToBtc) {
      // we want to trade eth to vBTC in UNI, so let's get the ETH
      // 4. buy ETH in reserve pool with all vBTC
      (tradeAmount, ) = bPool.swapExactAmountIn( // returns uint256 tokenAmountOut, uint256 spotPriceAfter
        address(vBtc),
        amount,
        address(wEth),
        0, // minAmountOut
        MAX_UINT
      ); // maxPrice
    }

    // approve should have been done in constructor
    // TransferHelper.safeApprove(tokenIn, address(router), tradeAmount);

    address[] memory path = new address[](2);
    path[0] = tokenIn;
    path[1] = tokenOut;
    // 5. sell ETH in spot pool
    uint256[] memory amounts = IUniswapV2Router01(uniRouter).swapExactTokensForTokens(
      tradeAmount,
      0, // amountOutMin: we can skip computing this number because the math is tested
      path,
      address(this),
      MAX_UINT // deadline
    );

    if (!ethToBtc) {
      // we traded vBTC for ETH in uni, now let's use it in balancer
      (tradeAmount, ) = bPool.swapExactAmountIn( // returns uint256 tokenAmountOut, uint256 spotPriceAfter
        address(wEth), // address tokenIn,
        amounts[1], // uint256 tokenAmountIn,
        address(vBtc), // address tokenOut,
        0, // minAmountOut
        MAX_UINT // maxPrice
      );
    }

    // adjusts weight in reserve pool
    {
      // read uni weights
      (uint256 reserveWeth, uint256 reserveVbtc) = UniswapV2Library.getReserves(
        uniRouter.factory(),
        address(wEth),
        address(vBtc)
      );
      uint256 vBtcBalance = bPool.getBalance(address(vBtc));
      uint256 wEthBalance = bPool.getBalance(address(wEth));
      // check that new weight does not exceed max weight
      uint256 newVbtcWeight = wEthBalance.mul(DEFAULT_WEIGHT).mul(reserveVbtc).div(vBtcBalance).div(
        reserveWeth
      );
      // if trade moves away from equal balance, slow it down
      if (newVbtcWeight > oldVbtcWeight && newVbtcWeight > DEFAULT_WEIGHT) {
        require(now.sub(blockTimestampLast) > 24 hours, "hold the unicorns");
      }
      blockTimestampLast = uint32(now);
      require(newVbtcWeight < maxVbtcWeight, "max weight error");
      // adjust weights so there is no arbitrage
      crp.updateWeight(address(vBtc), newVbtcWeight);
      crp.updateWeight(address(wEth), DEFAULT_WEIGHT);
    }

    // 6. repay loan
    // TODO: don't forget that we need to pay a flash loan fee
  }

  // governance function
  function setParams(
    address _uniRouter,
    address _oracle,
    uint256 _maxVbtcWeight,
    uint256 _swapFee,
    bool _isPublicSwap
  ) external onlyOwner {
    uniRouter = IUniswapV2Router01(_uniRouter);

    require(_oracle != address(0), "!oracle-0");
    oracle = _oracle;

    require(_maxVbtcWeight >= DEFAULT_WEIGHT / 5, "set max weight too low error");
    require(_maxVbtcWeight <= DEFAULT_WEIGHT * 9, "set max weight too high error");
    maxVbtcWeight = _maxVbtcWeight;

    IBPool bPool = crp.bPool();
    bPool.setSwapFee(_swapFee);
    bPool.setPublicSwap(_isPublicSwap);
  }

  // TODO: setController
}
