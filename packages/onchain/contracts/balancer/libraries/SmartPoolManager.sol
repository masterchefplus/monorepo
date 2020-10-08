// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.6;

// Needed to pass in structs
pragma experimental ABIEncoderV2;

// Imports

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "../../mocks/ConfigurableRightsPool.sol";
import "../IBFactory.sol";

/**
 * @author Balancer Labs
 * @title Factor out the weight updates
 */
library SmartPoolManager {
  // Type declarations

  // State variables (must be constant in a library)

  // B "ONE" - all math is in the "realm" of 10 ** 18;
  // where numeric 1 = 10 ** 18
  uint256 constant BONE = 10**18;
  uint256 constant MIN_WEIGHT = BONE;
  uint256 constant MAX_WEIGHT = BONE * 50;
  uint256 constant MAX_TOTAL_WEIGHT = BONE * 50;
  uint256 constant MIN_BALANCE = BONE / 10**6;
  uint256 constant MAX_BALANCE = BONE * 10**12;
  uint256 constant MIN_POOL_SUPPLY = BONE * 100;
  uint256 constant MAX_POOL_SUPPLY = BONE * 10**9;
  uint256 constant MIN_FEE = BONE / 10**6;
  uint256 constant MAX_FEE = BONE / 10;
  // EXIT_FEE must always be zero, or ConfigurableRightsPool._pushUnderlying will fail
  uint256 constant EXIT_FEE = 0;
  uint256 constant MAX_IN_RATIO = BONE / 2;
  uint256 constant MAX_OUT_RATIO = (BONE / 3) + 1 wei;
  // Must match MIN_BOUND_TOKENS and MAX_BOUND_TOKENS
  uint256 constant MIN_ASSET_LIMIT = 2;
  uint256 constant MAX_ASSET_LIMIT = 8;
  uint256 constant MAX_UINT = uint256(-1);

  uint256 constant MIN_BPOW_BASE = 1 wei;
  uint256 constant MAX_BPOW_BASE = (2 * BONE) - 1 wei;
  uint256 constant BPOW_PRECISION = BONE / 10**10;

  struct NewTokenParams {
    address addr;
    bool isCommitted;
    uint256 commitBlock;
    uint256 denorm;
    uint256 balance;
  }

  // updateWeight and pokeWeights are unavoidably long
  /* solhint-disable function-max-lines */

  /**
   * @notice Update the weight of an existing token
   * @dev Refactored to library to make CRPFactory deployable
   * @param self - ConfigurableRightsPool instance calling the library
   * @param bPool - Core BPool the CRP is wrapping
   * @param token - token to be reweighted
   * @param newWeight - new weight of the token
   */
  function updateWeight(
    ConfigurableRightsPool self,
    IBPool bPool,
    address token,
    uint256 newWeight
  ) external {
    require(newWeight >= MIN_WEIGHT, "ERR_MIN_WEIGHT");
    require(newWeight <= MAX_WEIGHT, "ERR_MAX_WEIGHT");

    uint256 currentWeight = bPool.getDenormalizedWeight(token);
    // Save gas; return immediately on NOOP
    if (currentWeight == newWeight) {
      return;
    }

    uint256 currentBalance = bPool.getBalance(token);
    uint256 totalSupply = self.totalSupply();
    uint256 totalWeight = bPool.getTotalDenormalizedWeight();
    uint256 poolShares;
    uint256 deltaBalance;
    uint256 deltaWeight;
    uint256 newBalance;

    if (newWeight < currentWeight) {
      // This means the controller will withdraw tokens to keep price
      // So they need to redeem PCTokens
      deltaWeight = BMath.bsub(currentWeight, newWeight);

      // poolShares = totalSupply * (deltaWeight / totalWeight)
      poolShares = BMath.bmul(totalSupply, BMath.bdiv(deltaWeight, totalWeight));

      // deltaBalance = currentBalance * (deltaWeight / currentWeight)
      deltaBalance = BMath.bmul(currentBalance, BMath.bdiv(deltaWeight, currentWeight));

      // New balance cannot be lower than MIN_BALANCE
      newBalance = BMath.bsub(currentBalance, deltaBalance);

      require(newBalance >= MIN_BALANCE, "ERR_MIN_BALANCE");

      // First get the tokens from this contract (Pool Controller) to msg.sender
      bPool.rebind(token, newBalance, newWeight);

      // Now with the tokens this contract can send them to msg.sender
      bool xfer = IERC20(token).transfer(msg.sender, deltaBalance);
      require(xfer, "ERR_ERC20_FALSE");

      self.pullPoolShareFromLib(msg.sender, poolShares);
      self.burnPoolShareFromLib(poolShares);
    } else {
      // This means the controller will deposit tokens to keep the price.
      // They will be minted and given PCTokens
      deltaWeight = BMath.bsub(newWeight, currentWeight);

      require(BMath.badd(totalWeight, deltaWeight) <= MAX_TOTAL_WEIGHT, "ERR_MAX_TOTAL_WEIGHT");

      // poolShares = totalSupply * (deltaWeight / totalWeight)
      poolShares = BMath.bmul(totalSupply, BMath.bdiv(deltaWeight, totalWeight));
      // deltaBalance = currentBalance * (deltaWeight / currentWeight)
      deltaBalance = BMath.bmul(currentBalance, BMath.bdiv(deltaWeight, currentWeight));

      // First gets the tokens from msg.sender to this contract (Pool Controller)
      bool xfer = IERC20(token).transferFrom(msg.sender, address(this), deltaBalance);
      require(xfer, "ERR_ERC20_FALSE");

      // Now with the tokens this contract can bind them to the pool it controls
      bPool.rebind(token, BMath.badd(currentBalance, deltaBalance), newWeight);

      self.mintPoolShareFromLib(poolShares);
      self.pushPoolShareFromLib(msg.sender, poolShares);
    }
  }

  /**
   * @notice Join a pool
   * @param self - ConfigurableRightsPool instance calling the library
   * @param bPool - Core BPool the CRP is wrapping
   * @param poolAmountOut - number of pool tokens to receive
   * @param maxAmountsIn - Max amount of asset tokens to spend
   * @return actualAmountsIn - calculated values of the tokens to pull in
   */
  function joinPool(
    ConfigurableRightsPool self,
    IBPool bPool,
    uint256 poolAmountOut,
    uint256[] calldata maxAmountsIn
  ) external view returns (uint256[] memory actualAmountsIn) {
    address[] memory tokens = bPool.getCurrentTokens();

    require(maxAmountsIn.length == tokens.length, "ERR_AMOUNTS_MISMATCH");

    uint256 poolTotal = self.totalSupply();
    // Subtract  1 to ensure any rounding errors favor the pool
    uint256 ratio = BMath.bdiv(poolAmountOut, BMath.bsub(poolTotal, 1));

    require(ratio != 0, "ERR_MATH_APPROX");

    // We know the length of the array; initialize it, and fill it below
    // Cannot do "push" in memory
    actualAmountsIn = new uint256[](tokens.length);

    // This loop contains external calls
    // External calls are to math libraries or the underlying pool, so low risk
    for (uint256 i = 0; i < tokens.length; i++) {
      address t = tokens[i];
      uint256 bal = bPool.getBalance(t);
      // Add 1 to ensure any rounding errors favor the pool
      uint256 tokenAmountIn = BMath.bmul(ratio, BMath.badd(bal, 1));

      require(tokenAmountIn != 0, "ERR_MATH_APPROX");
      require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");

      actualAmountsIn[i] = tokenAmountIn;
    }
  }

  /**
   * @notice Exit a pool - redeem pool tokens for underlying assets
   * @param self - ConfigurableRightsPool instance calling the library
   * @param bPool - Core BPool the CRP is wrapping
   * @param poolAmountIn - amount of pool tokens to redeem
   * @param minAmountsOut - minimum amount of asset tokens to receive
   * @return exitFee - calculated exit fee
   * @return pAiAfterExitFee - final amount in (after accounting for exit fee)
   * @return actualAmountsOut - calculated amounts of each token to pull
   */
  function exitPool(
    ConfigurableRightsPool self,
    IBPool bPool,
    uint256 poolAmountIn,
    uint256[] calldata minAmountsOut
  )
    external
    view
    returns (
      uint256 exitFee,
      uint256 pAiAfterExitFee,
      uint256[] memory actualAmountsOut
    )
  {
    address[] memory tokens = bPool.getCurrentTokens();

    require(minAmountsOut.length == tokens.length, "ERR_AMOUNTS_MISMATCH");

    uint256 poolTotal = self.totalSupply();

    // Calculate exit fee and the final amount in
    exitFee = BMath.bmul(poolAmountIn, EXIT_FEE);
    pAiAfterExitFee = BMath.bsub(poolAmountIn, exitFee);

    uint256 ratio = BMath.bdiv(pAiAfterExitFee, BMath.badd(poolTotal, 1));

    require(ratio != 0, "ERR_MATH_APPROX");

    actualAmountsOut = new uint256[](tokens.length);

    // This loop contains external calls
    // External calls are to math libraries or the underlying pool, so low risk
    for (uint256 i = 0; i < tokens.length; i++) {
      address t = tokens[i];
      uint256 bal = bPool.getBalance(t);
      // Subtract 1 to ensure any rounding errors favor the pool
      uint256 tokenAmountOut = BMath.bmul(ratio, BMath.bsub(bal, 1));

      require(tokenAmountOut != 0, "ERR_MATH_APPROX");
      require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");

      actualAmountsOut[i] = tokenAmountOut;
    }
  }

  // Internal functions

  // Check for zero transfer, and make sure it returns true to returnValue
  function verifyTokenComplianceInternal(address token) internal {
    bool returnValue = IERC20(token).transfer(msg.sender, 0);
    require(returnValue, "ERR_NONCONFORMING_TOKEN");
  }
}
