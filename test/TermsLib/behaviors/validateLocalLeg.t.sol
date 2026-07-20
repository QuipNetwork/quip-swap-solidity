// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib validateLocalLeg Tests
/// @dev Tests for TermsLib.validateLocalLeg — the leg escrowed on THIS chain must
///      carry EVM-narrowable asset targets and reclaimRecipient; its `recipient`
///      receives on the COUNTERPARTY's chain and is deliberately not checked
contract TermsLib_validateLocalLeg is TermsLibTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_validateLocalLeg_nativeLeg() public view {
    // native asset target is bytes32(0), which narrows cleanly
    harness.exposed_validateLocalLeg(_defaultTerms());
  }

  function test_validateLocalLeg_tokenLeg() public view {
    Terms memory terms = _defaultTerms();
    terms.assets = AssetHelper.toArray(
      _makeNativeAsset(1 ether), _makeERC20Asset(100 ether), _makeERC721Asset(1), _makeERC1155Asset(1, 50)
    );
    harness.exposed_validateLocalLeg(terms);
  }

  function test_validateLocalLeg_allowsForeignRecipient() public view {
    // the crux: a local leg's recipient may be a Solana pubkey — it receives the
    // counterparty's assets on the counterparty's chain, never here
    Terms memory terms = _defaultTerms();
    terms.recipient = SOLANA_PUBKEY;
    harness.exposed_validateLocalLeg(terms);
  }

  // ============ Revert Cases ============

  function test_validateLocalLeg_revertsWhen_reclaimRecipientNotEvm() public {
    Terms memory terms = _defaultTerms();
    terms.reclaimRecipient = SOLANA_PUBKEY;
    vm.expectRevert(abi.encodeWithSelector(TermsLib.NotEvmAddress.selector, SOLANA_PUBKEY));
    harness.exposed_validateLocalLeg(terms);
  }

  function test_validateLocalLeg_revertsWhen_assetTargetNotEvm() public {
    Terms memory terms = _defaultTerms();
    terms.assets = AssetHelper.makeERC20(SOLANA_MINT, 100 ether).toArray();
    vm.expectRevert(abi.encodeWithSelector(TermsLib.NotEvmAddress.selector, SOLANA_MINT));
    harness.exposed_validateLocalLeg(terms);
  }

  function test_validateLocalLeg_revertsWhen_laterAssetTargetNotEvm() public {
    // every asset is checked, not just the first
    Terms memory terms = _defaultTerms();
    terms.assets = AssetHelper.toArray(_makeERC20Asset(100 ether), AssetHelper.makeERC20(SOLANA_MINT, 100 ether));
    vm.expectRevert(abi.encodeWithSelector(TermsLib.NotEvmAddress.selector, SOLANA_MINT));
    harness.exposed_validateLocalLeg(terms);
  }
}
