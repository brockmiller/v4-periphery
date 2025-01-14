// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

/// @notice Abstract contract used to sync, send, and settle funds to the pool manager
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.
abstract contract DeltaResolver is ImmutableState {
    using TransientStateLibrary for IPoolManager;
    using SafeCast for *;

    /// @notice Emitted trying to settle a positive delta.
    error DeltaNotPositive(Currency currency);
    /// @notice Emitted trying to take a negative delta.
    error DeltaNotNegative(Currency currency);

    /// @notice Take an amount of currency out of the PoolManager
    /// @param currency Currency to take
    /// @param recipient Address to receive the currency
    /// @param amount Amount to take
    function _take(Currency currency, address recipient, uint256 amount) internal {
        poolManager.take(currency, recipient, amount);
    }

    /// @notice Pay and settle a currency to the PoolManager
    /// @dev The implementing contract must ensure that the `payer` is a secure address
    /// @param currency Currency to settle
    /// @param payer Address of the payer
    /// @param amount Amount to send
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (currency.isNative()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            _pay(currency, payer, amount);
            poolManager.settle();
        }
    }

    /// @notice Abstract function for contracts to implement paying tokens to the poolManager
    /// @dev The recipient of the payment should be the poolManager
    /// @param token The token to settle. This is known not to be the native currency
    /// @param payer The address who should pay tokens
    /// @param amount The number of tokens to send
    function _pay(Currency token, address payer, uint256 amount) internal virtual;

    /// @notice Obtain the full amount owed by this contract (negative delta)
    /// @param currency Currency to get the delta for
    /// @return amount The amount owed by this contract as a uint256
    function _getFullDebt(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is negative, it should be settled not taken.
        if (_amount > 0) revert DeltaNotNegative(currency);
        amount = uint256(-_amount);
    }

    /// @notice Obtain the full credit owed to this contract (positive delta)
    /// @param currency Currency to get the delta for
    /// @return amount The amount owed to this contract as a uint256
    function _getFullCredit(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is negative, it should be taken not settled for.
        if (_amount < 0) revert DeltaNotPositive(currency);
        amount = uint256(_amount);
    }

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            return currency.balanceOfSelf();
        } else if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullDebt(currency);
        }
        return amount;
    }

    /// @notice Calculates the amount for a take action
    function _mapTakeAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullCredit(currency);
        }
        return amount;
    }

    /// @notice Calculates the amount for a swap action
    /// @dev This is to be used for swaps where the input amount isn't known before the transaction, and
    /// isn't possible using a v4 multi-hop command.
    /// For example USDC-v2->DAI-v4->USDT. This intermediate DAI amount could be swapped using CONTRACT_BALANCE
    /// or settled using CONTRACT_BALANCE then swapped using OPEN_DELTA.
    function _mapInputAmount(uint128 amount, Currency currency) internal view returns (uint128) {
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            return currency.balanceOfSelf().toUint128();
        } else if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullCredit(currency).toUint128();
        }
        return amount;
    }
}
