// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.7;


// Wrapped Asset
interface IWAsset {

    function wrap(uint _amount, address _to) external;

    function unwrap(uint amount) external;

    function unwrapFor(address _for, uint amount) external;

    function updateReward(address from, address to, uint amount) external;

    function claimReward(address _to) external;

    function claimRewardFor(address _for) external;

    function getPendingRewards(address _for) external view returns (address[] memory tokens, uint[] memory amounts);

    function getUserInfo(address _user) external returns (uint, uint, uint);

    function endTreasuryReward(uint _amount) external;

    // function decompose(uint _amount) external returns (address[] memory tokens, uint[] memory amounts);
}