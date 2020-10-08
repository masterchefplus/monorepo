// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "./IBPool.sol";

interface IConfigurableRightsPool {
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

  struct Rights {
    bool canPauseSwapping;
    bool canChangeSwapFee;
    bool canChangeWeights;
    bool canAddRemoveTokens;
    bool canWhitelistLPs;
    bool canChangeCap;
  }

  function bPool() external returns (IBPool);

  function createPool(uint256 initialSupply) external;

  function updateWeight(address token, uint256 newWeight) external;
}
