// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {Vault} from "../vault/Vault.sol";
import {OverToken} from "../mocks/OverToken.sol";
import {MockVerifierProxy} from "../mocks/MockVerifierProxy.sol";
import {DataStreamsReports} from "../libs/DataStreamsReports.sol";
import {ChannelGame} from "./ChannelGame.sol";
import {GameState} from "./GameState.sol";
import {GameLogic} from "./GameLogic.sol";

abstract contract ChannelGameTestBase is Test {
  address constant TIMELOCK = address(0x71);
  address constant ADMIN = address(0xA1);
  address constant GUARDIAN = address(0x61);
  address constant PLAYER = address(0x1001);
  address constant PLAYER2 = address(0x1002);
  bytes32 constant BTC = bytes32((uint256(0x0003) << 240) | 1);

  uint256 operatorPk = 0xBEEF;
  address operator;

  OverToken token;
  AccessRegistry access;
  AssetRegistry assets;
  Vault vault;
  MockVerifierProxy verifier;
  ChannelGame game;

  uint64 constant T0 = 1_800_000_000;

  function setUp() public virtual {
    operator = vm.addr(operatorPk);
    vm.warp(T0);

    token = new OverToken(10_000_000e18);
    access = AccessRegistry(
      address(
        new ERC1967Proxy(
          address(new AccessRegistry()),
          abi.encodeCall(AccessRegistry.initialize, (TIMELOCK, ADMIN, operator, GUARDIAN))
        )
      )
    );
    assets = AssetRegistry(
      address(new ERC1967Proxy(address(new AssetRegistry()), abi.encodeCall(AssetRegistry.initialize, (address(access)))))
    );
    vault = Vault(
      address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(token)))))
    );
    verifier = new MockVerifierProxy();
    game = ChannelGame(
      address(
        new ERC1967Proxy(
          address(new ChannelGame()),
          abi.encodeCall(ChannelGame.initialize, (address(access), address(assets), address(vault), address(verifier), 7 days))
        )
      )
    );
    vm.prank(ADMIN);
    vault.setGame(address(game));
    // v3 (ADR-0022): currency 0 with a 5 % drawdown share — what the upgrade's reinitializer sets
    vm.prank(ADMIN);
    game.initializeV3(500);

    vm.prank(ADMIN);
    assets.registerAsset(BTC, _config());

    // capital and balances
    token.transfer(ADMIN, 1_000_000e18);
    token.transfer(PLAYER, 100_000e18);
    token.transfer(PLAYER2, 100_000e18);
    vm.startPrank(ADMIN);
    token.approve(address(vault), type(uint256).max);
    vault.depositCapital(500_000e18);
    vm.stopPrank();
    vm.prank(PLAYER);
    token.approve(address(vault), type(uint256).max);
    vm.prank(PLAYER2);
    token.approve(address(vault), type(uint256).max);
  }

  function _config() internal pure returns (AssetRegistry.AssetConfig memory cfg) {
    cfg.enabled = true;
    cfg.assetType = AssetRegistry.AssetType.Continuous;
    cfg.decimals = 18;
    cfg.minHeightSigmaWad = 4e18;
    cfg.maxHeightSigmaWad = 40e18;
    cfg.maxSlopeSigmaPerMinWad = 0.0167e18;
    cfg.minDurationSec = 15 minutes;
    cfg.maxDurationSec = 24 hours;
    cfg.minDeposit = 10e18;
    cfg.maxDeposit = 10_000e18;
    cfg.openFeeBps = 100;
    cfg.openFeeFixed = 0.5e18;
    cfg.profitFeeBps = 1000;
    cfg.royaltyBps = 1500;
    cfg.earlyClosePenaltyBps = 500;
    cfg.channelCreationFee = 0;
    cfg.ceilingWad = 50e18;
    cfg.minMultiplierWad = 1.01e18;
  }

  // ----------------- helpers -----------------

  function _quote(uint256 sigmaWad) internal view returns (ChannelGame.VolatilityQuote memory q, bytes memory sig) {
    return _quoteFor(BTC, sigmaWad);
  }

  function _quoteFor(bytes32 feedId, uint256 sigmaWad) internal view returns (ChannelGame.VolatilityQuote memory q, bytes memory sig) {
    q = ChannelGame.VolatilityQuote({
      feedId: feedId,
      sigmaWad: sigmaWad,
      modelVersion: 1,
      quotedAt: uint64(block.timestamp / 60 * 60),
      deadline: uint64(block.timestamp + 90)
    });
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          "VolatilityQuote(bytes32 feedId,uint256 sigmaWad,uint32 modelVersion,uint64 quotedAt,uint64 deadline)"
        ),
        q.feedId, q.sigmaWad, q.modelVersion, q.quotedAt, q.deadline
      )
    );
    sig = _signTyped(operatorPk, structHash);
  }

  /// @dev ADR-0023: the operator's entry permit for `owner` in `currencyId`, valid for 10 minutes.
  function _permitFor(address owner, uint8 currencyId) internal view returns (uint64 deadline, bytes memory sig) {
    deadline = uint64(block.timestamp + 600);
    sig = _signPermit(operatorPk, owner, currencyId, deadline);
  }

  function _signPermit(uint256 pk, address owner, uint8 currencyId, uint64 deadline) internal view returns (bytes memory) {
    return _signTyped(
      pk,
      keccak256(
        abi.encode(keccak256("EntryPermit(address owner,uint8 currencyId,uint64 deadline)"), owner, currencyId, deadline)
      )
    );
  }

  /// @dev EIP-712 signature over the game's domain ("Overcall Channel", "1").
  function _signTyped(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
    bytes32 domain = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256(bytes("Overcall Channel")),
        keccak256(bytes("1")),
        block.chainid,
        address(game)
      )
    );
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    (uint8 v, bytes32 r, bytes32 s2) = vm.sign(pk, digest);
    return abi.encodePacked(r, s2, v);
  }

  function _report(int192 price, uint32 validFrom, uint32 observed) internal pure returns (bytes memory) {
    bytes memory data = abi.encode(
      DataStreamsReports.ReportV3(BTC, validFrom, observed, 0, 0, 0, price, price, price)
    );
    bytes32[3] memory ctx;
    return abi.encode(ctx, data);
  }

  /// @dev Channel ±1% around 80000, sideways, for 4 hours, from entry price.
  function _openDefault(GameState.Side side, address player) internal returns (uint256 positionId) {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, player);
    r.side = side;
    r.deposit = 100e18;
    r.owner = player;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(player);
    positionId = game.openPosition(r);
  }

  function _bind(uint256 positionId, int192 price, uint64 pWad) internal {
    _bindD(positionId, price, pWad, 0.02e18); // default δ — the historical value used in test quotes
  }

  function _bindD(uint256 positionId, int192 price, uint64 pWad, uint64 deltaWad) internal {
    GameState.Position memory p = game.getPosition(positionId);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(price, uint32(p.requestTs) - 1, uint32(p.requestTs) + 1);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Bind, positionId, 0, pWad, deltaWad);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  /// @dev Settle the way the operator does: an ended, unbreached, unattested channel is first marked
  ///      survived in the same batch (a channel never survives by the clock alone, audit 2026-10-19).
  function _settleEntry(uint256 positionId) internal {
    bytes[] memory reports = new bytes[](0);
    uint256 channelId = game.getPosition(positionId).channelId;
    GameState.Channel memory c = game.getChannel(channelId);
    bool attest = block.timestamp > c.endTs && c.breachedAt == 0 && c.survivedAt == 0;
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](attest ? 2 : 1);
    if (attest) entries[0] = GameState.BatchEntry(GameState.EntryKind.MarkSurvived, channelId, 0, 0, 0);
    entries[attest ? 1 : 0] = GameState.BatchEntry(GameState.EntryKind.Settle, positionId, 0, 0, 0);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  /// @dev A bare Settle, without the operator's survival attestation.
  function _settleOnlyEntry(uint256 positionId) internal {
    bytes[] memory reports = new bytes[](0);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Settle, positionId, 0, 0, 0);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  function _markSurvivedEntry(uint256 channelId) internal {
    bytes[] memory reports = new bytes[](0);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.MarkSurvived, channelId, 0, 0, 0);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  /// @dev SettleClose with a report covering the position's closeRequestTs.
  function _settleCloseEntry(uint256 positionId, int192 price, uint64 pNowWad) internal {
    GameState.Position memory p = game.getPosition(positionId);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(price, uint32(p.closeRequestTs) - 1, uint32(p.closeRequestTs) + 1);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.SettleClose, positionId, 0, pNowWad, 0);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  /// @dev Joins an existing channel on the "breaches" side one minute later; bound at 80100 with P 0.6 (M = 2.45).
  function _joinBreachSide(uint256 channelId) internal returns (uint256 pidB) {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.channelId = channelId;
    r.side = GameState.Side.Breach;
    r.deposit = 100e18;
    r.owner = PLAYER2;
    r.quote = q;
    r.quoteSignature = sig;
    vm.warp(block.timestamp + 60);
    vm.prank(PLAYER2);
    pidB = game.openPosition(r);
    _bind(pidB, 80_100e18, 0.6e18);
  }

  function _breachEntry(uint256 channelId, int192 price, uint32 observed) internal {
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(price, observed, observed);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Breach, channelId, 0, 0, 0);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }
}
