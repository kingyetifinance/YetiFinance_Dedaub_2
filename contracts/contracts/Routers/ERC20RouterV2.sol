// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IYetiRouter.sol";
import "../Interfaces/IERC20.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../YUSDToken.sol";

// ERC20 router contract to be used for routing YUSD -> ERC20 and then wrapping.
// simple router using TJ router. 
contract ERC20RouterV2 is Ownable, IYetiRouter {
    using SafeMath for uint256;

    address internal activePoolAddress;
    address internal traderJoeRouter;
    address internal yusdTokenAddress;
    string public name;
    event RouteSet(address, address, address[]);

    // Usage: path = routes[fromToken][toToken]
    mapping (address => mapping(address => address[])) public routes;

    // Usage: type = nodeType[path[i]]
    // 1 = traderJoe
    // 2 = yusdMetapool
    // 3 = aToken
    // 4 = qToken
    // 
    mapping (address => uint256) public nodeTypes;

    mapping (address => int128) public yusdMetapoolIndex;
    constructor(
        string memory _name,
        address _activePoolAddress,
        address _traderJoeRouter, 
        address _yusdTokenAddress,
        address _USDC,
        address _USDT,
        address _DAI
    ) public {
        name = _name;
        activePoolAddress = _activePoolAddress;
        traderJoeRouter = _traderJoeRouter;
        yusdTokenAddress = _yusdTokenAddress;
        yusdMetapoolIndex[_yusdTokenAddress] = 0;
        yusdMetapoolIndex[_USDC] = 1;
        yusdMetapoolIndex[_USDT] = 2;
        yusdMetapoolIndex[_DAI] = 3;
        yusdMetapoolIndex[_yusdTokenAddress] = 4;

    }

    

    function setApprovals(address _token, address _who, uint _amount) onlyOwner external {
        IERC20(_token).approve(_who, _amount);
    }
    function setRoute(address _fromToken, address _toToken, address[] calldata _path) onlyOwner external {
        routes[_fromToken][_toToken] = _path;
        emit RouteSet(_fromToken, _toToken, _path);
    }

    function swapJoePair(address _pair, address _tokenIn) internal returns (address) {
        uint amountIn = IERC20(_tokenIn).balanceOf(address(this));
        IERC20(_tokenIn).transfer(_pair, amountIn);
        address _tokenOut;
        uint amount0Out;
        uint amount1Out;
        if (IJoePair(_pair).token0() == _tokenIn) {
            _tokenOut=IJoePair(_pair).token1();
        } else {
            _tokenOut=IJoePair(_pair).token0();
        }
        (uint reserve0, uint reserve1,) = IJoePair(_pair).getReserves();
        if (_tokenIn < _tokenOut) {
            // TokenIn=token0
            (amount0Out, amount1Out)=(uint(0),getAmountOut(amountIn, reserve0, reserve1));
        } else {
            // TokenIn=token1
            (amount0Out, amount1Out)=(getAmountOut(amountIn, reserve1, reserve0), uint(0));
        }
        IJoePair(_pair).swap(
            amount0Out, amount1Out, address(this), new bytes(0)
        );
        return _tokenOut;
    }
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    function swapYUSDMetapool(address _token, address _metapool, bool YUSDIn) internal returns (address){
        uint amountIn = IERC20(_token).balanceOf(address(this));
        
        if (YUSDIn) {
            // Swap YUSD for _token
            IMeta(_metapool).exchange_underlying(0, yusdMetapoolIndex[_token], amountIn, 0);
            return _token;
        } else {
            // Swap _token for YUSD
            IMeta(_metapool).exchange_underlying(yusdMetapoolIndex[_token],0, amountIn, 0);
            return yusdTokenAddress;
        }
    }

    // Takes the address of the token in, and gives a certain amount of token out.
    // Auto transfers to active pool.
    function route(
        address _fromUser,
        address _startingTokenAddress,
        address _endingTokenAddress,
        uint256 _amount,
        uint256 _minSwapAmount
    ) public override returns (uint256) {
        require(
            _startingTokenAddress == yusdTokenAddress,
            "Cannot route from a token other than YUSD"
        );
        address[] memory path = routes[_startingTokenAddress][_endingTokenAddress];
        require(path.length > 0, "No route found");
        IERC20(yusdTokenAddress).transferFrom(_fromUser, address(this), _amount);
        for (uint i; i < path.length; i++) {
            if (nodeTypes[path[i]]==1) {
                // Is traderjoe
                _startingTokenAddress = swapJoePair(path[i], _startingTokenAddress);
            } else if (nodeTypes[path[i]]==2) {
                // Is yusd metapool
                _startingTokenAddress = swapYUSDMetapool(_startingTokenAddress, path[i], true);
            }
        }
        uint outAmount = IERC20(_endingTokenAddress).balanceOf(address(this));
        IERC20(_endingTokenAddress).transfer(activePoolAddress, outAmount);
        require(
            outAmount >= _minSwapAmount,
            "Did not receive enough tokens to account for slippage"
        );
        return outAmount;
    }

    function unRoute(
        address _fromUser,
        address _startingTokenAddress,
        address _endingTokenAddress,
        uint256 _amount,
        uint256 _minSwapAmount
    ) external override returns (uint256) {
        require(
            _endingTokenAddress == yusdTokenAddress,
            "Cannot unroute from a token other than YUSD"
        );
        address[] memory path = new address[](2);
        path[0] = _startingTokenAddress;
        path[1] = yusdTokenAddress;
        IERC20(_startingTokenAddress).transferFrom(_fromUser, address(this), _amount);
        IERC20(_startingTokenAddress).approve(traderJoeRouter, _amount);
        uint256[] memory amounts = IRouter(traderJoeRouter).swapExactTokensForTokens(
            _amount,
            1,
            path,
            _fromUser,
            block.timestamp
        );
        require(
            amounts[1] >= _minSwapAmount,
            "Did not receive enough tokens to account for slippage"
        );

        return amounts[1];

    }
    function suicide() external onlyOwner {
        // Break contract in case of vulnerability in one of the dexes it uses
        selfdestruct(payable(address(msg.sender)));
    }
}

// Router for Uniswap V2, performs YUSD -> YETI swaps
interface IRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
interface IMeta {
    function exchange(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);
    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);
    
}

interface IJoePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        uint256 _amount0In,
        uint256 _amount1Out,
        address _to,
        bytes memory _data
    ) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}