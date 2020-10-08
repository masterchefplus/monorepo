// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "./IConfigurableRightsPool.sol";

interface ICRPFactory {

    /**
     * @notice Create a new CRP
     * @dev emits a LogNewCRP event
     * @param factoryAddress - the BFactory instance used to create the underlying pool
     * @param poolParams - struct containing the names, tokens, weights, balances, and swap fee
     * @param rights - struct of permissions, configuring this CRP instance (see above for definitions)
     */
    function newCrp(
        address factoryAddress,
        IConfigurableRightsPool.PoolParams calldata poolParams,
        IConfigurableRightsPool.Rights calldata rights
    )
        external
        returns (IConfigurableRightsPool);
}