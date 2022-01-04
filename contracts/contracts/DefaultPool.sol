// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "./Interfaces/IDefaultPool.sol";
import "./Interfaces/IActivePool.sol";
import "./Interfaces/IWhitelist.sol";
import "./Interfaces/IERC20.sol";
import "./Interfaces/IWAsset.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/YetiCustomBase.sol";


/*
 * The Default Pool holds the collateral and YUSD debt (but not YUSD tokens) from liquidations that have been redistributed
 * to active troves but not yet "applied", i.e. not yet recorded on a recipient active trove's struct.
 *
 * When a trove makes an operation that applies its pending collateral and YUSD debt, its pending collateral and YUSD debt is moved
 * from the Default Pool to the Active Pool.
 */
contract DefaultPool is Ownable, CheckContract, IDefaultPool, YetiCustomBase {
    using SafeMath for uint256;

    string public constant NAME = "DefaultPool";

    address public troveManagerAddress;
    address public activePoolAddress;
    address public whitelistAddress;
    address public yetiFinanceTreasury;

    // deposited collateral tracker. Colls is always the whitelist list of all collateral tokens. Amounts
    newColls internal poolColl;

    uint256 internal YUSDDebt;

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolYUSDDebtUpdated(uint256 _YUSDDebt);
    event DefaultPoolBalanceUpdated(address _collateral, uint256 _amount);
    event DefaultPoolBalancesUpdated(address[] _collaterals, uint256[] _amounts);

    // --- Dependency setters ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _whitelistAddress, 
        address _yetiTreasuryAddress
    ) external onlyOwner {
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_whitelistAddress);
        checkContract(_yetiTreasuryAddress);

        troveManagerAddress = _troveManagerAddress;
        activePoolAddress = _activePoolAddress;
        whitelist = IWhitelist(_whitelistAddress);
        whitelistAddress = _whitelistAddress;
        yetiFinanceTreasury = _yetiTreasuryAddress;

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    // --- Internal Functions ---

    // --- Getters for public variables. Required by IPool interface ---

    /*
     * Returns the collateralBalance for a given collateral
     *
     * Returns the amount of a given collateral in state. Not necessarily the contract's actual balance.
     */
    function getCollateral(address _collateral) public view override returns (uint256) {
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
    function getVC() external view override returns (uint256 totalVC) {
        for (uint256 i = 0; i < poolColl.tokens.length; i++) {
            address collateral = poolColl.tokens[i];
            uint256 amount = poolColl.amounts[i];

            uint256 collateralVC = whitelist.getValueVC(collateral, amount);
            totalVC = totalVC.add(collateralVC);
        }
        return totalVC;
    }

    // Debt that this pool holds. 
    function getYUSDDebt() external view override returns (uint256) {
        return YUSDDebt;
    }

    // Internal function to send collateral to a different pool. 
    function _sendCollateral(address _collateral, uint256 _amount) internal {
        address activePool = activePoolAddress;
        uint256 index = whitelist.getIndex(_collateral);
        poolColl.amounts[index] = poolColl.amounts[index].sub(_amount);

        emit DefaultPoolBalanceUpdated(_collateral, _amount);
        emit CollateralSent(_collateral, activePool, _amount);

        bool success = IERC20(_collateral).transfer(activePool, _amount);
        require(success, "DefaultPool: sending collateral failed");
    }

    // Returns true if all payments were successfully sent. Must be called by borrower operations, trove manager, or stability pool. 
    function sendCollsToActivePool(address[] memory _tokens, uint256[] memory _amounts, address _borrower)
        external
        override
    {
        _requireCallerIsTroveManager();
        address activePool = activePoolAddress;
        require(_tokens.length == _amounts.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            _sendCollateral(_tokens[i], _amounts[i]);
            if (whitelist.isWrapped(_tokens[i])) {
                IWAsset(_tokens[i]).updateReward(yetiFinanceTreasury, _borrower, _amounts[i]);
            }
        }
        IActivePool(activePool).receiveCollateral(_tokens, _amounts);
    }

    // Increases the YUSD Debt of this pool. 
    function increaseYUSDDebt(uint256 _amount) external override {
        _requireCallerIsTroveManager();
        YUSDDebt = YUSDDebt.add(_amount);
        emit DefaultPoolYUSDDebtUpdated(YUSDDebt);
    }

    // Decreases the YUSD Debt of this pool.
    function decreaseYUSDDebt(uint256 _amount) external override {
        _requireCallerIsTroveManager();
        YUSDDebt = YUSDDebt.sub(_amount);
        emit DefaultPoolYUSDDebtUpdated(YUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "DefaultPool: Caller is not the TroveManager");
    }

    function _requireCallerIsWhitelist() internal view {
        require(msg.sender == whitelistAddress, "DefaultPool: Caller is not whitelist");
    }

    // Should be called by ActivePool
    // __after__ collateral is transferred to this contract from Active Pool
    function receiveCollateral(address[] memory _tokens, uint256[] memory _amounts)
        external
        override
    {
        _requireCallerIsActivePool();
        poolColl.amounts = _leftSumColls(poolColl, _tokens, _amounts);
        emit DefaultPoolBalancesUpdated(_tokens, _amounts);
    }

    // Adds collateral type from whitelist. 
    function addCollateralType(address _collateral) external override {
        _requireCallerIsWhitelist();
        poolColl.tokens.push(_collateral);
        poolColl.amounts.push(0);
    }
}
