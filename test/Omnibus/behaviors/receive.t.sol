// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus receive Tests
/// @dev Tests for Omnibus.receive. Native is only accepted through `commit`,
/// where it is accounted against a lock's terms. A bare native transfer (empty
/// calldata) has no accounting slot and would be permanently unrecoverable, so
/// receive rejects it with NativeNotAccepted. commit's own native path is
/// covered in commit.t.sol and must stay unaffected.
contract Omnibus_receive is OmnibusTest {
  /// @notice a bare native transfer reverts with NativeNotAccepted and strands nothing
  function test_receive_revertsWhen_bareNativeSent() public {
    uint256 omnibusBefore = address(omnibus).balance;
    vm.deal(ALICE, 1 ether);

    vm.prank(ALICE);
    (bool ok, bytes memory ret) = address(omnibus).call{value: 1 ether}('');

    assertFalse(ok, 'bare native send must revert');
    assertEq(ret, abi.encodeWithSelector(IOmnibus.NativeNotAccepted.selector), 'must revert with NativeNotAccepted');
    // the value did not land: contract balance and sender balance are untouched
    assertEq(address(omnibus).balance, omnibusBefore, 'no native may stick to the contract');
    assertEq(ALICE.balance, 1 ether, 'the reverted value returns to the sender');
  }

  /// @notice even a zero-value bare call hits receive and is rejected the same way
  function test_receive_revertsWhen_zeroValueBareCall() public {
    vm.prank(ALICE);
    (bool ok, bytes memory ret) = address(omnibus).call{value: 0}('');

    assertFalse(ok, 'bare call must revert');
    assertEq(ret, abi.encodeWithSelector(IOmnibus.NativeNotAccepted.selector), 'must revert with NativeNotAccepted');
  }

  /// @notice rejection is independent of the amount sent
  function testFuzz_receive_revertsForAnyAmount(uint256 amount) public {
    amount = bound(amount, 0, 1_000_000 ether);
    uint256 omnibusBefore = address(omnibus).balance;
    vm.deal(ALICE, amount);

    vm.prank(ALICE);
    (bool ok, bytes memory ret) = address(omnibus).call{value: amount}('');

    assertFalse(ok, 'bare native send must revert for any amount');
    assertEq(ret, abi.encodeWithSelector(IOmnibus.NativeNotAccepted.selector), 'must revert with NativeNotAccepted');
    assertEq(address(omnibus).balance, omnibusBefore, 'no native may stick to the contract');
  }
}
