// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.7;

import "./ERC20_8.sol";
import "./Interfaces/IWAsset.sol";
// import "./Interfaces/IAaveIncentivesController.sol";

interface IAaveIncentivesController {
    /**
   * @dev Returns the total of rewards of an user, already accrued + not yet accrued
   * @param user The address of the user
   * @return The rewards
   **/
  function getRewardsBalance(address[] calldata assets, address user)
    external
    view
    returns (uint256);

    /**
   * @dev Claims reward for an user, on all the assets of the lending pool, accumulating the pending rewards
   * @param amount Amount of rewards to claim
   * @param to Address that will be receiving the rewards
   * @return Rewards claimed
   **/
  function claimRewards(
    address[] calldata assets,
    uint256 amount,
    address to
  ) external returns (uint256);

  /**
   * @dev returns the unclaimed rewards of the user
   * @param user the address of the user
   * @return the unclaimed user rewards
   */
  function getUserUnclaimedRewards(address user) external view returns (uint256);

  /**
  * @dev for backward compatibility with previous implementation of the Incentives controller
  */
  function REWARD_TOKEN() external view returns (address);
}


// ----------------------------------------------------------------------------
// Wrapped AAVE token Contract (represents staked aToken earning interest and AVAX rush rewards)
// aTokens remain 1:1 backed by the underlying token. 
// AVAX rush incentives are distributed through IAaveIncentivesController contract
// Distributes rewards to the owner of the token so we have to keep track of that for our 
// wrappers who are entering the protocol with this token. We can check the reward balance accrued 
// to that token when they claim rewards. 
// ----------------------------------------------------------------------------
contract WAAVE is ERC20_8, IWAsset {

    IERC20 public aToken;
    // Taken in as a param to aave claim rewards function. Just has aToken in it. 
    address[] public aTokenArray = new address[](1); 
    IAaveIncentivesController aaveIncentivesController;
    // uint public _poolPid;

    address internal activePool;
    address internal TML;
    address internal TMR;
    address internal defaultPool;
    address internal stabilityPool;
    address internal YetiFinanceTreasury;
    address internal borrowerOperations;
    address internal collSurplusPool;
    uint public SHAREOFFSET=1e12;
    bool internal addressesSet;

    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 interest;
        uint256 snapshotAAVE; // Current AAVE balance: numerator
        uint256 outstandingShares; // Current outstanding shares of QItoken wrapped
        // To calculate a user's reward share we need to know how much of the rewards has been provided when they wrap their aToken.
        // We can calculate the initial rewardAmount per share as rewardAmount / outstandingShares.
        // Upon unwrapping we can calculate the rewards they are entitled to as amount * ((newRewardAmout / newOutstandingShares)-(initialRewardAmount/initialOutstandingShares)).
        uint256 amountInYeti;
    }


    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) userInfo;


    /* ========== INITIALIZER ========== */

    constructor(string memory ERC20_symbol,
        string memory ERC20_name,
        uint8 ERC20_decimals,
        IERC20 _aToken, 
        IAaveIncentivesController _aaveIncentivesController
        ) {

        checkContract(address(_aToken));
        checkContract(address(_aaveIncentivesController));

        _symbol = ERC20_symbol;
        _name = ERC20_name;
        _decimals = ERC20_decimals;
        _totalSupply = 0;

        aToken = _aToken;
        aTokenArray[0] = address(aToken);
        aaveIncentivesController = _aaveIncentivesController;
    }

    function setAddresses(
        address _activePool,
        address _TML,
        address _TMR,
        address _defaultPool,
        address _stabilityPool,
        address _YetiFinanceTreasury, 
        address _borrowerOperations, 
        address _collSurplusPool) external {
        require(!addressesSet);
        checkContract(_activePool);
        checkContract(_TML);
        checkContract(_TMR);
        checkContract(_defaultPool);
        checkContract(_stabilityPool);
        checkContract(_YetiFinanceTreasury);
        checkContract(_borrowerOperations);
        checkContract(_collSurplusPool);
        activePool = _activePool;
        TML = _TML;
        TMR = _TMR;
        defaultPool = _defaultPool;
        stabilityPool = _stabilityPool;
        YetiFinanceTreasury = _YetiFinanceTreasury;
        borrowerOperations = _borrowerOperations;
        collSurplusPool = _collSurplusPool;
        addressesSet = true;
    }

    /* ========== New Functions =============== */


   

    // Can be called by anyone.
    // This function pulls in _amount base tokens from _from, then stakes them in
    // to mint WAssets which it sends to _to. It also updates
    // _rewardOwner's reward tracking such that it now has the right to
    // future yields from the newly minted WAssets
    function wrap(uint _amount, address _from, address _to, address _rewardRecipient) external override {
        if (msg.sender != borrowerOperations) {
            // Unless the caller is borrower operations, msg.sender and _from cannot 
            // be different. 
            require(msg.sender == _from, "WJLP: msg.sender and _from must be the same");
        }

        // Transfer token from the user to this contract and mint WAtoken.
        aToken.transferFrom(msg.sender, address(this), _amount);
        _mint(_to, 1e18*_amount/aavePerShare());

        // Update reward balances. 
        // TODO 
        _userUpdate(_rewardRecipient, _amount, true);

        if (_to == activePool) {
            userInfo[_rewardRecipient].amountInYeti += _amount;
        }
    }


    function aavePerShare() public view returns (uint) {
        if (_totalSupply==0) {
            return 1e18;
        }
        return 1e18*aToken.balanceOf(address(this))/_totalSupply;
    }

    function unwrap(uint _amount) external override {
        // Update reward balances and claim reward. 
        // TODO 
        _userUpdate(msg.sender, _amount, false);

        _burn(msg.sender, _amount);
        aToken.transfer(msg.sender, _amount*aavePerShare()/1e18);
    }


    // Only callable by ActivePool or StabilityPool
    // Used to provide unwrap assets during:
    // 1. Sending 0.5% liquidation reward to liquidators
    // 2. Sending back redeemed assets
    // In both cases, the wrapped asset is first sent to the liquidator or redeemer respectively,
    // then this function is called with _for equal to the the liquidator or redeemer address
    // Prior to this being called, the user whose assets we are burning should have their rewards updated
    function unwrapFor(address _from, address _to, uint _amount) external override {
        _requireCallerIsPool(); 

        // Update reward balances and claim reward. 
        // TODO 
        _userUpdate(_from, _amount, false);
        userInfo[_from].amountInYeti -= _amount;
        
        _burn(msg.sender, _amount);
        aToken.transfer(_to, _amount*aavePerShare()/1e18);
    }

    // When funds are transferred into the stabilityPool on liquidation,
    // the rewards these funds are earning are allocated Yeti Finance Treasury.
    // But when an stabilityPool depositor wants to withdraw their collateral,
    // the wAsset is unwrapped and the rewards are no longer accruing to the Yeti Finance Treasury
    function endTreasuryReward(address _to, uint _amount) external override {
        _requireCallerIsSPorDP();
        // Update reward balances and claim reward 
        // TODO 
        _updateReward(YetiFinanceTreasury, _to, _amount);
    }

    // Decreases _from's amount of LP tokens earning yield by _amount
    // And increases _to's amount of LP tokens earning yield by _amount
    // If _to is address(0), then doesn't increase anyone's amount
    function updateReward(address _from, address _to, uint _amount) external override {
        _requireCallerIsLRDorBO();

        // Update reward balances and claim reward 
        // TODO
        _updateReward(_from, _to, _amount);
    }

    function _updateReward(address _from, address _to, uint _amount) internal {
        // Claim any outstanding reward first 
        _userUpdate(_from, _amount, false);
        userInfo[_from].amountInYeti -= _amount;
        _userUpdate(_to, _amount, true);
        userInfo[_to].amountInYeti += _amount;
    }

    // // checks total pending JOE rewards for _for
    function getPendingRewards(address _for) external view override returns
        (address[] memory, uint[] memory)  {
            
        address[] memory tokens = new address[](2);
        uint[] memory amounts = new uint[](2);

    
        tokens[0] = address(aToken);
        amounts[0] = balanceOf(_for)*aavePerShare()/1e18;

        // TODO set tokens[1] to reward share from avalanche rush

        return (tokens, amounts);
    }

    // checks total pending JOE rewards for _for
    function getUserInfo(address _user) external view override returns (uint, uint, uint)  {
        UserInfo memory user = userInfo[_user];
        return (balanceOf(_user)*aavePerShare()/1e18, 0, balanceOf(_user));
    }


    // Claims msg.sender's pending rewards and sends to _to address
    function claimReward(address _to) external override {
        _sendAaveReward(msg.sender, _to);
    }

    // TODO 
    function _sendAaveReward(address _rewardOwner, address _to) internal {
        // Harvest rewards owed to this contract
        // aaveIncentivesController.claimRewards(aTokenArray, amount, to);

        // updates user reward with latest data from TODO
        _userUpdate(_rewardOwner, 0, true);

        // uint joeToSend = userInfo[_rewardOwner].unclaimedJOEReward;
        // userInfo[_rewardOwner].unclaimedJOEReward = 0;
        // _safeJoeTransfer(_to, joeToSend);
    }


    /*
     * Updates _user's reward tracking to give them unclaimed Avax reward.
     * They have the right to less or more future rewards depending
     * on whether it is or isn't a deposit
    */
    function _userUpdate(address _user, uint256 _amount, bool _isDeposit) private {
        // TODO
    }

    /*
    * Safe joe transfer function, just in case if rounding error causes pool to not have enough JOEs.
    */
    // function _safeJoeTransfer(address _to, uint256 _amount) internal {
    //     IERC20 cachedJOE = JOE;
    //     uint256 joeBal = cachedJOE.balanceOf(address(this));
    //     if (_amount > joeBal) {
    //         cachedJOE.safeTransfer(_to, joeBal);
    //     } else {
    //         cachedJOE.safeTransfer(_to, _amount);
    //     }
    // }

    // ===== Check Caller Require View Functions =====

    function _requireCallerIsPool() internal view {
        require((msg.sender == activePool || msg.sender == stabilityPool || msg.sender == collSurplusPool),
            "Caller is not active pool or stability pool"
        );
    }

    function _requireCallerIsSPorDP() internal view {
        require((msg.sender == stabilityPool || msg.sender == defaultPool),
            "Caller is not stability pool or default pool"
        );
    }

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePool,
            "Caller is not active pool"
        );
    }

    // liquidation redemption default pool
    function _requireCallerIsLRDorBO() internal view {
        require(
            (msg.sender == TML ||
             msg.sender == TMR ||
             msg.sender == defaultPool || 
             msg.sender == borrowerOperations),
            "Caller is not LRD"
        );
    }

    function _requireCallerIsSP() internal view {
        require(msg.sender == stabilityPool, "Caller is not stability pool");
    }

    function checkContract(address _account) internal view {
        require(_account != address(0), "Account cannot be zero address");

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(_account) }
        require(size != 0, "Account code size cannot be zero");
    }

}