// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "./Ownable.sol";
import "../Interfaces/IBaseOracle.sol";
import "../Interfaces/IWhitelist.sol";
import "../Interfaces/IPriceFeed.sol";
import "../Interfaces/IPriceCurve.sol";
import "../Interfaces/IActivePool.sol";
import "../Interfaces/IDefaultPool.sol";
import "../Interfaces/IStabilityPool.sol";
import "../Interfaces/ICollSurplusPool.sol";
import "../Interfaces/IERC20.sol";
import "./LiquityMath.sol";
import "./CheckContract.sol";


/**
 * Whitelist is the contract that keeps track of all the assets that the system takes as collateral.
 * It has onlyOwner functions to add or deprecate collaterals from the whitelist, change the price
 * curve, price feed, safety ratio, etc.
 */

contract Whitelist is Ownable, IWhitelist, IBaseOracle, CheckContract {
    using SafeMath for uint256;

    struct CollateralParams {
        // Safety ratio
        uint256 safetyRatio; // 10**18 * the ratio. i.e. ratio = .95 * 10**18 for 95%. More risky collateral has a lower ratio
        uint256 recoveryRatio;
        address oracle;
        uint256 decimals;
        address priceCurve;
        uint256 index;
        address defaultRouter;
        bool active;
        bool isWrapped;
    }

    IActivePool activePool;
    IDefaultPool defaultPool;
    IStabilityPool stabilityPool;
    ICollSurplusPool collSurplusPool;
    address borrowerOperationsAddress;
    bool private addressesSet;

    mapping(address => address) validCallers;
    mapping(address => bool) pendingLockCallers;
    mapping(address => bool) cannotUpdateValidCaller;

    mapping(address => CollateralParams) public collateralParams;
    // list of all collateral types in collateralParams (active and deprecated)
    // Addresses for easy access
    address[] public validCollateral; // index maps to token address.

    uint256 maxCollsInTrove = 50; // TODO: update to a reasonable number

    event CollateralAdded(address _collateral);
    event CollateralDeprecated(address _collateral);
    event CollateralUndeprecated(address _collateral);
    event OracleChanged(address _collateral, address _newOracle);
    event PriceCurveChanged(address _collateral, address _newPriceCurve);
    event SafetyRatioChanged(address _collateral, uint256 _newSafetyRatio);
    event RecoveryRatioChanged(address _collateral, uint256 _newRecoveryRatio);

    // Require that the collateral exists in the whitelist. If it is not the 0th index, and the
    // index is still 0 then it does not exist in the mapping.
    // no require here for valid collateral 0 index because that means it exists. 
    modifier exists(address _collateral) {
        _exists(_collateral);
        _;
    }

    // Calling from here makes it not inline, reducing contract size significantly. 
    function _exists(address _collateral) internal view {
        if (validCollateral[0] != _collateral) {
            require(collateralParams[_collateral].index != 0, "collateral does not exist");
        }
    }

    // ----------Only Owner Setter Functions----------

    function setAddresses(
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _collSurplusPoolAddress,
        address _borrowerOperationsAddress
    ) external override onlyOwner {
        require(!addressesSet, "addresses already set");
        checkContract(_activePoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_borrowerOperationsAddress);

        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        borrowerOperationsAddress = _borrowerOperationsAddress;
        addressesSet = true;
    }

    function addCollateral(
        address _collateral,
        uint256 _safetyRatio,
        uint256 _recoveryRatio,
        address _oracle,
        uint256 _decimals,
        address _priceCurve, 
        bool _isWrapped, 
        address _routerAddress
    ) external onlyOwner {
        checkContract(_collateral);
        checkContract(_oracle);
        checkContract(_priceCurve);
        checkContract(_routerAddress);
        // If collateral list is not 0, and if the 0th index is not equal to this collateral,
        // then if index is 0 that means it is not set yet.
        require(_safetyRatio < 11e17, "ratio must be less than 1.10"); //=> greater than 1.1 would mean taking out more YUSD than collateral VC

        if (validCollateral.length != 0) {
            require(validCollateral[0] != _collateral && collateralParams[_collateral].index == 0, "collateral already exists");
        }

        validCollateral.push(_collateral);
        collateralParams[_collateral] = CollateralParams(
            _safetyRatio,
            _recoveryRatio,
            _oracle,
            _decimals,
            _priceCurve,
            validCollateral.length - 1, 
            _routerAddress,
            true,
            _isWrapped
        );

        activePool.addCollateralType(_collateral);
        defaultPool.addCollateralType(_collateral);
        stabilityPool.addCollateralType(_collateral);
        collSurplusPool.addCollateralType(_collateral);

        // throw event
        emit CollateralAdded(_collateral);
        emit SafetyRatioChanged(_collateral, _safetyRatio);
        emit RecoveryRatioChanged(_collateral, _recoveryRatio);
    }

    /**
     * Deprecate collateral by not allowing any more collateral to be added of this type.
     * Still can interact with it via validCollateral and CollateralParams
     */
    function deprecateCollateral(address _collateral) external exists(_collateral) onlyOwner {
        checkContract(_collateral);

        require(collateralParams[_collateral].active, "collateral already deprecated");

        collateralParams[_collateral].active = false;

        // throw event
        emit CollateralDeprecated(_collateral);
    }

    /**
     * Undeprecate collateral by allowing more collateral to be added of this type.
     * Still can interact with it via validCollateral and CollateralParams
     */
    function undeprecateCollateral(address _collateral) external exists(_collateral) onlyOwner {
        checkContract(_collateral);

        require(!collateralParams[_collateral].active, "collateral is already active");

        collateralParams[_collateral].active = true;

        // throw event
        emit CollateralUndeprecated(_collateral);
    }

    /**
     * Function to change oracles
     */
    function changeOracle(address _collateral, address _oracle)
        external
        exists(_collateral)
        onlyOwner
    {
        checkContract(_collateral);
        checkContract(_oracle);
        collateralParams[_collateral].oracle = _oracle;

        // throw event
        emit OracleChanged(_collateral, _oracle);
    }

    /**
     * Function to change price curve
     */
    function changePriceCurve(address _collateral, address _priceCurve)
        external
        exists(_collateral)
        onlyOwner
    {
        checkContract(_collateral);
        checkContract(_priceCurve);

        (uint256 lastFeePercent, uint256 lastFeeTime) = IPriceCurve(collateralParams[_collateral].priceCurve).getFeeCapAndTime();
        IPriceCurve(_priceCurve).setFeeCapAndTime(lastFeePercent, lastFeeTime);
        collateralParams[_collateral].priceCurve = _priceCurve;

        // throw event
        emit PriceCurveChanged(_collateral, _priceCurve);
    }

    /**
     * Function to change Safety ratio.
     */
    function changeSafetyRatio(address _collateral, uint256 _newSafetyRatio)
        external
        exists(_collateral)
        onlyOwner
    {
        require(_newSafetyRatio < 11e17, "ratio must be less than 1.10"); //=> greater than 1.1 would mean taking out more YUSD than collateral VC
        require(collateralParams[_collateral].safetyRatio < _newSafetyRatio, "New SR must be greater than previous SR");
        collateralParams[_collateral].safetyRatio = _newSafetyRatio;

        // throw event
        emit SafetyRatioChanged(_collateral, _newSafetyRatio);
    }

    /**
     * Function to change Stable Adjusted Safety ratio. 
     */
    function changeRecoveryRatio(address _collateral, uint256 _newRecoveryRatio)
        external
        exists(_collateral)
        onlyOwner
    {
        collateralParams[_collateral].recoveryRatio = _newRecoveryRatio;

        // throw event
        emit RecoveryRatioChanged(_collateral, _newRecoveryRatio);
    }

    // -----------Routers--------------

    function setDefaultRouter(address _collateral, address _router) external override onlyOwner exists(_collateral) {
        checkContract(_router);
        collateralParams[_collateral].defaultRouter = _router;
    }

    function getDefaultRouterAddress(address _collateral) external view override exists(_collateral) returns (address) {
        return collateralParams[_collateral].defaultRouter;
    }


    // ---------- View Functions -----------

    function isWrapped(address _collateral) external view override returns (bool) {
        return collateralParams[_collateral].isWrapped;
    }

    function getValidCollateral() external view override returns (address[] memory) {
        return validCollateral;
    }

    // Get safety ratio used in VC Calculation
    function getSafetyRatio(address _collateral)
        external
        view
        override
        returns (uint256)
    {
        return collateralParams[_collateral].safetyRatio;
    }

    // Get safety ratio used in TCR calculation, as well as for redemptions. 
    // Often similar to Safety Ratio except for stables.
    function getRecoveryRatio(address _collateral)
        external
        view
        override
        exists(_collateral)
        returns (uint256)
    {
        return collateralParams[_collateral].recoveryRatio;
    }

    function getOracle(address _collateral)
        external
        view
        override
        exists(_collateral)
        returns (address)
    {
        return collateralParams[_collateral].oracle;
    }

    function getPriceCurve(address _collateral)
        external
        view
        override
        exists(_collateral)
        returns (address)
    {
        return collateralParams[_collateral].priceCurve;
    }

    function getIsActive(address _collateral)
        external
        view
        override
        exists(_collateral)
        returns (bool)
    {
        return collateralParams[_collateral].active;
    }

    function getDecimals(address _collateral)
        external
        view
        override
        exists(_collateral)
        returns (uint256)
    {
        return collateralParams[_collateral].decimals;
    }

    function getIndex(address _collateral)
        external
        view
        override
        exists(_collateral)
        returns (uint256)
    {
        return (collateralParams[_collateral].index);
    }

    // Returned as fee percentage * 10**18. View function for external callers.
    function getFee(
        address _collateral,
        uint256 _collateralVCInput,
        uint256 _collateralVCSystemBalance,
        uint256 _totalVCBalancePre,
        uint256 _totalVCBalancePost
    ) external view override exists(_collateral) returns (uint256 fee) {
        IPriceCurve priceCurve = IPriceCurve(collateralParams[_collateral].priceCurve);
        return priceCurve.getFee(_collateralVCInput, _collateralVCSystemBalance, _totalVCBalancePre, _totalVCBalancePost);
    }

    // Returned as fee percentage * 10**18. Non view function for just borrower operations to call.
    function getFeeAndUpdate(
        address _collateral,
        uint256 _collateralVCInput,
        uint256 _collateralVCSystemBalance,
        uint256 _totalVCBalancePre,
        uint256 _totalVCBalancePost
    ) external override exists(_collateral) returns (uint256 fee) {
        require(
            msg.sender == borrowerOperationsAddress,
            "caller must be BO"
        );
        IPriceCurve priceCurve = IPriceCurve(collateralParams[_collateral].priceCurve);
        return
            priceCurve.getFeeAndUpdate(
                _collateralVCInput,
                _collateralVCSystemBalance,
                _totalVCBalancePre,
                _totalVCBalancePost
            );
    }

    // should return 10**18 times the price in USD of 1 of the given _collateral
    function getPrice(address _collateral)
        public
        view
        override
        returns (uint256)
    {
        IPriceFeed collateral_priceFeed = IPriceFeed(collateralParams[_collateral].oracle);
        return collateral_priceFeed.fetchPrice_v();
    }

    // Gets the value of that collateral type, of that amount, in USD terms.
    function getValueUSD(address _collateral, uint256 _amount)
        external
        view
        override
        returns (uint256)
    {
        return _getValueUSD(_collateral, _amount);
    }

    // Aggregates all usd values of passed in collateral / amounts
    function getValuesUSD(address[] memory _collaterals, uint256[] memory _amounts)
        external
        view
        override
        returns (uint256 USDValue)
    {
        uint256 tokensLen = _collaterals.length;
        for (uint i; i < tokensLen; ++i) {
            USDValue = USDValue.add(_getValueUSD(_collaterals[i], _amounts[i]));
        }
    }

    function _getValueUSD(address _collateral, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        uint256 decimals = collateralParams[_collateral].decimals;
        uint256 price = getPrice(_collateral);
        return price.mul(_amount).div(10**decimals);
    }

    // Gets the value of that collateral type, of that amount, in VC terms.
    function getValueVC(address _collateral, uint256 _amount)
        external
        view
        override
        returns (uint256)
    {
        return _getValueVC(_collateral, _amount);
    }

    function getValuesVC(address[] memory _collaterals, uint256[] memory _amounts)
        external
        view
        override
        returns (uint256 VCValue)
    {
        uint256 tokensLen = _collaterals.length;
        for (uint i; i < tokensLen; ++i) {
            VCValue = VCValue.add(_getValueVC(_collaterals[i], _amounts[i]));
        }
    }

    function _getValueVC(address _collateral, uint256 _amount) 
        internal 
        view 
        returns (uint256) {
        // Multiply price by amount and safety ratio to get in VC terms, as well as dividing by amount of decimals to normalize. 
        return ((getPrice(_collateral)).mul(_amount).mul(collateralParams[_collateral].safetyRatio).div(10**(18 + collateralParams[_collateral].decimals)));
    }

    // Gets the value of that collateral type, of that amount, in Recovery VC terms.
    function getValueRVC(address _collateral, uint256 _amount)
        external
        view
        override
        returns (uint256)
    {
        return _getValueRVC(_collateral, _amount);
    }

    function getValuesRVC(address[] memory _collaterals, uint256[] memory _amounts)
        external
        view
        override
        returns (uint256 RVCValue)
    {
        uint256 tokensLen = _collaterals.length;
        for (uint i; i < tokensLen; ++i) {
            RVCValue = RVCValue.add(_getValueRVC(_collaterals[i], _amounts[i]));
        }
    }

    function _getValueRVC(address _collateral, uint256 _amount) 
        internal 
        view 
        returns (uint256) {
        // Multiply price by amount and recovery ratio to get in Recovery VC terms, as well as dividing by amount of decimals to normalize. 
        return ((getPrice(_collateral)).mul(_amount).mul(collateralParams[_collateral].recoveryRatio).div(10**(18 + collateralParams[_collateral].decimals)));
    }

    // Gets the TCR value of that collateral type, of that amount, in TCR VC terms. Also returns the regular Value VC. 
    // Used in the active pool and default pool VC calculations. 
    function getValueVCforTCR(address _collateral, uint256 _amount)
        external
        view
        override
        returns (uint256, uint256)
    {
        return _getValueVCforTCR(_collateral, _amount);
    }

    function getValuesVCforTCR(address[] memory _collaterals, uint256[] memory _amounts)
        external
        view
        override
        returns (uint256 VCValue, uint256 RVCValue)
    {
        uint256 tokensLen = _collaterals.length;
        for (uint i; i < tokensLen; ++i) {
            (uint256 tempVCValue, uint256 tempRVCValue) = _getValueVCforTCR(_collaterals[i], _amounts[i]);
            VCValue = VCValue.add(tempVCValue);
            RVCValue = RVCValue.add(tempRVCValue);
        }
    }

    function _getValueVCforTCR(address _collateral, uint256 _amount) 
        internal 
        view 
        returns (uint256 VC, uint256 VCforTCR) {
        uint256 price = getPrice(_collateral);
        uint256 decimals = collateralParams[_collateral].decimals;
        uint256 safetyRatio = collateralParams[_collateral].safetyRatio;
        uint256 recoveryRatio = collateralParams[_collateral].recoveryRatio;
        VC = price.mul(_amount).mul(safetyRatio).div(10**(18 + decimals));
        VCforTCR = price.mul(_amount).mul(recoveryRatio).div(10**(18 + decimals));
    }


    // ===== Contract Callers ======

    /* msg.sender is the Yeti contract calling this function
     * _caller is the caller of that contract on the Yeti contract
     * this function confirms whether the caller of the Yeti Contract is
     * allowed to call that function
     */
    function isValidCaller(address _caller) external override view returns (bool) {
        return (validCallers[msg.sender] == _caller);
    }


    function getValidCaller(address _contract) external override view returns (address) {
        return validCallers[_contract];
    }

    // Changing/Locking Contract Callers:

    function updateValidCaller(address _contract, address _caller) onlyOwner external {
        require(!cannotUpdateValidCaller[_contract], "cannot update valid caller of this contract");
        validCallers[_contract] = _caller;
    }


    function updatePendingLockCaller(address _contract, bool _lock) onlyOwner external {
        pendingLockCallers[_contract] = _lock;
    }


    function lockCaller(address _contract) onlyOwner external {
        cannotUpdateValidCaller[_contract] = pendingLockCallers[_contract];
    }

    // Max Colls in Trove Functions

    function updateMaxCollsInTrove(uint _newMax) onlyOwner external {
        maxCollsInTrove = _newMax;
    }
}
