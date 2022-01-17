// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "../Dependencies/LiquityMath.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "./Dependencies/SafeERC20.sol";

import "hardhat/console.sol";


/*
 * Contains functions for tracking user balances of staked tokens
 * and staking and un-staking LP tokens
*/
contract LPTokenWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public lpToken;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function _stakeTokens(uint256 amount) internal {
        require(amount > 0, "Cannot stake 0");

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        console.log("Stake Tokens");
        console.log("staked token balance pre");
        console.log(lpToken.balanceOf(address(this)));

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        console.log("staked token balance post");
        console.log(lpToken.balanceOf(address(this)));

        emit Staked(msg.sender, amount);
    }

    function _withdrawTokens(uint256 amount) internal {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        lpToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}


/*
 *
*/
contract Farm is Ownable, LPTokenWrapper {
    IERC20 public yetiToken;

    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);

    modifier updateReward(address account) {
        //        console.log("Update Reward for");
        //        console.log(account);

        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        //        console.log("Update Reward: Reward Per Token Stored");
        //        console.log(rewardPerTokenStored);


        if (account != address(0)) {
            rewards[account] = earned(account);
            //            console.log("Upadte reward: Reawrds for account");
            //            console.log(rewards[account]);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }


    constructor(IERC20 _LP, IERC20 _YETI) public {
        lpToken = _LP;
        yetiToken = _YETI;
    }


    // ========== EXTERNAL FUNCTIONS ==========


    // stake token to start farming
    function stake(uint256 amount) external updateReward(msg.sender) {
        _stakeTokens(amount);
    }

    // withdraw staked tokens but don't collect accumulated farming rewards
    function withdraw(uint256 amount) public updateReward(msg.sender) {
        _withdrawTokens(amount);
    }


    // withdraw all staked tokens and also collect accumulated farming reward
    function exit() external {
        withdraw(balanceOf(msg.sender));
        getReward();
    }


    // collect pending farming reward
    function getReward() public updateReward(msg.sender) {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            yetiToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }


    /* Used to update reward rate by the owner
     * Owner can only update reward to a reward such that
     * there is enough Yeti in the contract to emit
     * _reward Yeti tokens across _duration
    */
    function notifyRewardAmount(uint256 _reward, uint256 _duration) external onlyOwner updateReward(address(0)) {
        console.log(yetiToken.balanceOf(address(this)));
        console.log(_reward);

        require(
            (yetiToken.balanceOf(address(this)) >= _reward),
            "Insufficient YETI in contract");

        rewardRate = _reward.div(_duration);
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(_duration);
        emit RewardAdded(_reward);
    }


    //  ========== VIEW FUNCTIONS ==========


    function lastTimeRewardApplicable() public view returns (uint256) {
        return LiquityMath._min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
        rewardPerTokenStored.add(
            lastTimeRewardApplicable()
            .sub(lastUpdateTime)
            .mul(rewardRate)
            .mul(1e18)
            .div(totalSupply())
        );
    }

    function earned(address account) public view returns (uint256) {
        //        console.log("Earned for:");
        //        console.log(account);
        //
        //        console.log("Earned for balance of account:");
        //        console.log(balanceOf(account));
        //
        //
        //        console.log("Earned For userRewardPerTokenPaid");
        //        console.log(userRewardPerTokenPaid[account]);
        //
        //        console.log("Earned for other parts:");
        //        console.log(balanceOf(account)
        //        .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
        //        .div(1e18));
        //
        //        console.log("Earned for rewards[account]:");
        //        console.log(rewards[account]);

        return
        balanceOf(account)
        .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
        .div(1e18)
        .add(rewards[account]);
    }

}