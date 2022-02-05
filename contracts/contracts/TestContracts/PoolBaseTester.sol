// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "../Dependencies/PoolBase.sol";

contract PoolBaseTester is PoolBase {

    event Sum(address[] tokens, uint[] amounts);
    
    // call _leftSumColls
    function leftSumColls(address[] memory _tokens1, uint[] memory _amounts1,
        address[] memory _tokens2, uint[] memory _amounts2) external {
        uint[] memory sumAmounts = _leftSumColls(newColls(_tokens1, _amounts1), _tokens2, _amounts2);
        address[] memory tokens;
        emit Sum(tokens, sumAmounts);
    }

    // call _leftSubColls
    function leftSubColls(address[] memory _tokens1, uint[] memory _amounts1,
        address[] memory _tokens2, uint[] memory _amounts2) external {
        uint[] memory diffAmounts = _leftSubColls(newColls(_tokens1, _amounts1), _tokens2, _amounts2);
        address[] memory tokens;
        emit Sum(tokens, diffAmounts);
    }
}
