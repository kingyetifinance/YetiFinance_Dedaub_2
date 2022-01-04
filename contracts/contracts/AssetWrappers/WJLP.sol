// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.7;

import "./ERC20_8.sol";
import "./Interfaces/IWAsset.sol";

interface IRewarder {}

interface IMasterChefJoeV2 {
    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. JOEs to distribute per second.
        uint256 lastRewardTimestamp; // Last timestamp that JOEs distribution occurs.
        uint256 accJoePerShare; // Accumulated JOEs per share, times 1e12. See below.
        IRewarder rewarder;
    }

    // Deposit LP tokens to MasterChef for JOE allocation.
    function deposit(uint256 _pid, uint256 _amount) external;

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external;

    // get data on a pool given _pid
    function poolInfo(uint _pid) external view returns (PoolInfo memory pool);

    function poolLength() external returns (uint);
}

// ----------------------------------------------------------------------------
// Wrapped Joe LP token Contract (represents staked JLP token earning JOE Rewards)
// ----------------------------------------------------------------------------
contract WJLP is ERC20_8, IWAsset {

    IERC20 public JLP;
    IERC20 public JOE;

    IMasterChefJoeV2 public _MasterChefJoe;
    uint public _poolPid;

    address public activePool;
    address public TML;
    address public TMR;
    address public defaultPool;
    address public stabilityPool;
    address public YetiFinanceTreasury;

    bool addressesSet;

    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 unclaimedJOEReward;
        //
        // We do some fancy math here. Basically, any point in time, the amount of JOEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accJoePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accJoePerShare` (and `lastRewardTimestamp`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }


    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) userInfo;

    // Types of minting
    mapping(uint => address) mintType;

    /* ========== INITIALIZER ========== */

    constructor(string memory ERC20_symbol,
        string memory ERC20_name,
        uint8 ERC20_decimals,
        IERC20 _JLP,
        IERC20 _JOE,
        IMasterChefJoeV2 MasterChefJoe,
        uint256 poolPid) {

        _symbol = ERC20_symbol;
        _name = ERC20_name;
        _decimals = ERC20_decimals;
        _totalSupply = 0;

        JLP = _JLP;
        JOE = _JOE;

        _MasterChefJoe = MasterChefJoe;
        _poolPid = poolPid;
    }

    function setAddresses(
        address _activePool,
        address _TML,
        address _TMR,
        address _defaultPool,
        address _stabilityPool,
        address _YetiFinanceTreasury) external {
        require(!addressesSet);
        activePool = _activePool;
        TML = _TML;
        TMR = _TMR;
        defaultPool = _defaultPool;
        stabilityPool = _stabilityPool;
        YetiFinanceTreasury = _YetiFinanceTreasury;
        addressesSet = true;
    }

    /* ========== New Functions =============== */

    // Can be called by anyone.
    // This function pulls in _amount base tokens from _from, then stakes them in
    // to mint WAssets which it sends to _to. It also updates
    // _rewardOwner's reward tracking such that it now has the right to
    // future yields from the newly minted WAssets
    function wrap(uint _amount, address _to) external override {
        JLP.transferFrom(msg.sender, address(this), _amount);
        JLP.approve(address(_MasterChefJoe), _amount);

        // stake LP tokens in Trader Joe's.
        // In process of depositing, all this contract's
        // accumulated JOE rewards are sent into this contract
        _MasterChefJoe.deposit(_poolPid, _amount);

        // update user reward tracking
        _userUpdate(msg.sender, _amount, true);
        _mint(_to, _amount);
    }

    function unwrap(uint _amount) external override {
        _MasterChefJoe.withdraw(_poolPid, _amount);
        // msg.sender is either Active Pool or Stability Pool
        // each one has the ability to unwrap and burn WAssets they own and
        // send them to someone else
        _burn(msg.sender, _amount);
        JLP.transfer(msg.sender, _amount);
    }


    // Only callable by ActivePool or StabilityPool
    // Used to provide unwrap assets during:
    // 1. Sending 0.5% liquidation reward to liquidators
    // 2. Sending back redeemed assets
    // In both cases, the wrapped asset is first sent to the liquidator or redeemer respectively,
    // then this function is called with _for equal to the the liquidator or redeemer address
    // Prior to this being called, the user whose assets we are burning should have their rewards updated
    function unwrapFor(address _to, uint _amount) external override {
        _requireCallerIsAPorSP();
        _MasterChefJoe.withdraw(_poolPid, _amount);
        // msg.sender is either Active Pool or Stability Pool
        // each one has the ability to unwrap and burn WAssets they own and
        // send them to someone else
        _burn(msg.sender, _amount);
        JLP.transfer(_to, _amount);

    }

    // When funds are transferred into the stabilityPool on liquidation,
    // the rewards these funds are earning are allocated Yeti Finance Treasury.
    // But when an stabilityPool depositor wants to withdraw their collateral,
    // the wAsset is unwrapped and the rewards are no longer accruing to the Yeti Finance Treasury
    function endTreasuryReward(uint _amount) external override {
        _requireCallerIsSP();
        _userUpdate(YetiFinanceTreasury, _amount, false);
    }

    // Decreases _from's amount of LP tokens earning yield by _amount
    // And increases _to's amount of LP tokens earning yield by _amount
    // If _to is address(0), then doesn't increase anyone's amount
    function updateReward(address _from, address _to, uint _amount) external override {
        _requireCallerIsLRD();
        _userUpdate(_from, _amount, false);
        if (address(_to) != address(0)) {
            _userUpdate(_to, _amount, true);
        }
    }

    // checks total pending JOE rewards for _for
    function getPendingRewards(address _for) external view override returns
        (address[] memory, uint[] memory)  {
        // latest accumulated Joe Per Share:
        uint256 accJoePerShare = _MasterChefJoe.poolInfo(_poolPid).accJoePerShare;
        UserInfo storage user = userInfo[_for];

        uint unclaimed = user.unclaimedJOEReward;
        uint pending = (user.amount * accJoePerShare / 1e12) - user.rewardDebt;

        address[] memory tokens = new address[](1);
        uint[] memory amounts = new uint[](1);
        tokens[0] = address(JLP);
        amounts[0] = unclaimed + pending;

        return (tokens, amounts);
    }

    // checks total pending JOE rewards for _for
    function getUserInfo(address _user) external view override returns (uint, uint, uint)  {
        UserInfo memory user = userInfo[_user];
        return (user.amount, user.rewardDebt, user.unclaimedJOEReward);
    }


    // Claims msg.sender's pending rewards and sends to _to address
    function claimReward(address _to) external override {
        _sendJoeReward(msg.sender, _to);
    }


    // Only callable by ActivePool.
    // Claims reward on behalf of a borrower as part of the process
    // of withdrawing a wrapped asset from borrower's trove
    function claimRewardFor(address _for) external override {
        _requireCallerIsActivePool();
        _sendJoeReward(_for, _for);
    }


    function _sendJoeReward(address _rewardOwner, address _to) internal {
        // harvests all JOE that the WJLP contract is owed
        _MasterChefJoe.withdraw(_poolPid, 0);

        // updates user.unclaimedJOEReward with latest data from TJ
        _userUpdate(_rewardOwner, 0, true);

        uint joeToSend = userInfo[_rewardOwner].unclaimedJOEReward;
        userInfo[_rewardOwner].unclaimedJOEReward = 0;
        _safeJoeTransfer(_to, joeToSend);
    }

    /*
     * Updates _user's reward tracking to give them unclaimedJOEReward.
     * They have the right to less or more future rewards depending
     * on whether it is or isn't a deposit
    */
    function _userUpdate(address _user, uint256 _amount, bool _isDeposit) private returns (uint pendingJoeSent) {
        // latest accumulated Joe Per Share:
        uint256 accJoePerShare = _MasterChefJoe.poolInfo(_poolPid).accJoePerShare;
        UserInfo storage user = userInfo[_user];

        if (user.amount > 0) {
            user.unclaimedJOEReward = (user.amount * accJoePerShare / 1e12) - user.rewardDebt;
        }

        if (_isDeposit) {
            user.amount = user.amount + _amount;
        } else {
            user.amount = user.amount - _amount;
        }

        // update for JOE rewards that are already accounted for in user.unclaimedJOEReward
        user.rewardDebt = user.amount * accJoePerShare / 1e12;
    }

    /*
    * Safe joe transfer function, just in case if rounding error causes pool to not have enough JOEs.
    */
    function _safeJoeTransfer(address _to, uint256 _amount) internal {
        uint256 joeBal = JOE.balanceOf(address(this));
        if (_amount > joeBal) {
            JOE.transfer(_to, joeBal);
        } else {
            JOE.transfer(_to, _amount);
        }
    }

    // ===== Check Caller Require View Functions =====

    function _requireCallerIsAPorSP() internal view {
        require((msg.sender == activePool || msg.sender == stabilityPool),
            "Caller is not active pool or stability pool"
        );
    }

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePool,
            "Caller is not active pool"
        );
    }

    // liquidation redemption default pool
    function _requireCallerIsLRD() internal view {
        require(
            (msg.sender == TML ||
             msg.sender == TMR ||
             msg.sender == defaultPool),
            "Caller is not LRD"
        );
    }

    function _requireCallerIsSP() internal view {
        require(msg.sender == stabilityPool, "Caller is not stability pool");
    }

}