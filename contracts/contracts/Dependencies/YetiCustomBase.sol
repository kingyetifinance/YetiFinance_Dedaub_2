// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "./BaseMath.sol";
import "./SafeMath.sol";
import "../Interfaces/IERC20.sol";
import "../Interfaces/IWhitelist.sol";


contract YetiCustomBase is BaseMath {
    using SafeMath for uint256;

    IWhitelist whitelist;

    struct newColls {
        // tokens and amounts should be the same length
        address[] tokens;
        uint256[] amounts;
    }

    // Collateral math

    // gets the sum of _coll1 and _coll2
    function _sumColls(newColls memory _coll1, newColls memory _coll2)
        internal
        view
        returns (newColls memory finalColls)
    {
        newColls memory coll3;

        coll3.tokens = whitelist.getValidCollateral();
        coll3.amounts = new uint256[](coll3.tokens.length);

        uint256 n = 0;
        for (uint256 i = 0; i < _coll1.tokens.length; i++) {
            uint256 tokenIndex = whitelist.getIndex(_coll1.tokens[i]);
            if (_coll1.amounts[i] > 0) {
                n++;
                coll3.amounts[tokenIndex] = _coll1.amounts[i];
            }
        }

        for (uint256 i = 0; i < _coll2.tokens.length; i++) {
            uint256 tokenIndex = whitelist.getIndex(_coll2.tokens[i]);
            if (_coll2.amounts[i] > 0) {
                if (coll3.amounts[tokenIndex] == 0) {
                    n++;
                }
                coll3.amounts[tokenIndex] = coll3.amounts[tokenIndex].add(_coll2.amounts[i]);
            }
        }

        address[] memory sumTokens = new address[](n);
        uint256[] memory sumAmounts = new uint256[](n);
        uint256 j = 0;

        // should only find n amounts over 0
        for (uint256 i = 0; i < coll3.tokens.length; i++) {
            if (coll3.amounts[i] > 0) {
                sumTokens[j] = coll3.tokens[i];
                sumAmounts[j] = coll3.amounts[i];
                j++;
            }
        }
        finalColls.tokens = sumTokens;
        finalColls.amounts = sumAmounts;
    }


    // gets the sum of coll1 with tokens and amounts
    function _sumColls(
        newColls memory _coll1,
        address[] memory tokens,
        uint256[] memory amounts
    ) internal view returns (newColls memory) {
        newColls memory coll2 = newColls(tokens, amounts);
        return _sumColls(_coll1, coll2);
    }


    function _sumColls(
        address[] memory tokens1,
        uint256[] memory amounts1,
        address[] memory tokens2,
        uint256[] memory amounts2
    ) internal view returns (newColls memory) {
        newColls memory coll1 = newColls(tokens1, amounts1);
        return _sumColls(coll1, tokens2, amounts2);
    }


    // Function for summing colls when coll1 includes all the tokens in the whitelist
    // Used in active, default, stability, and surplus pools
    // assumes _coll1.tokens = all whitelisted tokens
    function _leftSumColls(
        newColls memory _coll1,
        address[] memory _tokens,
        uint256[] memory _amounts
    ) internal view returns (uint[] memory) {
        uint[] memory sumAmounts = _getArrayCopy(_coll1.amounts);

        // assumes that sumAmounts length = whitelist tokens length.
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint tokenIndex = whitelist.getIndex(_tokens[i]);
            sumAmounts[tokenIndex] = sumAmounts[tokenIndex].add(_amounts[i]);
        }

        return sumAmounts;
    }


    // Function for summing colls when one list is all tokens. Used in active, default, stability, and surplus pools
    function _leftSubColls(newColls memory _coll1, address[] memory _subTokens, uint[] memory _subAmounts)
        internal
        view
        returns (uint[] memory)
    {
        uint[] memory diffAmounts = _getArrayCopy(_coll1.amounts);

        //assumes that coll1.tokens = whitelist tokens. Keeps all of coll1's tokens, and subtracts coll2's amounts
        for (uint256 i = 0; i < _subTokens.length; i++) {
            uint256 tokenIndex = whitelist.getIndex(_subTokens[i]);
            diffAmounts[tokenIndex] = diffAmounts[tokenIndex].sub(_subAmounts[i]);
        }
        return diffAmounts;
    }
    

    // Returns _coll1 minus _tokens and _amounts
    // will error if _tokens include a token not in _coll1.tokens
    function _subColls(newColls memory _coll1, address[] memory _tokens, uint[] memory _amounts)
        internal
        view
        returns (newColls memory finalColls)
    {
        require(_tokens.length == _amounts.length, "Sub Colls invalid input");

        newColls memory coll3;
        coll3.tokens = whitelist.getValidCollateral();
        coll3.amounts = new uint256[](coll3.tokens.length);
        uint256 n = 0;

        for (uint256 i = 0; i < _coll1.tokens.length; i++) {
            if (_coll1.amounts[i] > 0) {
                uint256 tokenIndex = whitelist.getIndex(_coll1.tokens[i]);
                coll3.amounts[tokenIndex] = _coll1.amounts[i];
                n++;
            }
        }

        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 tokenIndex = whitelist.getIndex(_tokens[i]);
            require(coll3.amounts[tokenIndex] >= _amounts[i], "illegal sub");
            coll3.amounts[tokenIndex] = coll3.amounts[tokenIndex].sub(_amounts[i]);
            if (coll3.amounts[tokenIndex] == 0) {
                n--;
            }
        }

        address[] memory diffTokens = new address[](n);
        uint256[] memory diffAmounts = new uint256[](n);
        uint256 j = 0;

        for (uint256 i = 0; i < coll3.tokens.length; i++) {
            if (coll3.amounts[i] > 0) {
                diffTokens[j] = coll3.tokens[i];
                diffAmounts[j] = coll3.amounts[i];
                j++;
            }
        }
        finalColls.tokens = diffTokens;
        finalColls.amounts = diffAmounts;
    }

    function _getArrayCopy(uint[] memory _arr) internal pure returns (uint[] memory){
        uint[] memory copy = new uint[](_arr.length);
        for (uint i = 0; i < _arr.length; i++) {
            copy[i] = _arr[i];
        }
        return copy;
    }
}
