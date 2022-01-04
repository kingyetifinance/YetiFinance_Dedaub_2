//SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./BoringCrypto/BoringMath.sol";
import "./BoringCrypto/BoringERC20.sol";
import "./BoringCrypto/Domain.sol";
import "./BoringCrypto/ERC20.sol";
import "./BoringCrypto/IERC20.sol";
import "./BoringCrypto/BoringBatchable.sol";
import "./BoringCrypto/BoringOwnable.sol";


interface IYETIToken is IERC20 {
    function sendToSYETI(address _sender, uint256 _amount) external;
    function transfer(address recipient, uint256 amount) external returns (bool);
}

// Staking in sSpell inspired by Chef Nomi's SushiBar - MIT license (originally WTFPL)
// modified by BoringCrypto for DictatorDAO


// Use effective yetibalance, which updates on rebase. Rebase occurs every 8 
// Each rebase increases the effective yetibalance by a certain amount of the total value
// of the contract, which is equal to the yusd balance + the last price which the buyback 
// was executed at, multiplied by the YETI balance. Then, a portion of the value, say 1/200
// of the total value of the contract is added to the effective yetibalance. Also updated on 
// mint and withdraw, because that is actual value that is added to the contract. 

contract sYETIToken is IERC20, Domain, BoringOwnable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;

    string public constant symbol = "sYETI";
    string public constant name = "Staked YETI Tokens";
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    uint256 private constant LOCK_TIME = 69 hours;
    uint256 public effectiveYetiTokenBalance;
    uint256 public lastBuybackTime;
    uint256 public lastBuybackPrice;
    uint256 public lastRebaseTime;
    uint256 public transferRatio; // 100% = 1e18. Amount to transfer over each rebase. 
    IYETIToken public yetiToken;
    IERC20 public yusdToken;

    struct User {
        uint128 balance;
        uint128 lockedUntil;
    }

    /// @notice owner > balance mapping.
    mapping(address => User) public users;
    /// @notice owner > spender > allowance mapping.
    mapping(address => mapping(address => uint256)) public override allowance;
    /// @notice owner > nonce mapping. Used in `permit`.
    mapping(address => uint256) public nonces;

    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);
    event BuyBackExecuted(uint YUSDToSell, uint amounts0, uint amounts1);
    event Rebase(uint additionalYetiTokenBalance);

    function balanceOf(address user) public view override returns (uint256 balance) {
        return users[user].balance;
    }

    function setAddresses(IYETIToken _yeti, IERC20 _yusd) external onlyOwner {
        yetiToken = _yeti;
        yusdToken = _yusd;
    }

    function _transfer(
        address from,
        address to,
        uint256 shares
    ) internal {
        User memory fromUser = users[from];
        require(now >= fromUser.lockedUntil, "Locked");
        if (shares != 0) {
            require(fromUser.balance >= shares, "Low balance");
            if (from != to) {
                require(to != address(0), "Zero address"); // Moved down so other failed calls safe some gas
                User memory toUser = users[to];
                users[from].balance = fromUser.balance - shares.to128(); // Underflow is checked
                users[to].balance = toUser.balance + shares.to128(); // Can't overflow because totalSupply would be greater than 2^128-1;
            }
        }
        emit Transfer(from, to, shares);
    }

    function _useAllowance(address from, uint256 shares) internal {
        if (msg.sender == from) {
            return;
        }
        uint256 spenderAllowance = allowance[from][msg.sender];
        // If allowance is infinite, don't decrease it to save on gas (breaks with EIP-20).
        if (spenderAllowance != type(uint256).max) {
            require(spenderAllowance >= shares, "Low allowance");
            allowance[from][msg.sender] = spenderAllowance - shares; // Underflow is checked
        }
    }

    /// @notice Transfers `shares` tokens from `msg.sender` to `to`.
    /// @param to The address to move the tokens.
    /// @param shares of the tokens to move.
    /// @return (bool) Returns True if succeeded.
    function transfer(address to, uint256 shares) public returns (bool) {
        _transfer(msg.sender, to, shares);
        return true;
    }

    /// @notice Transfers `shares` tokens from `from` to `to`. Caller needs approval for `from`.
    /// @param from Address to draw tokens from.
    /// @param to The address to move the tokens.
    /// @param shares The token shares to move.
    /// @return (bool) Returns True if succeeded.
    function transferFrom(
        address from,
        address to,
        uint256 shares
    ) public returns (bool) {
        _useAllowance(from, shares);
        _transfer(from, to, shares);
        return true;
    }

    /// @notice Approves `amount` from sender to be spend by `spender`.
    /// @param spender Address of the party that can draw from msg.sender's account.
    /// @param amount The maximum collective amount that `spender` can draw.
    /// @return (bool) Returns True if approved.
    function approve(address spender, uint256 amount) public override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant PERMIT_SIGNATURE_HASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /// @notice Approves `value` from `owner_` to be spend by `spender`.
    /// @param owner_ Address of the owner.
    /// @param spender The address of the spender that gets approved to draw from `owner_`.
    /// @param value The maximum collective amount that `spender` can draw.
    /// @param deadline This permit must be redeemed before this deadline (UTC timestamp in seconds).
    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(owner_ != address(0), "Zero owner");
        require(now < deadline, "Expired");
        require(
            ecrecover(_getDigest(keccak256(abi.encode(PERMIT_SIGNATURE_HASH, owner_, spender, value, nonces[owner_]++, deadline))), v, r, s) ==
            owner_,
            "Invalid Sig"
        );
        allowance[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    /// math is ok, because amount, totalSupply and shares is always 0 <= amount <= 100.000.000 * 10^18
    /// theoretically you can grow the amount/share ratio, but it's not practical and useless
    function mint(uint256 amount) public returns (bool) {
        require(msg.sender != address(0), "Zero address");
        User memory user = users[msg.sender];

        uint256 shares = totalSupply == 0 ? amount : (amount * totalSupply) / effectiveYetiTokenBalance;
        user.balance += shares.to128();
        user.lockedUntil = (now + LOCK_TIME).to128();
        users[msg.sender] = user;
        totalSupply += shares;

        yetiToken.sendToSYETI(msg.sender, amount);
        effectiveYetiTokenBalance = effectiveYetiTokenBalance.add(amount);

        emit Transfer(address(0), msg.sender, shares);
        return true;
    }

    function _burn(
        address from,
        address to,
        uint256 shares
    ) internal {
        require(to != address(0), "Zero address");
        User memory user = users[from];
        require(now >= user.lockedUntil, "Locked");
        uint256 amount = (shares * effectiveYetiTokenBalance) / totalSupply;
        users[from].balance = user.balance.sub(shares.to128()); // Must check underflow
        totalSupply -= shares;

        yetiToken.transfer(to, amount);
        effectiveYetiTokenBalance = effectiveYetiTokenBalance.sub(amount);

        emit Transfer(from, address(0), shares);
    }

    function burn(address to, uint256 shares) public returns (bool) {
        _burn(msg.sender, to, shares);
        return true;
    }

    function burnFrom(
        address from,
        address to,
        uint256 shares
    ) public returns (bool) {
        _useAllowance(from, shares);
        _burn(from, to, shares);
        return true;
    }

    /** 
     * Buyback function called by owner of function. Keeps track of the 
     */
    function buyBack(address routerAddress, uint256 YUSDToSell, uint256 YETIOutMin, address[] memory path) external onlyOwner {
        require(YUSDToSell > 0, "Zero amount");
        require(lastBuybackTime + 69 hours < now, "Must have 69 hours pass before another buyBack");
        yusdToken.approve(routerAddress, YUSDToSell);
        uint256[] memory amounts = IRouter(routerAddress).swapExactTokensForTokens(YUSDToSell, YETIOutMin, path, address(this), now);
        lastBuybackTime = now;
        // amounts[0] is the amount of YUSD that was sold, and amounts[1] is the amount of YETI that was gained in return. So the price is amounts[0] / amounts[1]
        lastBuybackPrice = div(amounts[0].mul(1e18), amounts[1]);
        emit BuyBackExecuted(YUSDToSell, amounts[0], amounts[1]);
    }

    // Rebase function for adding new value to the sYETI - YETI ratio. 
    function rebase() external {
        require(now >= lastRebaseTime + 8 hours, "Must have 8 hours pass before another rebase");
        // Use last buyback price to transfer some of the actual YETI Tokens that this contract owns 
        // to the effective yeti token balance. Transfer a portion of the value over to the effective balance
        uint256 yetiTokenBalance = yetiToken.balanceOf(address(this));
        uint256 valueOfContract = _getValueOfContract(yetiTokenBalance);
        uint256 additionalYetiTokenBalance = div(valueOfContract.mul(transferRatio), (lastBuybackPrice));
        // Ensure that the amount of YETI tokens effectively added is >= the amount we have repurchased. 
        if (yetiTokenBalance - effectiveYetiTokenBalance < additionalYetiTokenBalance) {
            additionalYetiTokenBalance = yetiTokenBalance;
        }
        effectiveYetiTokenBalance = effectiveYetiTokenBalance.add(additionalYetiTokenBalance);
        lastRebaseTime = now;
        emit Rebase(additionalYetiTokenBalance);
    }

    // Sums YUSD balance + old price. 
    function _getValueOfContract(uint _yetiTokenBalance) internal view returns (uint256) {
        uint256 adjustedYetiTokenBalance = _yetiTokenBalance.sub(effectiveYetiTokenBalance);
        uint256 yusdTokenBalance = yusdToken.balanceOf(address(this));
        return div(lastBuybackPrice.mul(adjustedYetiTokenBalance), (1e18)).add(yusdTokenBalance);
    }

    // Sets new transfer ratio for rebasing
    function setTransferRatio(uint256 newTransferRatio) external onlyOwner {
        require(newTransferRatio > 0, "Zero transfer ratio");
        require(newTransferRatio <= 1e18, "Transfer ratio too high");
        transferRatio = newTransferRatio;
    }

    // Safe divide
    function div(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require(b > 0, "BoringMath: Div By 0");
        return a / b;
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