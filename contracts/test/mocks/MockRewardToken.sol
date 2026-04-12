// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title  MockRewardToken
/// @notice ERC-20 stub used to test the BlieverUmaAdapter's best-effort reward refund path.
///
///         Two failure modes:
///           • transferShouldRevert  — transfer() hard-reverts (simulates USDC revert)
///           • transferReturnsFalse  — transfer() returns false without reverting
///             (simulates non-reverting failure tokens — rare but valid ERC-20 behavior)
///
///         Both trigger the adapter's `RefundFailed` event path.
contract MockRewardToken {
    string  public name     = "Mock Reward Token";
    string  public symbol   = "MRT";
    uint8   public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public transferShouldRevert;
    bool public transferReturnsFalse;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ── Test controls ──────────────────────────────────────────────────────

    function setTransferShouldRevert(bool v) external { transferShouldRevert = v; }
    function setTransferReturnsFalse(bool v) external { transferReturnsFalse = v; }

    // ── Standard ERC-20 ───────────────────────────────────────────────────

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function forceApprove(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferShouldRevert) revert("MockToken: transfer reverted");
        if (transferReturnsFalse) return false;
        require(balanceOf[msg.sender] >= amount, "MockToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from]             >= amount, "MockToken: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockToken: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
