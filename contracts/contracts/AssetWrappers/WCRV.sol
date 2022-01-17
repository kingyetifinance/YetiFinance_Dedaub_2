// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.7;

import "./ERC20_8.sol";
import "./Interfaces/IWAsset.sol";
interface IGauge {
    function deposit(uint256 _value) external;
    function withdraw(uint256 _value) external;
    function claim_rewards()external;
    function balanceOf(address _user) external view returns (uint256);
}

interface ICurvePool{
    function add_liquidity(uint256[3] calldata _amounts, uint256 _min_mint_amount, bool _use_underlying)external returns (uint256);
    function coins(uint256 _index)external returns (address);
    function underlying_coins(uint256 _index)external returns (address);
}


// ----------------------------------------------------------------------------
// Wrapped Joe LP token Contract (represents staked JLP token earning JOE Rewards)
// ----------------------------------------------------------------------------
contract WCRV is IWAsset, ERC20_8 {

    ICurvePool public POOL;
    IERC20 public LP;
    rewardToken[] public rewardTokens;
    IGauge public gauge;
    uint256 public crvDepIndex;
    uint256[] public crvDeposits;
    address public traderJoe;
    address public swapOutput;
    uint public latestCompoundTime;
    // uint public _poolPid;

    address public activePool;
    address public TML;
    address public TMR;
    address public defaultPool;
    address public stabilityPool;
    address public YetiFinanceTreasury;
    uint public SHAREOFFSET=1e12;
    uint public numberOfCoinsInCurvePool;
    bool addressesSet;
    uint MAX_INT=2**256-1;

    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 interest;
        uint256 snapshotAAVE; // Current AAVE balance: numerator
        uint256 outstandingShares; // Current outstanding shares of QItoken wrapped
        // To calculate a user's reward share we need to know how much of the rewards has been provided when they wrap their aToken.
        // We can calculate the initial rewardAmount per share as rewardAmount / outstandingShares.
        // Upon unwrapping we can calculate the rewards they are entitled to as amount * ((newRewardAmout / newOutstandingShares)-(initialRewardAmount/initialOutstandingShares)).
    }

    struct rewardToken {
        address token;
        address[] swapPath;
        uint256 minAmt;
    }


    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) userInfo;

    // Types of minting
    mapping(uint => address) mintType;


    //Debug for compound calls
    event Log(string message);
    event LogBytes(bytes data);

    /* ========== INITIALIZER ========== */

    constructor(string memory ERC20_symbol,
        string memory ERC20_name,
        uint8 ERC20_decimals,
        address _swapOutput,
        address _POOL,
        IERC20 _LP,
        rewardToken[] memory _rewardTokens,
        address _gauge,
        address _traderJoe,
        uint256 _numberOfCoinsInCurvePool,
        uint256 _indexOfCoinToDepositInCurvePool
        // uint256 poolPid
        ) {

        _symbol = ERC20_symbol;
        _name = ERC20_name;
        _decimals = ERC20_decimals;
        _totalSupply = 0;

        swapOutput=_swapOutput;
        IERC20(swapOutput).approve(_POOL,MAX_INT);
        POOL=ICurvePool(_POOL);
        LP=_LP;
        LP.approve(_gauge, MAX_INT);
        gauge = IGauge(_gauge);
        traderJoe=_traderJoe;
        
        numberOfCoinsInCurvePool=_numberOfCoinsInCurvePool;
        require(crvDepIndex<_numberOfCoinsInCurvePool, "Index of coin to deposit in curve pool is out of bounds");
        crvDepIndex=_indexOfCoinToDepositInCurvePool;
        require(swapOutput==POOL.underlying_coins(crvDepIndex), "Swap output address does not match the address of the coin to deposit in the curve pool");
        // for (uint i=0; i<_numberOfCoinsInCurvePool; i++) {
        //     crvDeposits.push(0);
        // }
        for (uint i = 0; i < _rewardTokens.length; i++) {
            require(_rewardTokens[i].swapPath[_rewardTokens[i].swapPath.length-1] == swapOutput, "Swap output must be last element in swap path");
            rewardTokens.push(_rewardTokens[i]);
            IERC20(rewardTokens[i].token).approve(traderJoe, MAX_INT);
        }
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
    function wrap(uint _amount, address _from, address _to, address _rewardOwner) external override{
        accumulateRewards();
        _mint(_to, 1e18*_amount/LPPerShare());
        LP.transferFrom(msg.sender, address(this), _amount);
        gauge.deposit(_amount);
    }

    function LPPerShare() public view returns (uint) {
        if (_totalSupply==0) {
            return 1e18;
        }
        return 1e18*gauge.balanceOf(address(this))/_totalSupply;
    }
    
    function updateRewardToken(uint256 index, address _token, address[] memory _path, uint256 _minAmt) public {
        require(msg.sender==YetiFinanceTreasury, "Only YetiFinanceTreasury can update reward tokens");
        _setRewardToken(index, _token, _path, _minAmt);
    }
    function _setRewardToken(uint256 index, address _token, address[] memory _path, uint256 _minAmt) internal {
        require(_path.length==0 || _path[_path.length-1] == swapOutput, "Swap output must be last element in swap path or path must be empty");
        if (index>=rewardTokens.length) {
            //Add new token
            IERC20(_token).approve(traderJoe, MAX_INT);
            rewardTokens.push(rewardToken(_token, _path, _minAmt));
        } else {
            //Update existing token
            rewardTokens[index].token = _token;
            rewardTokens[index].swapPath = _path;
            rewardTokens[index].minAmt = _minAmt;
        }
    }
    function getRewardToken(uint256 index) public view returns (rewardToken memory) {
        return rewardTokens[index];
    }

    function accumulateRewards() public {
        if (latestCompoundTime+3600<block.timestamp) {
            compound();
        }
    }

    function compound() public {
        latestCompoundTime = block.timestamp;
        gauge.claim_rewards();
        uint nLen = rewardTokens.length;
        for (uint i=0;i<nLen;i++){
            rewardToken memory info = rewardTokens[i];
            if(info.swapPath.length==0 || IERC20(info.token).balanceOf(address(this))<info.minAmt){
                continue;
            }
            swapTraderJoe(info);
            
        }
        uint256 balance = IERC20(swapOutput).balanceOf(address(this));
        if (balance>0){
            // uint256[] memory crvDeposits = new uint256[](numberOfCoinsInCurvePool);
            // 
            uint256[3] memory crvDeposits;
            crvDeposits[crvDepIndex] = balance; 
            POOL.add_liquidity(crvDeposits,0,true);
            balance = LP.balanceOf(address(this));
            gauge.deposit(balance);
        }
    }
    function swapTraderJoe(rewardToken memory _rewardToken)internal{
        if(_rewardToken.token == swapOutput){
            return;
        }
        
        if (_rewardToken.token != address(0)){
            uint256 balance = IERC20(_rewardToken.token).balanceOf(address(this));
            IJoeRouter01(traderJoe).swapExactTokensForTokens(balance,0,_rewardToken.swapPath,address(this),block.timestamp+30);
        }else{
            uint256 balance = address(this).balance;
            IJoeRouter01(traderJoe).swapExactAVAXForTokens{value : balance}(0,_rewardToken.swapPath,address(this),block.timestamp+30);
        }
    }

    function unwrap(uint _amount) external override {
        accumulateRewards();        
        gauge.withdraw(_amount*LPPerShare()/1e18);
        _burn(msg.sender, _amount);
        LP.transfer(msg.sender, LP.balanceOf(address(this)));
    }

   


    // Only callable by ActivePool or StabilityPool
    // Used to provide unwrap assets during:
    // 1. Sending 0.5% liquidation reward to liquidators
    // 2. Sending back redeemed assets
    // In both cases, the wrapped asset is first sent to the liquidator or redeemer respectively,
    // then this function is called with _for equal to the the liquidator or redeemer address
    // Prior to this being called, the user whose assets we are burning should have their rewards updated
    function unwrapFor(address _from, address _to, uint _amount) external override {
        _requireCallerIsAPorSP();
        // accumulateRewards(msg.sender);
        // _MasterChefJoe.withdraw(_poolPid, _amount);

        // msg.sender is either Active Pool or Stability Pool
        // each one has the ability to unwrap and burn WAssets they own and
        // send them to someone else
        // userInfo[_to].amount=userInfo[_to].amount-_amount;
        gauge.withdraw(_amount*LPPerShare()/1e18);
        _burn(msg.sender, _amount);
        LP.transfer(_to, LP.balanceOf(address(this)));
    }

    // When funds are transferred into the stabilityPool on liquidation,
    // the rewards these funds are earning are allocated Yeti Finance Treasury.
    // But when an stabilityPool depositor wants to withdraw their collateral,
    // the wAsset is unwrapped and the rewards are no longer accruing to the Yeti Finance Treasury
    function endTreasuryReward(address _to, uint _amount) external override {
        _requireCallerIsSP();
    }

    // Decreases _from's amount of LP tokens earning yield by _amount
    // And increases _to's amount of LP tokens earning yield by _amount
    // If _to is address(0), then doesn't increase anyone's amount
    function updateReward(address _from, address _to, uint _amount) external override {
        _requireCallerIsLRD();

    }

    // // checks total pending JOE rewards for _for
    function getPendingRewards(address _for) external view override returns
        (address[] memory, uint[] memory)  {
            
        address[] memory tokens = new address[](1);
        uint[] memory amounts = new uint[](1);

    
        tokens[0] = address(LP);
        amounts[0] = balanceOf(_for)*LPPerShare()/1e18;

        return (tokens, amounts);
    }

    // checks total pending JOE rewards for _for
    function getUserInfo(address _user) external view override returns (uint, uint, uint)  {
        UserInfo memory user = userInfo[_user];
        return (balanceOf(_user)*LPPerShare()/1e18, 0, balanceOf(_user));
    }

    function claimRewardTreasury() external {
        require(msg.sender==YetiFinanceTreasury);

    }


    // Claims msg.sender's pending rewards and sends to _to address
    function claimReward(address _to) external override {
        // _sendReward(msg.sender, _to);
    }


    // Only callable by ActivePool.
    // Claims reward on behalf of a borrower as part of the process
    // of withdrawing a wrapped asset from borrower's trove
    function claimRewardFor(address _for) external {
        _requireCallerIsActivePool();

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




interface IJoeRouter01 {
    function factory() external pure returns (address);

    function WAVAX() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityAVAX(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountAVAXMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountAVAX,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityAVAX(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountAVAXMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountAVAX);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityAVAXWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountAVAXMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountAVAX);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactAVAXForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactAVAX(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForAVAX(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapAVAXForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}