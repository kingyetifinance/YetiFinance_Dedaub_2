// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import './Interfaces/IActivePool.sol';
import "./Interfaces/IWhitelist.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/IDefaultPool.sol";
import './Interfaces/IERC20.sol';
import "./Interfaces/IWAsset.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/YetiCustomBase.sol";


/*
 * The Active Pool holds the all collateral and YUSD debt (but not YUSD tokens) for all active troves.
 *
 * When a trove is liquidated, its collateral and YUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is Ownable, CheckContract, IActivePool, YetiCustomBase {
    using SafeMath for uint256;

    string constant public NAME = "ActivePool";

    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public stabilityPoolAddress;
    address public defaultPoolAddress;
    address public troveManagerLiquidationsAddress;
    address public troveManagerRedemptionsAddress;
    address public whitelistAddress;
    address public collSurplusPoolAddress;

    
    // deposited collateral tracker. Colls is always the whitelist list of all collateral tokens. Amounts 
    newColls internal poolColl;

    // YUSD Debt tracker. Tracker of all debt in the system. 
    uint256 internal YUSDDebt;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolYUSDDebtUpdated(uint _YUSDDebt);
    event ActivePoolBalanceUpdated(address _collateral, uint _amount);
    event ActivePoolBalancesUpdated(address[] _collaterals, uint256[] _amounts);
    event CollateralsSent(address[] _collaterals, uint256[] _amounts, address _to);

    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress,
        address _whitelistAddress,
        address _troveManagerLiquidationsAddress,
        address _troveManagerRedemptionsAddress,
        address _collSurplusPoolAddress
    )
        external
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_whitelistAddress);
        checkContract(_troveManagerLiquidationsAddress);
        checkContract(_troveManagerRedemptionsAddress);
        checkContract(_collSurplusPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;
        whitelist = IWhitelist(_whitelistAddress);
        troveManagerLiquidationsAddress = _troveManagerLiquidationsAddress;
        troveManagerRedemptionsAddress = _troveManagerRedemptionsAddress;
        whitelistAddress = _whitelistAddress;
        collSurplusPoolAddress = _collSurplusPoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit WhitelistAddressChanged(_whitelistAddress);

        _renounceOwnership();
    }

    // --- Internal Functions ---

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the collateralBalance for a given collateral
    *
    * Returns the amount of a given collateral in state. Not necessarily the contract's actual balance.
    */
    function getCollateral(address _collateral) public view override returns (uint) {
        return poolColl.amounts[whitelist.getIndex(_collateral)];
    }

    /*
    * Returns all collateral balances in state. Not necessarily the contract's actual balances.
    */
    function getAllCollateral() public view override returns (address[] memory, uint256[] memory) {
        return (poolColl.tokens, poolColl.amounts);
    }

    // returns the VC value of a given collateralAddress in this contract
    function getCollateralVC(address _collateral) external view override returns (uint) {
        return whitelist.getValueVC(_collateral, getCollateral(_collateral));
    }


    /*
    * Returns the VC of the contract
    *
    * Not necessarily equal to the the contract's raw VC balance - Collateral can be forcibly sent to contracts.
    *
    * Computed when called by taking the collateral balances and
    * multiplying them by the corresponding price and ratio and then summing that
    */
    function getVC() external view override returns (uint totalVC) {
        for (uint i = 0; i < poolColl.tokens.length; i++) {
            address collateral = poolColl.tokens[i];
            uint amount = poolColl.amounts[i];

            uint collateralVC = whitelist.getValueVC(collateral, amount);

            totalVC = totalVC.add(collateralVC);
        }
        return totalVC;
    }


    // Debt that this pool holds. 
    function getYUSDDebt() external view override returns (uint) {
        return YUSDDebt;
    }

    // --- Pool functionality ---

    // Internal function to send collateral to a different pool. 
    function _sendCollateral(address _to, address _collateral, uint _amount) internal returns (bool) {
        uint index = whitelist.getIndex(_collateral);
        poolColl.amounts[index] = poolColl.amounts[index].sub(_amount);
        bool sent = IERC20(_collateral).transfer(_to, _amount);
        require(sent);

        emit ActivePoolBalanceUpdated(_collateral, _amount);
        emit CollateralSent(_collateral, _to, _amount);
    }

    // Returns true if all payments were successfully sent. Must be called by borrower operations, trove manager, or stability pool. 
    function sendCollaterals(address _to, address[] memory _tokens, uint[] memory _amounts) external override returns (bool) {
        _requireCallerIsBOorTroveMorTMLorSP();
        require(_tokens.length == _amounts.length);
        for (uint i = 0; i < _tokens.length; i++) {
            _sendCollateral(_to, _tokens[i], _amounts[i]); // reverts if send fails
        }

        if (_needsUpdateCollateral(_to)) {
            ICollateralReceiver(_to).receiveCollateral(_tokens, _amounts);
        }

        emit CollateralsSent(_tokens, _amounts, _to);
        
        return true;
    }

    // Returns true if all payments were successfully sent. Must be called by borrower operations, trove manager, or stability pool.
    // This function als ounwraps the collaterals and sends them to _to, if they are wrapped assets. If collect rewards is set to true,
    // It also harvests rewards on the user's behalf. 
    function sendCollateralsUnwrap(address _to, address[] memory _tokens, uint[] memory _amounts, bool _collectRewards) external override returns (bool) {
        _requireCallerIsBOorTroveMorTMLorSP();
        require(_tokens.length == _amounts.length);
        for (uint i = 0; i < _tokens.length; i++) {
            if (whitelist.isWrapped(_tokens[i])) {
                IWAsset(_tokens[i]).unwrapFor(_to, _amounts[i]);
                if (_collectRewards) {
                    IWAsset(_tokens[i]).claimRewardFor(_to);
                }
            } else {
                _sendCollateral(_to, _tokens[i], _amounts[i]); // reverts if send fails
            }
        }
        return true;
    }

    // View function that returns if the contract transferring to needs to have its balances updated. 
    function _needsUpdateCollateral(address _contractAddress) internal view returns (bool) {
        return ((_contractAddress == defaultPoolAddress) || (_contractAddress == stabilityPoolAddress) || (_contractAddress == collSurplusPoolAddress));
    }

    // Increases the YUSD Debt of this pool. 
    function increaseYUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        YUSDDebt  = YUSDDebt.add(_amount);
        emit ActivePoolYUSDDebtUpdated(YUSDDebt);
    }

    // Decreases the YUSD Debt of this pool. 
    function decreaseYUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        YUSDDebt = YUSDDebt.sub(_amount);
        emit ActivePoolYUSDDebtUpdated(YUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBOorTroveMorTMLorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress ||
            msg.sender == stabilityPoolAddress ||
            msg.sender == troveManagerLiquidationsAddress ||
            msg.sender == troveManagerRedemptionsAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool");
    }

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool");
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress ||
            msg.sender == stabilityPoolAddress ||
            msg.sender == troveManagerRedemptionsAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool");
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager");
    }

    function _requireCallerIsWhitelist() internal view {
        require(
        msg.sender == whitelistAddress,
        "ActivePool: Caller is not whitelist");
    }

    // should be called by BorrowerOperations or DefaultPool
    // __after__ collateral is transferred to this contract.
    function receiveCollateral(address[] memory _tokens, uint[] memory _amounts) external override {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        poolColl.amounts = _leftSumColls(poolColl, _tokens, _amounts);
        emit ActivePoolBalancesUpdated(_tokens, _amounts);
    }

    // Adds collateral type from whitelist. 
    function addCollateralType(address _collateral) external override {
        _requireCallerIsWhitelist();
        poolColl.tokens.push(_collateral);
        poolColl.amounts.push(0);
    }

}
