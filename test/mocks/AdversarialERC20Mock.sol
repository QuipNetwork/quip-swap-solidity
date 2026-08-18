// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

contract AdversarialERC20Mock {
  enum BalanceBehavior {
    Exact,
    RevertQuery,
    MalformedQuery
  }

  mapping(address account => uint256 amount) private balances;
  mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
  BalanceBehavior public balanceBehavior;
  address public failingAccount;

  function mint(address to, uint256 amount) external {
    balances[to] += amount;
  }

  function setBalanceBehavior(BalanceBehavior behavior, address account) external {
    balanceBehavior = behavior;
    failingAccount = account;
  }

  function rawBalanceOf(address account) external view returns (uint256) {
    return balances[account];
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    _transfer(msg.sender, to, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    uint256 allowed = allowance[from][msg.sender];
    require(allowed >= amount, 'ALLOWANCE');
    if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    _transfer(from, to, amount);
    return true;
  }

  fallback() external {
    if (msg.sig != bytes4(keccak256('balanceOf(address)'))) revert('UNKNOWN_CALL');
    address account;
    assembly {
      account := calldataload(4)
    }
    if (account == failingAccount) {
      if (balanceBehavior == BalanceBehavior.RevertQuery) revert('BALANCE_QUERY_REVERTED');
      if (balanceBehavior == BalanceBehavior.MalformedQuery) {
        assembly {
          mstore(0, 1)
          return(31, 1)
        }
      }
    }
    uint256 value = balances[account];
    assembly {
      mstore(0, value)
      return(0, 32)
    }
  }

  function _transfer(address from, address to, uint256 amount) private {
    require(balances[from] >= amount, 'BALANCE');
    balances[from] -= amount;
    balances[to] += amount;
  }
}
