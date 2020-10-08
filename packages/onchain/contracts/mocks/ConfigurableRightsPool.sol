// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.6;

// Needed to handle structures externally
pragma experimental ABIEncoderV2;

// Imports

import "../balancer/IBFactory.sol";
import "../balancer/BalancerOwnable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

// Interfaces

// Libraries
import {RightsManager} from "../balancer/libraries/RightsManager.sol";
import "../balancer/libraries/SmartPoolManager.sol";
import "../balancer/Bmath.sol";
import "../balancer/libraries/BConst.sol";

// Contracts

/**
 * @author Balancer Labs
 * @title Smart Pool with customizable features
 * @notice PCToken is the "Balancer Smart Pool" token (transferred upon finalization)
 * @dev Rights are defined as follows (index values into the array)
 *      0: canPauseSwapping - can setPublicSwap back to false after turning it on
 *                            by default, it is off on initialization and can only be turned on
 *      1: canChangeSwapFee - can setSwapFee after initialization (by default, it is fixed at create time)
 *      2: canChangeWeights - can bind new token weights (allowed by default in base pool)
 *      3: canAddRemoveTokens - can bind/unbind tokens (allowed by default in base pool)
 *      4: canWhitelistLPs - can restrict LPs to a whitelist
 *      5: canChangeCap - can change the BSP cap (max # of pool tokens)
 *
 * Note that functions called on bPool and bFactory may look like internal calls,
 *   but since they are contracts accessed through an interface, they are really external.
 * To make this explicit, we could write "IBPool(address(bPool)).function()" everywhere,
 *   instead of "bPool.function()".
 */
