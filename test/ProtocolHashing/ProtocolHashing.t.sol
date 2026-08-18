// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {
  ActionTag,
  Asset,
  AssetType,
  AuthorizationMode,
  CommitPayload,
  DelegationPolicy,
  ExpectedSourceState,
  ProtocolTerms,
  SideTag,
  SideTerms,
  WrapperMode
} from '../../src/protocol/ProtocolTypes.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract ProtocolHashingTest is Test {
  string internal constant TERMS_DOMAIN = 'InterlockTerms-v1.1';
  string internal constant GATE_CONTEXT_DOMAIN = 'InterlockBobCommitGateContext-v1.1';
  string internal constant BOB_COMMIT_GATE_DOMAIN = 'InterlockBobCommitGate-v1.1';
  string internal constant SETTLEMENT_LOCK_DOMAIN = 'InterlockSettlementLock-v1.1';
  string internal constant ASSETS_DOMAIN = 'InterlockAssets-v1.1';
  string internal constant COMMIT_DOMAIN = 'InterlockCommit-v1.1';

  address internal constant ALICE = address(0x1111);
  address internal constant BOB = address(0x2222);
  address internal constant DELEGATE = address(0x3333);
  address internal constant VERIFIER = address(0x4444);
  address internal constant SWAP = address(0x5555);
  address internal constant TOKEN = address(0x6666);
  bytes32 internal constant BOB_SECRET = keccak256('bob-secret');
  bytes32 internal constant SECRET = keccak256('settlement-secret');
  bytes32 internal constant ACTION_NONCE = keccak256('action-nonce');

  function test_allHashFamiliesMatchCanonicalEncodings() public pure {
    ProtocolTerms memory terms = _crossChainTerms();
    ProtocolTerms memory projected = ProtocolHashing.gateTerms(terms);
    bytes32 trade = ProtocolHashing.tradeId(terms);
    bytes32 context = ProtocolHashing.gateContextId(terms);
    bytes32 lock = ProtocolHashing.settlementLock(trade, SECRET);

    assertEq(trade, keccak256(abi.encode(TERMS_DOMAIN, terms)));
    assertEq(context, keccak256(abi.encode(GATE_CONTEXT_DOMAIN, projected)));
    assertEq(
      ProtocolHashing.commitLock(context, BOB_SECRET),
      keccak256(abi.encode(BOB_COMMIT_GATE_DOMAIN, context, BOB_SECRET))
    );
    assertEq(lock, keccak256(abi.encode(SETTLEMENT_LOCK_DOMAIN, trade, SECRET)));
    assertEq(
      ProtocolHashing.assetHash(terms.counterpartySide),
      keccak256(abi.encode(ASSETS_DOMAIN, terms.counterpartySide.chainId, terms.counterpartySide.assets))
    );

    CommitPayload memory payload = CommitPayload({
      chainId: terms.counterpartySide.chainId,
      mode: WrapperMode.CrossChain,
      authorizationVerifier: VERIFIER,
      swapAddress: SWAP,
      tradeId: trade,
      lock: lock,
      side: SideTag.Counterparty,
      action: ActionTag.Commit,
      expectedSourceState: ExpectedSourceState.Unused,
      assetHash: ProtocolHashing.assetHash(terms.counterpartySide),
      principal: terms.counterpartySide.principal,
      principalKeyVersion: terms.counterpartySide.principalKeyVersion,
      delegationPolicy: terms.counterpartySide.delegationPolicy,
      delegate: terms.counterpartySide.delegate,
      delegateKeyVersion: terms.counterpartySide.delegateKeyVersion,
      actionNonce: ACTION_NONCE,
      commitmentDeadline: terms.counterpartySide.commitmentDeadline,
      expiry: 1000
    });
    assertEq(
      ProtocolHashing.commitPayloadHash(
        terms, false, VERIFIER, SWAP, lock, ExpectedSourceState.Unused, ACTION_NONCE, 1000
      ),
      keccak256(abi.encode(COMMIT_DOMAIN, payload))
    );
    assertEq(
      ProtocolHashing.encodeAuthorizationNonceKey(2, VERIFIER, BOB, 7, ACTION_NONCE),
      abi.encode(uint256(2), VERIFIER, BOB, uint256(7), ACTION_NONCE)
    );
    assertEq(
      ProtocolHashing.encodeRegistryNonceKey(2, SWAP, BOB, 1, 9, ACTION_NONCE),
      abi.encode(uint256(2), SWAP, BOB, uint8(1), uint256(9), ACTION_NONCE)
    );
  }

  function test_tradeAndGateContextBindEveryTermsFieldWithOneDocumentedProjection() public pure {
    ProtocolTerms memory terms = _crossChainTerms();
    bytes32 trade = ProtocolHashing.tradeId(terms);
    bytes32 context = ProtocolHashing.gateContextId(terms);

    for (uint256 sideIndex; sideIndex < 2; ++sideIndex) {
      bool party = sideIndex == 0;
      for (uint256 field; field < 19; ++field) {
        ProtocolTerms memory changed = _mutate(terms, party, field);
        assertNotEq(ProtocolHashing.tradeId(changed), trade);
        if (!party && field == 9) {
          assertEq(ProtocolHashing.gateContextId(changed), context);
        } else {
          assertNotEq(ProtocolHashing.gateContextId(changed), context);
        }
      }
    }

    ProtocolTerms memory projected = ProtocolHashing.gateTerms(terms);
    assertEq(projected.counterpartySide.commitLock, bytes32(0));
    assertEq(projected.partySide.commitLock, terms.partySide.commitLock);
    assertEq(ProtocolHashing.tradeId(terms), trade);
    assertNotEq(ProtocolHashing.tradeId(projected), trade);
  }

  function test_assetHashBindsOnlyChainAndCanonicalAssetListForBothSides() public pure {
    ProtocolTerms memory terms = _crossChainTerms();
    for (uint256 sideIndex; sideIndex < 2; ++sideIndex) {
      bool party = sideIndex == 0;
      SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
      bytes32 original = ProtocolHashing.assetHash(side);
      for (uint256 field = 14; field < 19; ++field) {
        ProtocolTerms memory changed = _mutate(terms, party, field);
        assertNotEq(ProtocolHashing.assetHash(party ? changed.partySide : changed.counterpartySide), original);
      }
      ProtocolTerms memory chainChanged = _mutate(terms, party, 0);
      assertNotEq(ProtocolHashing.assetHash(party ? chainChanged.partySide : chainChanged.counterpartySide), original);
      ProtocolTerms memory principalChanged = _mutate(terms, party, 1);
      assertEq(
        ProtocolHashing.assetHash(party ? principalChanged.partySide : principalChanged.counterpartySide), original
      );
    }
  }

  function test_commitPayloadBindsBothSidesModesAndEveryInput() public pure {
    ProtocolTerms memory cross = _crossChainTerms();
    ProtocolTerms memory same = _sameChainTerms();
    for (uint256 modeIndex; modeIndex < 2; ++modeIndex) {
      ProtocolTerms memory terms = modeIndex == 0 ? cross : same;
      WrapperMode expectedMode = modeIndex == 0 ? WrapperMode.CrossChain : WrapperMode.SameChain;
      assertEq(uint8(ProtocolHashing.mode(terms)), uint8(expectedMode));
      for (uint256 sideIndex; sideIndex < 2; ++sideIndex) {
        bool party = sideIndex == 0;
        ExpectedSourceState expected = ProtocolHashing.expectedSourceState(party, expectedMode);
        ExpectedSourceState other =
          expected == ExpectedSourceState.Unused ? ExpectedSourceState.PartyCommitted : ExpectedSourceState.Unused;
        bytes32 trade = ProtocolHashing.tradeId(terms);
        bytes32 lock = ProtocolHashing.settlementLock(trade, SECRET);
        bytes32 original =
          ProtocolHashing.commitPayloadHash(terms, party, VERIFIER, SWAP, lock, expected, ACTION_NONCE, 1000);

        assertNotEq(
          ProtocolHashing.commitPayloadHash(terms, party, address(0x7777), SWAP, lock, expected, ACTION_NONCE, 1000),
          original
        );
        assertNotEq(
          ProtocolHashing.commitPayloadHash(
            terms, party, VERIFIER, address(0x8888), lock, expected, ACTION_NONCE, 1000
          ),
          original
        );
        assertNotEq(
          ProtocolHashing.commitPayloadHash(
            terms, party, VERIFIER, SWAP, keccak256('other-lock'), expected, ACTION_NONCE, 1000
          ),
          original
        );
        assertNotEq(
          ProtocolHashing.commitPayloadHash(terms, party, VERIFIER, SWAP, lock, other, ACTION_NONCE, 1000), original
        );
        assertNotEq(
          ProtocolHashing.commitPayloadHash(
            terms, party, VERIFIER, SWAP, lock, expected, keccak256('other-nonce'), 1000
          ),
          original
        );
        assertNotEq(
          ProtocolHashing.commitPayloadHash(terms, party, VERIFIER, SWAP, lock, expected, ACTION_NONCE, 1001), original
        );
        assertNotEq(
          ProtocolHashing.commitPayloadHash(terms, !party, VERIFIER, SWAP, lock, expected, ACTION_NONCE, 1000), original
        );

        for (uint256 changedSide; changedSide < 2; ++changedSide) {
          for (uint256 field; field < 19; ++field) {
            ProtocolTerms memory changed = _mutate(terms, changedSide == 0, field);
            assertNotEq(
              ProtocolHashing.commitPayloadHash(changed, party, VERIFIER, SWAP, lock, expected, ACTION_NONCE, 1000),
              original
            );
          }
        }
      }
    }

    assertEq(
      uint8(ProtocolHashing.expectedSourceState(true, WrapperMode.CrossChain)), uint8(ExpectedSourceState.Unused)
    );
    assertEq(
      uint8(ProtocolHashing.expectedSourceState(false, WrapperMode.CrossChain)), uint8(ExpectedSourceState.Unused)
    );
    assertEq(uint8(ProtocolHashing.expectedSourceState(true, WrapperMode.SameChain)), uint8(ExpectedSourceState.Unused));
    assertEq(
      uint8(ProtocolHashing.expectedSourceState(false, WrapperMode.SameChain)),
      uint8(ExpectedSourceState.PartyCommitted)
    );
  }

  function test_lockAndNonceFamiliesBindEveryInput() public pure {
    bytes32 context = keccak256('context');
    bytes32 trade = keccak256('trade');
    assertNotEq(
      ProtocolHashing.commitLock(context, BOB_SECRET),
      ProtocolHashing.commitLock(keccak256('other-context'), BOB_SECRET)
    );
    assertNotEq(
      ProtocolHashing.commitLock(context, BOB_SECRET),
      ProtocolHashing.commitLock(context, keccak256('other-bob-secret'))
    );
    assertNotEq(
      ProtocolHashing.settlementLock(trade, SECRET), ProtocolHashing.settlementLock(keccak256('other-trade'), SECRET)
    );
    assertNotEq(
      ProtocolHashing.settlementLock(trade, SECRET), ProtocolHashing.settlementLock(trade, keccak256('other-secret'))
    );

    bytes32 authorization = keccak256(ProtocolHashing.encodeAuthorizationNonceKey(1, VERIFIER, ALICE, 7, ACTION_NONCE));
    assertNotEq(
      authorization, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(2, VERIFIER, ALICE, 7, ACTION_NONCE))
    );
    assertNotEq(authorization, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(1, SWAP, ALICE, 7, ACTION_NONCE)));
    assertNotEq(
      authorization, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(1, VERIFIER, BOB, 7, ACTION_NONCE))
    );
    assertNotEq(
      authorization, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(1, VERIFIER, ALICE, 8, ACTION_NONCE))
    );
    assertNotEq(
      authorization, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(1, VERIFIER, ALICE, 7, keccak256('other')))
    );

    bytes32 registry = keccak256(ProtocolHashing.encodeRegistryNonceKey(1, SWAP, ALICE, 0, 7, ACTION_NONCE));
    assertNotEq(registry, keccak256(ProtocolHashing.encodeRegistryNonceKey(2, SWAP, ALICE, 0, 7, ACTION_NONCE)));
    assertNotEq(registry, keccak256(ProtocolHashing.encodeRegistryNonceKey(1, VERIFIER, ALICE, 0, 7, ACTION_NONCE)));
    assertNotEq(registry, keccak256(ProtocolHashing.encodeRegistryNonceKey(1, SWAP, BOB, 0, 7, ACTION_NONCE)));
    assertNotEq(registry, keccak256(ProtocolHashing.encodeRegistryNonceKey(1, SWAP, ALICE, 1, 7, ACTION_NONCE)));
    assertNotEq(registry, keccak256(ProtocolHashing.encodeRegistryNonceKey(1, SWAP, ALICE, 0, 8, ACTION_NONCE)));
    assertNotEq(registry, keccak256(ProtocolHashing.encodeRegistryNonceKey(1, SWAP, ALICE, 0, 7, keccak256('other'))));
  }

  function test_validateTermsRejectsAuthorizationDelegationAndIdentityShapes() public {
    ProtocolTerms memory terms = _crossChainTerms();
    ProtocolTerms memory invalid = _copy(terms);
    invalid.partySide.principal = address(0);
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.authorizationMode = AuthorizationMode.QuipWallet;
    invalid.partySide.principalKeyVersion = 1;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.authorizationMode = AuthorizationMode.RegisteredDirect;
    invalid.counterpartySide.principalKeyVersion = 0;
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.delegate = address(0);
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.delegateKeyVersion = 0;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.delegate = DELEGATE;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.delegateKeyVersion = 1;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    invalid.partySide.delegate = DELEGATE;
    invalid.partySide.delegateKeyVersion = 1;
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.recipient = address(0);
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.reclaimRecipient = address(0);
    _assertInvalid(invalid);
  }

  function test_validateTermsRejectsChainDeadlineAndProgressionShapes() public {
    ProtocolTerms memory terms = _crossChainTerms();
    ProtocolTerms memory invalid = _copy(terms);
    invalid.partySide.chainId = 0;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.chainId = 0;
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.claimDeadline = invalid.partySide.commitmentDeadline;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.reclaimRelease = invalid.counterpartySide.claimDeadline;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.commitmentDeadline = invalid.counterpartySide.commitmentDeadline;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.commitmentDeadline = invalid.partySide.claimDeadline;
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.commitLock = keccak256('party-lock');
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.commitLock = bytes32(0);
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.claimDeadline = invalid.counterpartySide.reclaimRelease + 1;
    invalid.partySide.reclaimRelease = invalid.partySide.claimDeadline + 1;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.counterpartySide.claimDeadline = invalid.partySide.reclaimRelease + 1;
    invalid.counterpartySide.reclaimRelease = invalid.counterpartySide.claimDeadline + 1;
    _assertInvalid(invalid);

    ProtocolTerms memory same = _sameChainTerms();
    ProtocolHashing.validateTerms(same);
    invalid = _copy(same);
    invalid.counterpartySide.commitLock = keccak256('same-chain-lock');
    _assertInvalid(invalid);
    invalid = _copy(same);
    invalid.partySide.reclaimRelease = invalid.partySide.claimDeadline;
    _assertInvalid(invalid);
    invalid = _copy(same);
    invalid.counterpartySide.reclaimRelease = invalid.partySide.claimDeadline;
    _assertInvalid(invalid);
  }

  function test_validateTermsRejectsEveryAssetShapeAndOrderingFailure() public {
    ProtocolTerms memory terms = _crossChainTerms();
    ProtocolTerms memory invalid = _copy(terms);
    invalid.partySide.assets = new Asset[](0);
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.assets[0].amount = 0;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.assets[0].target = TOKEN;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.assets[0].id = 1;
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.assets[1].target = address(0);
    _assertInvalid(invalid);
    invalid = _copy(terms);
    invalid.partySide.assets[1].id = 1;
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.assets = new Asset[](1);
    invalid.partySide.assets[0] = Asset({assetType: AssetType.ERC721, target: address(0), id: 1, amount: 1});
    _assertInvalid(invalid);
    invalid.partySide.assets[0] = Asset({assetType: AssetType.ERC721, target: TOKEN, id: 1, amount: 2});
    _assertInvalid(invalid);
    invalid.partySide.assets[0] = Asset({assetType: AssetType.ERC1155, target: address(0), id: 1, amount: 1});
    _assertInvalid(invalid);

    invalid = _copy(terms);
    invalid.partySide.assets[1] = invalid.partySide.assets[0];
    _assertInvalid(invalid);
    invalid = _copy(terms);
    Asset memory first = invalid.partySide.assets[0];
    invalid.partySide.assets[0] = invalid.partySide.assets[1];
    invalid.partySide.assets[1] = first;
    _assertInvalid(invalid);
  }

  function _assertInvalid(ProtocolTerms memory terms) internal {
    vm.expectRevert(ProtocolHashing.InvalidTerms.selector);
    this.validate(terms);
  }

  function validate(ProtocolTerms calldata terms) external pure {
    ProtocolHashing.validateTerms(terms);
  }

  function _crossChainTerms() internal pure returns (ProtocolTerms memory terms) {
    terms.partySide = _side(1, ALICE, BOB, 100, 300, 900, true);
    terms.counterpartySide = _side(2, BOB, ALICE, 200, 400, 800, false);
    terms.counterpartySide.commitLock = ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), BOB_SECRET);
  }

  function _sameChainTerms() internal pure returns (ProtocolTerms memory terms) {
    terms.partySide = _side(1, ALICE, BOB, 100, 300, 900, true);
    terms.counterpartySide = _side(1, BOB, ALICE, 200, 400, 800, false);
    terms.counterpartySide.commitLock = bytes32(0);
  }

  function _side(
    uint256 chainId,
    address principal,
    address recipient,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    bool party
  ) internal pure returns (SideTerms memory side) {
    Asset[] memory assets = new Asset[](2);
    assets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: party ? 10 : 20});
    assets[1] = Asset({assetType: AssetType.ERC20, target: TOKEN, id: 0, amount: party ? 30 : 40});
    side = SideTerms({
      chainId: chainId,
      assets: assets,
      principal: principal,
      authorizationMode: party ? AuthorizationMode.QuipWallet : AuthorizationMode.RegisteredDirect,
      principalKeyVersion: party ? 0 : 7,
      reclaimRecipient: principal,
      recipient: recipient,
      commitmentDeadline: commitmentDeadline,
      claimDeadline: claimDeadline,
      reclaimRelease: reclaimRelease,
      commitLock: bytes32(0),
      delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.SpecificDelegate,
      delegate: party ? address(0) : DELEGATE,
      delegateKeyVersion: party ? 0 : 3,
      sideNonce: party ? keccak256('party-nonce') : keccak256('counterparty-nonce')
    });
  }

  function _mutate(
    ProtocolTerms memory original,
    bool party,
    uint256 field
  ) internal pure returns (ProtocolTerms memory changed) {
    changed = _copy(original);
    SideTerms memory side = party ? changed.partySide : changed.counterpartySide;
    if (field == 0) {
      side.chainId += 100;
    } else if (field == 1) {
      side.principal = address(uint160(side.principal) + 100);
    } else if (field == 2) {
      side.authorizationMode = side.authorizationMode == AuthorizationMode.QuipWallet
        ? AuthorizationMode.RegisteredDirect
        : AuthorizationMode.QuipWallet;
    } else if (field == 3) {
      side.principalKeyVersion += 1;
    } else if (field == 4) {
      side.reclaimRecipient = address(uint160(side.reclaimRecipient) + 100);
    } else if (field == 5) {
      side.recipient = address(uint160(side.recipient) + 100);
    } else if (field == 6) {
      side.commitmentDeadline += 1;
    } else if (field == 7) {
      side.claimDeadline += 1;
    } else if (field == 8) {
      side.reclaimRelease += 1;
    } else if (field == 9) {
      side.commitLock = keccak256(abi.encode(side.commitLock, 'changed'));
    } else if (field == 10) {
      side.delegationPolicy = side.delegationPolicy == DelegationPolicy.NotAllowed
        ? DelegationPolicy.Permissionless
        : DelegationPolicy.NotAllowed;
    } else if (field == 11) {
      side.delegate = address(uint160(side.delegate) + 100);
    } else if (field == 12) {
      side.delegateKeyVersion += 1;
    } else if (field == 13) {
      side.sideNonce = keccak256(abi.encode(side.sideNonce, 'changed'));
    } else if (field == 14) {
      side.assets[0].assetType = AssetType.ERC1155;
    } else if (field == 15) {
      side.assets[0].target = TOKEN;
    } else if (field == 16) {
      side.assets[0].id += 1;
    } else if (field == 17) {
      side.assets[0].amount += 1;
    } else {
      Asset[] memory expanded = new Asset[](side.assets.length + 1);
      for (uint256 i; i < side.assets.length; ++i) {
        expanded[i] = side.assets[i];
      }
      expanded[side.assets.length] = Asset({assetType: AssetType.ERC1155, target: TOKEN, id: 1, amount: 1});
      side.assets = expanded;
    }
  }

  function _copy(ProtocolTerms memory terms) internal pure returns (ProtocolTerms memory) {
    return abi.decode(abi.encode(terms), (ProtocolTerms));
  }
}
