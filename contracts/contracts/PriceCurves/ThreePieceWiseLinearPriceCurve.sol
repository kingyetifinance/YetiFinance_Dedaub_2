// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "../Interfaces/IPriceCurve.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";

/** 
 * This contract is used to calculate the variable fee for an input of tokens. 
 * Uses three linear piecewise functions to calculate the fee, and the average 
 * of the system collateralization by that asset before and after the tx. 
 */
contract ThreePieceWiseLinearPriceCurve is IPriceCurve, Ownable {
    using SafeMath for uint256;

    string name;
    uint256 m1;
    uint256 b1;
    uint256 cutoff1;
    uint256 m2;
    uint256 b2;
    uint256 cutoff2;
    uint256 m3;
    uint256 b3;
    uint256 decayTime;

    uint lastFeeTime;
    uint lastFeePercent;
    uint dollarCap;
    address whitelistAddress;

    /** 
     * f1 = m1 * x + b1
     * f1 meets f2 at cutoff1, which is defined by that intersection point and slope m2
     * f2 meets f3 at cutoff2, which is defined by that intersection point and slope m3
     * Everything in terms of actual * 1e18, scaled by 1e18 because can't do percentages
     * Decimal precision = 1e18
     */

    /** 
     * Function for setting slopes and intercepts of linear functions used for fee calculations. 
     */
    function adjustParams(string memory _name, uint256 _m1, uint256 _b1, uint256 _m2, uint256 _cutoff1, uint256 _m3, uint256 _cutoff2, uint _dollarCap) public onlyOwner {
        name = _name;
        m1 = _m1;
        b1 = _b1;
        m2 = _m2;
        b2 = _m1.mul(_cutoff1).div(1e18).add(_b1).sub(_m2.mul(_cutoff1).div(1e18));
        cutoff1 = _cutoff1;
        m3 = _m3;
        b3 = _m2.mul(_cutoff2).div(1e18).add(b2).sub(_m3.mul(_cutoff2).div(1e18));
        cutoff2 = _cutoff2;
        dollarCap = _dollarCap; // Cap in VC terms of max of this asset. dollarCap = 0 means no cap. No cap.
        decayTime = 5 days;
    }

    // Set the whitelist address so that the fee can only be updated by whitelistAddress
    function setAddresses(address _whitelistAddress) public override onlyOwner {
        whitelistAddress = _whitelistAddress;
    }

    // Set the decay time in seconds
    function setDecayTime(uint _decayTime) public override onlyOwner {
        decayTime = _decayTime;
    }

    // Gets the fee cap and time currently. Used for setting new values for next price curve. 
    function getFeeCapAndTime() external override view returns (uint256 _lastFeePercent, uint256 _lastFeeTime) {
        return (lastFeePercent, lastFeeTime);
    }

    // Function for setting the old price curve's last fee cap / value to the new fee cap / value. 
    // Called only by whitelist. 
    function setFeeCapAndTime(uint256 _lastFeePercent, uint256 _lastFeeTime) external override {
        require(msg.sender == whitelistAddress);
        lastFeePercent = _lastFeePercent;
        lastFeeTime = _lastFeeTime;
    }

    /** 
     * Function for getting the fee for a particular collateral type based on percent of YUSD backed
     * by this asset. 
     * @param _collateralVCInput is how much collateral is being input by the user into the system
     * @param _totalCollateralVCBalance is how much collateral is in the system
     * @param _totalVCBalancePost is how much VC the system for all collaterals after all adjustments (additions, subtractions)
     */
    function getFee(uint256 _collateralVCInput, uint256 _totalCollateralVCBalance, uint256 _totalVCBalancePre, uint256 _totalVCBalancePost) override external view returns (uint256 fee) {
        // If dollarCap == 0, then it is not capped. Otherwise, then the total + the total input must be less than the cap.
        if (dollarCap != 0) {
            require(_totalCollateralVCBalance.add(_collateralVCInput) <= dollarCap, "Collateral input exceeds cap");
        }

        uint feePre = _getFeePoint(_totalCollateralVCBalance, _totalVCBalancePre);
        uint feePost = _getFeePoint(_totalCollateralVCBalance.add(_collateralVCInput), _totalVCBalancePost);

        uint decayedLastFee = calculateDecayedFee();
        uint feeCalculated = _max((feePre.add(feePost)).div(2), decayedLastFee);

        return feeCalculated;
    }

    // Called only by whitelist. Updates the last fee time and last fee percent
    function getFeeAndUpdate(uint256 _collateralVCInput, uint256 _totalCollateralVCBalance, uint256 _totalVCBalancePre, uint256 _totalVCBalancePost) override external returns (uint256 fee) {
        require(msg.sender == whitelistAddress, "Only whitelist can update fee");
        // If dollarCap == 0, then it is not capped. Otherwise, then the total + the total input must be less than the cap.
        if (dollarCap != 0) {
            require(_totalCollateralVCBalance.add(_collateralVCInput) <= dollarCap, "Collateral input exceeds cap");
        }
        uint feePre = _getFeePoint(_totalCollateralVCBalance, _totalVCBalancePre);
        uint feePost = _getFeePoint(_totalCollateralVCBalance.add(_collateralVCInput), _totalVCBalancePost);

        uint decayedLastFee = calculateDecayedFee();
        uint feeCalculated = _max((feePre.add(feePost)).div(2), decayedLastFee);

        lastFeeTime = block.timestamp;
        lastFeePercent = feeCalculated;
        return feeCalculated;
    }

    /** 
     * Function for getting the fee for a particular collateral type based on percent of YUSD backed
     * by this asset. 
     */
    function _getFeePoint(uint256 _collateralVCBalance, uint256 _totalVCBalance) internal view returns (uint256 fee) {
        if (_totalVCBalance == 0) {
            return 0;
        }
        // percent of all VC backed by this collateral * 1e18
        uint256 percentBacked = _collateralVCBalance.mul(1e18).div(_totalVCBalance);
        require(percentBacked <= 1e18 && percentBacked >= 0, "percent backed out of bounds");

        if (percentBacked <= cutoff1) { // use function 1
            return _min(m1.mul(percentBacked).div(1e18).add(b1), 1e18);
        } else if (percentBacked <= cutoff2) { // use function 2
            return _min(m2.mul(percentBacked).div(1e18).add(b2), 1e18);
        } else { // use function 3
            return _min(m3.mul(percentBacked).div(1e18).add(b3), 1e18);
        }
    }

    function calculateDecayedFee() public override view returns (uint256 fee) {
        uint256 decay = block.timestamp.sub(lastFeeTime);
        if (decay > 0 && decay < decayTime) {
            fee = lastFeePercent.sub(lastFeePercent.mul(decay).div(decayTime));
        } else {
            fee = lastFeePercent;
        }
        return fee;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? b : a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? b : a;
    }
}