contract ConfigurableRightsPool is BalancerOwnable, BMath {
  // Type declarations

  struct PoolParams {
    // Balancer Pool Token (representing shares of the pool)
    string poolTokenSymbol;
    string poolTokenName;
    // Tokens inside the Pool
    address[] constituentTokens;
    uint256[] tokenBalances;
    uint256[] tokenWeights;
    uint256 swapFee;
  }

  // For blockwise, automated weight updates
  // Move weights linearly from startWeights to endWeights,
  // between startBlock and endBlock
  struct GradualUpdateParams {
    uint256 startBlock;
    uint256 endBlock;
    uint256[] startWeights;
    uint256[] endWeights;
  }

  // State variables

  IBFactory public bFactory;
  IBPool public bPool;

  // Struct holding the rights configuration
  RightsManager.Rights public rights;

  // Hold the parameters used in updateWeightsGradually
  GradualUpdateParams public gradualUpdate;

  // This is for adding a new (currently unbound) token to the pool
  // It's a two-step process: commitAddToken(), then applyAddToken()
  SmartPoolManager.NewTokenParams public newToken;

  // Fee is initialized on creation, and can be changed if permission is set
  // Only needed for temporary storage between construction and createPool
  // Thereafter, the swap fee should always be read from the underlying pool
  uint256 private _initialSwapFee;

  // Store the list of tokens in the pool, and balances
  // NOTE that the token list is *only* used to store the pool tokens between
  //   construction and createPool - thereafter, use the underlying BPool's list
  //   (avoids synchronization issues)
  address[] private _initialTokens;
  uint256[] private _initialBalances;

  // Enforce a minimum time between the start and end blocks
  uint256 public minimumWeightChangeBlockPeriod;
  // Enforce a mandatory wait time between updates
  // This is also the wait time between committing and applying a new token
  uint256 public addTokenTimeLockInBlocks;

  // Whitelist of LPs (if configured)
  mapping(address => bool) private _liquidityProviderWhitelist;

  // Cap on the pool size (i.e., # of tokens minted when joining)
  // Limits the risk of experimental pools; failsafe/backup for fixed-size pools
  uint256 public bspCap;

  // Event declarations

  // Anonymous logger event - can only be filtered by contract address

  event LogCall(bytes4 indexed sig, address indexed caller, bytes data);

  event LogJoin(address indexed caller, address indexed tokenIn, uint256 tokenAmountIn);

  event LogExit(address indexed caller, address indexed tokenOut, uint256 tokenAmountOut);

  event CapChanged(address indexed caller, uint256 oldCap, uint256 newCap);

  event NewTokenCommitted(address indexed token, address indexed pool, address indexed caller);

  // Modifiers

  modifier logs() {
    emit LogCall(msg.sig, msg.sender, msg.data);
    _;
  }

  // Mark functions that require delegation to the underlying Pool
  modifier needsBPool() {
    require(address(bPool) != address(0), "ERR_NOT_CREATED");
    _;
  }

  modifier lockUnderlyingPool() {
    // Turn off swapping on the underlying pool during joins
    // Otherwise tokens with callbacks would enable attacks involving simultaneous swaps and joins
    bool origSwapState = bPool.isPublicSwap();
    bPool.setPublicSwap(false);
    _;
    bPool.setPublicSwap(origSwapState);
  }

  // Default values for these variables (used only in updateWeightsGradually), set in the constructor
  // Pools without permission to update weights cannot use them anyway, and should call
  //   the default createPool() function.
  // To override these defaults, pass them into the overloaded createPool()
  // Period is in blocks; 500 blocks ~ 2 hours; 90,000 blocks ~ 2 weeks
  uint256 public constant DEFAULT_MIN_WEIGHT_CHANGE_BLOCK_PERIOD = 90000;
  uint256 public constant DEFAULT_ADD_TOKEN_TIME_LOCK_IN_BLOCKS = 500;

  // Function declarations

  /**
   * @notice Construct a new Configurable Rights Pool (wrapper around BPool)
   * @dev _initialTokens and _swapFee are only used for temporary storage between construction
   *      and create pool, and should not be used thereafter! _initialTokens is destroyed in
   *      createPool to prevent this, and _swapFee is kept in sync (defensively), but
   *      should never be used except in this constructor and createPool()
   * @param factoryAddress - the BPoolFactory used to create the underlying pool
   * @param poolParams - struct containing pool parameters
   * @param rightsStruct - Set of permissions we are assigning to this smart pool
   */
  constructor(
    address factoryAddress,
    PoolParams memory poolParams,
    RightsManager.Rights memory rightsStruct
  ) public {
    // We don't have a pool yet; check now or it will fail later (in order of likelihood to fail)
    // (and be unrecoverable if they don't have permission set to change it)
    // Most likely to fail, so check first
    require(poolParams.swapFee >= BConst.MIN_FEE, "ERR_INVALID_SWAP_FEE");
    require(poolParams.swapFee <= BConst.MAX_FEE, "ERR_INVALID_SWAP_FEE");

    // Arrays must be parallel
    require(
      poolParams.tokenBalances.length == poolParams.constituentTokens.length,
      "ERR_START_BALANCES_MISMATCH"
    );
    require(
      poolParams.tokenWeights.length == poolParams.constituentTokens.length,
      "ERR_START_WEIGHTS_MISMATCH"
    );
    // Cannot have too many or too few - technically redundant, since BPool.bind() would fail later
    // But if we don't check now, we could have a useless contract with no way to create a pool

    require(poolParams.constituentTokens.length >= BConst.MIN_ASSET_LIMIT, "ERR_TOO_FEW_TOKENS");
    require(poolParams.constituentTokens.length <= BConst.MAX_ASSET_LIMIT, "ERR_TOO_MANY_TOKENS");
    // There are further possible checks (e.g., if they use the same token twice), but
    // we can let bind() catch things like that (i.e., not things that might reasonably work)

    bFactory = IBFactory(factoryAddress);
    rights = rightsStruct;
    _initialTokens = poolParams.constituentTokens;
    _initialBalances = poolParams.tokenBalances;
    _initialSwapFee = poolParams.swapFee;

    // These default block time parameters can be overridden in createPool
    minimumWeightChangeBlockPeriod = DEFAULT_MIN_WEIGHT_CHANGE_BLOCK_PERIOD;
    addTokenTimeLockInBlocks = DEFAULT_ADD_TOKEN_TIME_LOCK_IN_BLOCKS;

    gradualUpdate.startWeights = poolParams.tokenWeights;
    // Initializing (unnecessarily) for documentation - 0 means no gradual weight change has been initiated
    gradualUpdate.startBlock = 0;
    // By default, there is no cap (unlimited pool token minting)
    bspCap = BConst.MAX_UINT;
  }

  // External functions

  /**
   * @notice Set the swap fee on the underlying pool
   * @dev Keep the local version and core in sync (see below)
   *      bPool is a contract interface; function calls on it are external
   * @param swapFee in Wei
   */
  function setSwapFee(uint256 swapFee) external virtual logs onlyOwner needsBPool {
    require(rights.canChangeSwapFee, "ERR_NOT_CONFIGURABLE_SWAP_FEE");

    // Underlying pool will check against min/max fee
    bPool.setSwapFee(swapFee);
  }

  /**
   * @notice Getter for the publicSwap field on the underlying pool
   * @dev viewLock, because setPublicSwap is lock
   *      bPool is a contract interface; function calls on it are external
   * @return Current value of isPublicSwap
   */
  function isPublicSwap() external virtual view needsBPool returns (bool) {
    return bPool.isPublicSwap();
  }

  /**
   * @notice Set the cap (max # of pool tokens)
   * @dev _bspCap defaults in the constructor to unlimited
   *      Can set to 0 (or anywhere below the current supply), to halt new investment
   *      Prevent setting it before creating a pool, since createPool sets to intialSupply
   *      (it does this to avoid an unlimited cap window between construction and createPool)
   *      Therefore setting it before then has no effect, so should not be allowed
   * @param newCap - new value of the cap
   */
  function setCap(uint256 newCap) external logs needsBPool onlyOwner {
    require(rights.canChangeCap, "ERR_CANNOT_CHANGE_CAP");

    emit CapChanged(msg.sender, bspCap, newCap);

    bspCap = newCap;
  }

  /**
   * @notice Set the public swap flag on the underlying pool
   * @dev If this smart pool has canPauseSwapping enabled, we can turn publicSwap off if it's already on
   *      Note that if they turn swapping off - but then finalize the pool - finalizing will turn the
   *      swapping back on. They're not supposed to finalize the underlying pool... would defeat the
   *      smart pool functions. (Only the owner can finalize the pool - which is this contract -
   *      so there is no risk from outside.)
   *
   *      bPool is a contract interface; function calls on it are external
   * @param publicSwap new value of the swap
   */
  function setPublicSwap(bool publicSwap) external virtual logs onlyOwner needsBPool {
    require(rights.canPauseSwapping, "ERR_NOT_PAUSABLE_SWAP");

    bPool.setPublicSwap(publicSwap);
  }

  /**
   * @notice Create a new Smart Pool - and set the block period time parameters
   * @dev Initialize the swap fee to the value provided in the CRP constructor
   *      Can be changed if the canChangeSwapFee permission is enabled
   *      Time parameters will be fixed at these values
   *
   *      If this contract doesn't have canChangeWeights permission - or you want to use the default
   *      values, the block time arguments are not needed, and you can just call the single-argument
   *      createPool()
   * @param initialSupply - Starting token balance
   * @param minimumWeightChangeBlockPeriodParam - Enforce a minimum time between the start and end blocks
   * @param addTokenTimeLockInBlocksParam - Enforce a mandatory wait time between updates
   *                                   This is also the wait time between committing and applying a new token
   */
  function createPool(
    uint256 initialSupply,
    uint256 minimumWeightChangeBlockPeriodParam,
    uint256 addTokenTimeLockInBlocksParam
  ) external virtual onlyOwner logs {
    require(
      minimumWeightChangeBlockPeriodParam >= addTokenTimeLockInBlocksParam,
      "ERR_INCONSISTENT_TOKEN_TIME_LOCK"
    );

    minimumWeightChangeBlockPeriod = minimumWeightChangeBlockPeriodParam;
    addTokenTimeLockInBlocks = addTokenTimeLockInBlocksParam;

    createPoolInternal(initialSupply);
  }

  /**
   * @notice Create a new Smart Pool
   * @dev Delegates to internal function
   * @param initialSupply starting token balance
   */
  function createPool(uint256 initialSupply) external virtual onlyOwner logs {
    createPoolInternal(initialSupply);
  }

  /**
   * @notice Update the weight of an existing token
   * @dev Notice Balance is not an input (like with rebind on BPool) since we will require prices not to change
   *      This is achieved by forcing balances to change proportionally to weights, so that prices don't change
   *      If prices could be changed, this would allow the controller to drain the pool by arbing price changes
   * @param token - token to be reweighted
   * @param newWeight - new weight of the token
   */
  function updateWeight(address token, uint256 newWeight)
    external
    virtual
    logs
    onlyOwner
    needsBPool
  {
    require(rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");

    // We don't want people to set weights manually if there's a block-based update in progress
    require(gradualUpdate.startBlock == 0, "ERR_NO_UPDATE_DURING_GRADUAL");

    // Delegate to library to save space
    SmartPoolManager.updateWeight(this, bPool, token, newWeight);
  }

  /**
   * @notice Join a pool
   * @dev Emits a LogJoin event (for each token)
   *      bPool is a contract interface; function calls on it are external
   * @param poolAmountOut - number of pool tokens to receive
   * @param maxAmountsIn - Max amount of asset tokens to spend
   */
  function joinPool(uint256 poolAmountOut, uint256[] calldata maxAmountsIn)
    external
    logs
    needsBPool
    lockUnderlyingPool
  {
    require(
      !rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender],
      "ERR_NOT_ON_WHITELIST"
    );

    // Delegate to library to save space

    // Library computes actualAmountsIn, and does many validations
    // Cannot call the push/pull/min from an external library for
    // any of these pool functions. Since msg.sender can be anybody,
    // they must be internal
    uint256[] memory actualAmountsIn = SmartPoolManager.joinPool(
      this,
      bPool,
      poolAmountOut,
      maxAmountsIn
    );

    // After createPool, token list is maintained in the underlying BPool
    address[] memory poolTokens = bPool.getCurrentTokens();

    for (uint256 i = 0; i < poolTokens.length; i++) {
      address t = poolTokens[i];
      uint256 tokenAmountIn = actualAmountsIn[i];

      emit LogJoin(msg.sender, t, tokenAmountIn);

      _pullUnderlying(t, msg.sender, tokenAmountIn);
    }

    _mintPoolShare(poolAmountOut);
    _pushPoolShare(msg.sender, poolAmountOut);
  }

  /**
   * @notice Exit a pool - redeem pool tokens for underlying assets
   * @dev Emits a LogExit event for each token
   *      bPool is a contract interface; function calls on it are external
   * @param poolAmountIn - amount of pool tokens to redeem
   * @param minAmountsOut - minimum amount of asset tokens to receive
   */
  function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut)
    external
    logs
    needsBPool
    lockUnderlyingPool
  {
    // Delegate to library to save space

    // Library computes actualAmountsOut, and does many validations
    // Also computes the exitFee and pAiAfterExitFee
    (uint256 exitFee, uint256 pAiAfterExitFee, uint256[] memory actualAmountsOut) = SmartPoolManager
      .exitPool(this, bPool, poolAmountIn, minAmountsOut);

    _pullPoolShare(msg.sender, poolAmountIn);
    _pushPoolShare(address(bFactory), exitFee);
    _burnPoolShare(pAiAfterExitFee);

    // After createPool, token list is maintained in the underlying BPool
    address[] memory poolTokens = bPool.getCurrentTokens();

    for (uint256 i = 0; i < poolTokens.length; i++) {
      address t = poolTokens[i];
      uint256 tokenAmountOut = actualAmountsOut[i];

      emit LogExit(msg.sender, t, tokenAmountOut);

      _pushUnderlying(t, msg.sender, tokenAmountOut);
    }
  }

  /**
   * @notice Getter for specific permissions
   * @dev value of the enum is just the 0-based index in the enumeration
   *      For instance canPauseSwapping is 0; canChangeWeights is 2
   * @return token boolean true if we have the given permission
   */
  function hasPermission(RightsManager.Permissions permission)
    external
    virtual
    view
    returns (bool)
  {
    return RightsManager.hasPermission(rights, permission);
  }

  /**
   * @notice Get the denormalized weight of a token
   * @dev viewlock to prevent calling if it's being updated
   * @return token weight
   */
  function getDenormalizedWeight(address token) external view needsBPool returns (uint256) {
    return bPool.getDenormalizedWeight(token);
  }

  /**
   * @notice Getter for the SmartPoolManager contract
   * @dev Convenience function to get the address of the SmartPoolManager library (so clients can check version)
   * @return address of the SmartPoolManager library
   */
  function getSmartPoolManagerVersion() external pure returns (address) {
    return address(SmartPoolManager);
  }

  // Public functions

  // "Public" versions that can safely be called from SmartPoolManager
  // Allows only the contract itself to call them (not the controller or any external account)

  function mintPoolShareFromLib(uint256 amount) public {
    require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

    //_mint(amount);
  }

  function pushPoolShareFromLib(address to, uint256 amount) public {
    require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

    //_push(to, amount);
  }

  function pullPoolShareFromLib(address from, uint256 amount) public {
    require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

    //_pull(from, amount);
  }

  function burnPoolShareFromLib(uint256 amount) public {
    require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

    //_burn(amount);
  }

  // Internal functions

  // Lint wants the function to have a leading underscore too
  /* solhint-disable private-vars-leading-underscore */

  /**
   * @notice Create a new Smart Pool
   * @dev Initialize the swap fee to the value provided in the CRP constructor
   *      Can be changed if the canChangeSwapFee permission is enabled
   * @param initialSupply starting token balance
   */
  function createPoolInternal(uint256 initialSupply) internal {
    require(address(bPool) == address(0), "ERR_IS_CREATED");
    require(initialSupply >= BConst.MIN_POOL_SUPPLY, "ERR_INIT_SUPPLY_MIN");
    require(initialSupply <= BConst.MAX_POOL_SUPPLY, "ERR_INIT_SUPPLY_MAX");

    // If the controller can change the cap, initialize it to the initial supply
    // Defensive programming, so that there is no gap between creating the pool
    // (initialized to unlimited in the constructor), and setting the cap,
    // which they will presumably do if they have this right.
    if (rights.canChangeCap) {
      bspCap = initialSupply;
    }

    // There is technically reentrancy here, since we're making external calls and
    // then transferring tokens. However, the external calls are all to the underlying BPool

    // To the extent possible, modify state variables before calling functions
    _mintPoolShare(initialSupply);
    _pushPoolShare(msg.sender, initialSupply);

    // Deploy new BPool (bFactory and bPool are interfaces; all calls are external)
    bPool = bFactory.newBPool();

    // EXIT_FEE must always be zero, or ConfigurableRightsPool._pushUnderlying will fail
    require(BConst.EXIT_FEE == 0, "ERR_NONZERO_EXIT_FEE");

    for (uint256 i = 0; i < _initialTokens.length; i++) {
      address t = _initialTokens[i];
      uint256 bal = _initialBalances[i];
      uint256 denorm = gradualUpdate.startWeights[i];

      bool returnValue = IERC20(t).transferFrom(msg.sender, address(this), bal);
      require(returnValue, "ERR_ERC20_FALSE");

      returnValue = IERC20(t).approve(address(bPool), BConst.MAX_UINT);
      require(returnValue, "ERR_ERC20_FALSE");

      bPool.bind(t, bal, denorm);
    }

    while (_initialTokens.length > 0) {
      // Modifying state variable after external calls here,
      // but not essential, so not dangerous
      _initialTokens.pop();
    }

    // Set fee to the initial value set in the constructor
    // Hereafter, read the swapFee from the underlying pool, not the local state variable
    bPool.setSwapFee(_initialSwapFee);
    bPool.setPublicSwap(true);

    // "destroy" the temporary swap fee (like _initialTokens above) in case a subclass tries to use it
    _initialSwapFee = 0;
  }

  /* solhint-enable private-vars-leading-underscore */

  // Rebind BPool and pull tokens from address
  // bPool is a contract interface; function calls on it are external
  function _pullUnderlying(
    address erc20,
    address from,
    uint256 amount
  ) internal needsBPool {
    // Gets current Balance of token i, Bi, and weight of token i, Wi, from BPool.
    uint256 tokenBalance = bPool.getBalance(erc20);
    uint256 tokenWeight = bPool.getDenormalizedWeight(erc20);

    bool xfer = IERC20(erc20).transferFrom(from, address(this), amount);
    require(xfer, "ERR_ERC20_FALSE");
    bPool.rebind(erc20, badd(tokenBalance, amount), tokenWeight);
  }

  // Rebind BPool and push tokens to address
  // bPool is a contract interface; function calls on it are external
  function _pushUnderlying(
    address erc20,
    address to,
    uint256 amount
  ) internal needsBPool {
    // Gets current Balance of token i, Bi, and weight of token i, Wi, from BPool.
    uint256 tokenBalance = bPool.getBalance(erc20);
    uint256 tokenWeight = bPool.getDenormalizedWeight(erc20);
    bPool.rebind(erc20, bsub(tokenBalance, amount), tokenWeight);

    bool xfer = IERC20(erc20).transfer(to, amount);
    require(xfer, "ERR_ERC20_FALSE");
  }

  // Wrappers around corresponding core functions

  function _mintPoolShare(uint256 amount) internal {
    //_mint(amount);
  }

  function _pushPoolShare(address to, uint256 amount) internal {
    //_push(to, amount);
  }

  function _pullPoolShare(address from, uint256 amount) internal {
    //_pull(from, amount);
  }

  function _burnPoolShare(uint256 amount) internal {
    //_burn(amount);
  }
}
