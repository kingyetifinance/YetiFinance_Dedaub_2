// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IWhitelist.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/LiquityBase.sol";


/**
 * The CollSurplusPool holds all the bonus collateral that occurs from liquidations and
 * redemptions, to be claimed by the trove owner.ß
 */
contract CollSurplusPool is Ownable, CheckContract, ICollSurplusPool, LiquityBase {
    using SafeMath for uint256;

    string public constant NAME = "CollSurplusPool";

    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public troveManagerRedemptionsAddress;
    address public activePoolAddress;

    // deposited collateral tracker. Colls is always the whitelist list of all collateral tokens. Amounts
    newColls internal poolColl;

    // Collateral surplus claimable by trove owners
    mapping(address => newColls) internal balances;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);

    event CollBalanceUpdated(address indexed _account);
    event CollateralSent(address _to);

    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _troveManagerRedemptionsAddress,
        address _activePoolAddress,
        address _whitelistAddress
    ) external override onlyOwner {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_troveManagerRedemptionsAddress);
        checkContract(_activePoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        troveManagerRedemptionsAddress = _troveManagerRedemptionsAddress;
        activePoolAddress = _activePoolAddress;
        whitelist = IWhitelist(_whitelistAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    /*
     * Returns the VC of the contract
     *
     * Not necessarily equal to the the contract's raw VC balance - Collateral can be forcibly sent to contracts.
     *
     * Computed when called by taking the collateral balances and
     * multiplying them by the corresponding price and ratio and then summing that
     */
    function getCollVC() external view override returns (uint256) {
        return _getVCColls(poolColl);
    }

    /*
     * View function for getting the amount claimable by a particular trove owner.
     */
    function getAmountClaimable(address _account, address _collateral)
        external
        view
        override
        returns (uint256)
    {
        uint256 collateralIndex = whitelist.getIndex(_collateral);
        if (balances[_account].amounts.length > collateralIndex) {
            return balances[_account].amounts[collateralIndex];
        }
        return 0;
    }

    /*
     * Returns the collateralBalance for a given collateral
     *
     * Returns the amount of a given collateral in state. Not necessarily the contract's actual balance.
     */
    function getCollateral(address _collateral) public view override returns (uint256) {
        uint256 collateralIndex = whitelist.getIndex(_collateral);
        return poolColl.amounts[collateralIndex];
    }

    /*
     *
     * Returns all collateral balances in state. Not necessarily the contract's actual balances.
     */
    function getAllCollateral() public view override returns (address[] memory, uint256[] memory) {
        return (poolColl.tokens, poolColl.amounts);
    }

    // --- Pool functionality ---

    // Surplus value is accounted by the trove manager.
    function accountSurplus(
        address _account,
        address[] memory _tokens,
        uint256[] memory _amounts
    ) external override {
        _requireCallerIsTroveManager();
        balances[_account] = _sumColls(balances[_account], _tokens, _amounts);
        emit CollBalanceUpdated(_account);
    }

    // Function called by borrower operations which claims the collateral that is owned by
    // a particular trove user.
    function claimColl(address _account) external override {
        _requireCallerIsBorrowerOperations();

        newColls memory claimableColl = balances[_account];
        require(_CollsIsNonZero(claimableColl), "CollSurplusPool: No collateral available to claim");

        balances[_account].amounts = new uint256[](poolColl.tokens.length); // sets balance of account to 0
        emit CollBalanceUpdated(_account);

        poolColl.amounts = _leftSubColls(poolColl, claimableColl.tokens, claimableColl.amounts);
        emit CollateralSent(_account);

        bool success = _sendColl(_account, claimableColl);
        require(success, "CollSurplusPool: sending Collateral failed");
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(
            msg.sender == borrowerOperationsAddress,
            "CollSurplusPool: Caller is not Borrower Operations"
        );
    }

    function _requireCallerIsTroveManager() internal view {
        require(
            msg.sender == troveManagerAddress || msg.sender == troveManagerRedemptionsAddress,
            "CollSurplusPool: Caller is not TroveManager"
        );
    }

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "CollSurplusPool: Caller is not Active Pool");
    }

    function _requireCallerIsWhitelist() internal view {
        require(msg.sender == address(whitelist), "CollSurplusPool: Caller is not Whitelist");
    }

    function receiveCollateral(address[] memory _tokens, uint256[] memory _amounts)
        external
        override
    {
        _requireCallerIsActivePool();
        poolColl.amounts = _leftSumColls(poolColl, _tokens, _amounts);
    }

    // Adds collateral type from the whitelist.
    function addCollateralType(address _collateral) external override {
        _requireCallerIsWhitelist();
        poolColl.tokens.push(_collateral);
        poolColl.amounts.push(0);
    }
}
