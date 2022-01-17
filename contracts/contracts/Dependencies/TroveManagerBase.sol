// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "../Interfaces/ITroveManager.sol";
import "../Interfaces/IStabilityPool.sol";
import "../Interfaces/ICollSurplusPool.sol";
import "../Interfaces/IYUSDToken.sol";
import "../Interfaces/ISortedTroves.sol";
import "../Interfaces/IYETIToken.sol";
import "../Interfaces/ISYETI.sol";
import "../Interfaces/IActivePool.sol";
import "../Interfaces/ITroveManagerLiquidations.sol";
import "../Interfaces/ITroveManagerRedemptions.sol";
import "./LiquityBase.sol";
import "./Ownable.sol";

/** 
 * Contains shared functionality of TroveManagerLiquidations, TroveManagerRedemptions, and TroveManager. 
 * Keeps addresses to cache, events, structs, status, etc. Also keeps Trove struct. 
 */

contract TroveManagerBase is LiquityBase, Ownable {

    // --- Connected contract declarations ---

    // A doubly linked list of Troves, sorted by their sorted by their individual collateral ratios

    struct ContractsCache {
        IActivePool activePool;
        IDefaultPool defaultPool;
        IYUSDToken yusdToken;
        ISYETI sYETI;
        ISortedTroves sortedTroves;
        ICollSurplusPool collSurplusPool;
        address gasPoolAddress;
    }

    struct SingleRedemptionValues {
        uint YUSDLot;
        newColls CollLot;
        bool cancelledPartial;
    }

    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        closedByRedemption
    }

    enum TroveManagerOperation {
        applyPendingRewards,
        liquidateInNormalMode,
        liquidateInRecoveryMode,
        redeemCollateral
    }

    // Store the necessary data for a trove
    struct Trove {
        newColls colls;
        uint debt;
        mapping(address => uint) stakes;
        Status status;
        uint128 arrayIndex;
    }


    event TroveUpdated(address indexed _borrower, uint _debt, address[] _tokens, uint[] _amounts, TroveManagerOperation operation);
}
