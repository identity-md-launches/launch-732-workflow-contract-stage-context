// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LaunchToken — GENESIS PROTOCOL (GENESIS)
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 tokens is minted once, to the
/// deployer, in the constructor. There is no owner, mint, burn, pause, blocklist, fee or upgrade
/// path: after construction the only state that can change is balances and allowances, and only
/// through the standard ERC-20 functions.
/// @dev Self-contained on purpose (no inherited library) so the deployed bytecode is exactly what is
/// in this file. No external calls are made, so there is no reentrancy surface.
contract LaunchToken {
    /// @notice ERC-20 token name.
    string public constant name = "GENESIS PROTOCOL";

    /// @notice ERC-20 token symbol.
    string public constant symbol = "GENESIS";

    /// @notice ERC-20 decimals.
    uint8 public constant decimals = 18;

    /// @notice Total supply in minor units: 1,000,000,000 * 10^18 = 10^27. Never changes.
    uint256 public constant totalSupply = 1_000_000_000 * 10 ** 18;

    /// @notice Balance of each account in minor units.
    mapping(address account => uint256) public balanceOf;

    /// @notice Remaining amount `spender` may move from `owner`.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    /// @notice Emitted when `value` moves from `from` to `to` (`from` is zero only for the genesis mint).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets the allowance of `spender` to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice `sender` holds `balance`, which is less than the `needed` amount.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` is allowed `allowance`, which is less than the `needed` amount.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @notice Transfers to the zero address are refused, so the supply can never be burned by mistake.
    error InvalidReceiver(address receiver);

    /// @notice Approvals to the zero address are refused.
    error InvalidSpender(address spender);

    /// @dev Mints the whole supply to the deployer. In the launch this is the project factory, which
    /// distributes it; nothing here knows or cares who the deployer is afterwards.
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    /// @notice Moves exactly `value` from the caller to `to`.
    /// @return Always true; failure reverts.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `value`.
    /// @dev `type(uint256).max` is treated as an unlimited allowance that `transferFrom` does not
    /// decrease. Changing a non-zero allowance is subject to the well-known ERC-20 approve race;
    /// callers who care should set it to zero first.
    /// @return Always true; failure reverts.
    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender(spender);
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves exactly `value` from `from` to `to`, spending the caller's allowance.
    /// @return Always true; failure reverts.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance(msg.sender, allowed, value);
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert InvalidReceiver(to);
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);
        unchecked {
            // fromBalance >= value was checked above; the sum of all balances is the constant
            // totalSupply, so the credit cannot overflow.
            balanceOf[from] = fromBalance - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
