// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {Vault} from "../vault/Vault.sol";
import {DataStreamsReports} from "../libs/DataStreamsReports.sol";
import {IVerifierProxy} from "../interfaces/IVerifierProxy.sol";
import {GameState as S} from "./GameState.sol";
import {GameLogic} from "./GameLogic.sol";
import {GameEntry} from "./GameEntry.sol";
import {ClaimLogic} from "./ClaimLogic.sol";
import {GameAdmin} from "./GameAdmin.sol";

/**
 * @title ChannelGame
 * @notice The core of the Channel game: channels (ERC-721, ADR-0018), two-sided requests (ADR-0019),
 *         the operator batch, royalties. Money moves only through the vaults. The contract is a thin
 *         shell over four external libraries sharing its storage by delegatecall (the 24 KB limit):
 *         GameEntry (channels, requests), GameLogic (the batch engine, deferred rewards),
 *         ClaimLogic (royalty claims with conversion), GameAdmin (currencies, exchange route).
 *         The contract keeps what needs its own identity: the EIP-712 quote check, the ERC-721
 *         mint and transfer lock, the pause, the upgrade gate.
 *
 *         v3 (ADR-0021/0022): a position has a currency and its money lives in that currency's
 *         vault; each currency has a drawdown allowance that can pause the game and defer rewards
 *         for the admin's decision. Every v2 entry point and event keeps its signature — live
 *         callers keep working; the currency-aware variants are additions (`openPositionIn`,
 *         `createChannelIn`, `claimRoyaltiesIn`, `PositionCurrency`).
 *
 * @dev UUPS (ADR-0009), ERC-7201. Events and errors raised inside the libraries are declared here
 *      too, so the game's ABI decodes everything emitted from its address.
 */
contract ChannelGame is Initializable, UUPSUpgradeable, ERC721Upgradeable, EIP712Upgradeable {
  uint256 public constant WAD = 1e18;
  uint16 public constant BPS = 10_000;

  /// @dev Quote bound: σ is a fraction of price (≤ 100%). δ is no longer part of the quote —
  ///      it depends on the remainder and is brought in the binding entry (checked in GameLogic).
  uint256 private constant MAX_QUOTE_SIGMA_WAD = 1e18;
  /// @dev requestCloseBatch: the most positions one call may close (gas headroom, ~50k each).
  uint256 public constant MAX_CLOSE_BATCH = 50;

  // ----------------- Request types -----------------

  /// @notice Volatility quote (ADR-0016/0019/0020), signed by the operator.
  struct VolatilityQuote {
    bytes32 feedId;
    uint256 sigmaWad; // raw σ₁ₘ, WAD (without g(N): the horizon adjustment is applied by the P calculator, ADR-0016 amended)
    uint32 modelVersion;
    uint64 quotedAt;
    uint64 deadline;
  }

  bytes32 private constant QUOTE_TYPEHASH = keccak256(
    "VolatilityQuote(bytes32 feedId,uint256 sigmaWad,uint32 modelVersion,uint64 quotedAt,uint64 deadline)"
  );

  /// @notice ADR-0023: the operator's consent that `owner` may hold a position in `currencyId` — the gate for
  ///         a currency open only to some players (USDG launches for stakers only). Not needed for OVER or a
  ///         permitless currency.
  bytes32 private constant ENTRY_PERMIT_TYPEHASH =
    keccak256("EntryPermit(address owner,uint8 currencyId,uint64 deadline)");

  struct NewChannel {
    bytes32 feedId;
    uint64 startTs; // drawn value; ignored when priceOnOpen
    uint64 endTs;
    int192 centerPrice; // 0 when priceOnOpen
    uint128 heightWad;
    int128 slopeWadPerSec;
    bool priceOnOpen;
    address channelOwner; // owner of the channel NFT (ADR-0018)
  }

  struct OpenRequest {
    uint256 channelId; // 0 = create a new channel
    NewChannel newChannel;
    S.Side side;
    uint128 deposit;
    address owner; // position owner (ADR-0011)
    uint128 minMultiplierWad; // player's multiplier floor: binds only when M ≥ max(this, config minimum); 0 = no floor
    VolatilityQuote quote;
    bytes quoteSignature;
  }

  // ----------------- Events (ADR-0008/0020) — those emitted by the libraries are redeclared for the ABI -----------------

  event ChannelCreated(
    uint256 indexed channelId, bytes32 indexed feedId, address indexed owner, uint64 startTs, uint64 endTs,
    int192 centerPrice, uint128 heightWad, int128 slopeWadPerSec, bool priceOnOpen, uint16 royaltyBps
  );
  event PositionRequested(
    uint256 indexed positionId, uint256 indexed channelId, address indexed owner, uint8 side, uint128 deposit,
    uint128 stake, uint64 requestTs, uint256 sigmaWad, uint32 modelVersion
  );
  event CloseRequested(uint256 indexed positionId, uint64 closeRequestTs);
  event BatchEntrySkipped(uint256 indexed id, uint8 kind, bytes reason);
  event RoyaltyClaimed(uint256 indexed channelId, address indexed owner, uint256 amount);
  event PausedSet(bool paused);
  // v3 — additive (ADR-0021/0022)
  event PositionCurrency(uint256 indexed positionId, uint8 indexed currencyId);
  event CurrencyAdded(uint8 indexed currencyId, address vault, address token);
  event CurrencyParamsSet(uint8 indexed currencyId, uint16 drawdownBps, uint128 dustFloor);
  event RouterSet(address router);
  event RoutePathSet(uint8 indexed currencyId, address[] path);
  event CurrencyAccessSet(uint8 indexed currencyId, bool permitless);
  event BaseURISet(string baseURI);
  event ChannelSurvived(uint256 indexed channelId, uint64 survivedAt);
  event MaxReportLagSet(uint32 seconds_);
  /// @dev ERC-4906: marketplaces refetch the metadata of the range.
  event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

  // ----------------- Errors — those raised by the libraries are redeclared for the ABI -----------------

  error NotOperator();
  error NotAdmin();
  error NotGuardianOrAdmin();
  error NotTimelock();
  error GamePaused();
  error UnknownChannel(uint256 channelId);
  error WrongStatus(uint256 positionId, S.PositionStatus status);
  error QuoteExpired(uint64 deadline);
  error QuoteSignerNotOperator(address signer);
  error QuoteFeedMismatch(bytes32 expected, bytes32 actual);
  error QuoteOutOfRange();
  error MultiplierFloorTooHigh(uint128 floorWad, uint128 ceilingWad);
  error AssetNotAccepting(bytes32 feedId);
  error BadGeometry(string what);
  error BadDeposit(uint128 deposit);
  error ChannelClosedForEntries(uint256 channelId);
  error NotPositionOwner(uint256 positionId);
  error NotChannelOwner(uint256 channelId);
  error ChannelNotClaimable(uint256 channelId);
  error TransferLocked(uint256 channelId);
  error ChannelExpired(uint256 channelId);
  error InvalidWindow();
  // v3
  error UnknownCurrency(uint8 currencyId);
  error CurrencyNotAccepted(bytes32 feedId, uint8 currencyId);
  error DeferredPending(uint32 count);
  error BadRoute(string what);
  error BadCurrencyParams(string what);
  error VaultNotBound(address vault);
  error PermitExpired(uint64 deadline);
  error PermitSignerNotOperator(address signer);
  error BadOwner(address owner);
  error BatchTooLarge(uint256 count);
  error NothingToClose();
  error InboundShortfall(uint256 requested, uint256 received);
  error InvalidReportLag(uint32 seconds_);

  modifier onlyOperator() {
    if (!S.s().access.isOperator(msg.sender)) revert NotOperator();
    _;
  }

  modifier onlyAdmin() {
    if (!S.s().access.isAdmin(msg.sender)) revert NotAdmin();
    _;
  }

  modifier onlyTimelock() {
    if (!S.s().access.isTimelock(msg.sender)) revert NotTimelock();
    _;
  }

  modifier notPaused() {
    if (S.s().paused) revert GamePaused();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address access_,
    address assets_,
    address vault_,
    address verifier_,
    uint64 settlementWindow_
  ) external initializer {
    __ERC721_init("Overcall Channel", "OCCH");
    __EIP712_init("Overcall Channel", "1");
    S.GameStorage storage $ = S.s();
    $.access = AccessRegistry(access_);
    $.assets = AssetRegistry(assets_);
    $.vault = Vault(vault_);
    $.verifier = IVerifierProxy(verifier_);
    if (settlementWindow_ < 1 days || settlementWindow_ > 30 days) revert InvalidWindow();
    $.settlementWindow = settlementWindow_;
    $.nextChannelId = 1;
    $.nextPositionId = 1;
  }

  /**
   * @notice v3 state (ADR-0021/0022): registers the pre-v3 vault as currency 0 with its drawdown
   *         share. Runs inside the upgrade's `upgradeToAndCall`, so the game never settles a win
   *         with a zero share. Further currencies are added by the timelock (`addCurrency`).
   */
  function initializeV3(uint16 overDrawdownBps) external reinitializer(2) {
    GameAdmin.initV3(overDrawdownBps);
  }

  // ----------------- Currencies (ADR-0021) — timelock / admin, checked in GameAdmin -----------------

  function addCurrency(address vault_, uint16 drawdownBps, uint128 dustFloor, address[] calldata path)
    external
    returns (uint8 currencyId)
  {
    return GameAdmin.addCurrency(vault_, drawdownBps, dustFloor, path);
  }

  function setCurrencyParams(uint8 currencyId, uint16 drawdownBps, uint128 dustFloor) external {
    GameAdmin.setCurrencyParams(currencyId, drawdownBps, dustFloor);
  }

  function setCurrencyPermitless(uint8 currencyId, bool permitless) external {
    GameAdmin.setCurrencyPermitless(currencyId, permitless);
  }

  function setRouter(address router_) external {
    GameAdmin.setRouter(router_);
  }

  function setRoutePath(uint8 currencyId, address[] calldata path) external {
    GameAdmin.setRoutePath(currencyId, path);
  }

  function setMaxReportLag(uint32 seconds_) external {
    GameAdmin.setMaxReportLag(seconds_);
  }

  /// @notice The report lag in force: the admin's setting, 30 s until set.
  function maxReportLag() external view returns (uint32) {
    uint32 lag = S.s().maxReportLagSec;
    return lag == 0 ? 30 : lag;
  }

  // ----------------- Channel NFT metadata -----------------

  /// @notice Base of every channel token's metadata URI: tokenURI(id) = baseURI + id. Admin; empty = none.
  function setBaseURI(string calldata baseURI_) external onlyAdmin {
    S.s().baseURI = baseURI_;
    emit BaseURISet(baseURI_);
    emit BatchMetadataUpdate(0, type(uint256).max);
  }

  function _baseURI() internal view override returns (string memory) {
    return S.s().baseURI;
  }

  /// @dev ERC-4906 (metadata update events) on top of ERC-721.
  function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
    return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
  }

  // ----------------- Guardian / admin -----------------

  /// @notice Pause: guardian or admin; unpause: admin only, and only once every deferred reward is
  ///         decided (ADR-0022) — `forceUnpause` overrides. Unpausing refills no allowance.
  function setPaused(bool paused_) external {
    S.GameStorage storage $ = S.s();
    bool allowed = paused_
      ? ($.access.isGuardian(msg.sender) || $.access.isAdmin(msg.sender))
      : $.access.isAdmin(msg.sender); // only the admin can unpause
    if (!allowed) revert NotGuardianOrAdmin();
    if (!paused_ && $.deferredCount != 0) revert DeferredPending($.deferredCount);
    $.paused = paused_;
    emit PausedSet(paused_);
  }

  function forceUnpause() external onlyAdmin {
    S.s().paused = false;
    emit PausedSet(false);
  }

  // ----------------- Deferred rewards (ADR-0022) — admin, checked in GameLogic -----------------

  function approveRewards(uint256[] calldata positionIds) external {
    GameLogic.approveRewards(positionIds);
  }

  function rejectRewards(uint256[] calldata positionIds) external {
    GameLogic.rejectRewards(positionIds);
  }

  function refillAllowance(uint8 currencyId) external {
    GameLogic.refillAllowance(currencyId);
  }

  // ----------------- Channels (ADR-0018) -----------------

  function createChannel(NewChannel calldata p) external notPaused returns (uint256 channelId) {
    channelId = GameEntry.createChannel(p, msg.sender, 0);
    _mint(p.channelOwner, channelId);
  }

  /// @notice Same as `createChannel`, with the creation fee charged in the given currency (ADR-0021).
  function createChannelIn(NewChannel calldata p, uint8 currencyId) external notPaused returns (uint256 channelId) {
    channelId = GameEntry.createChannel(p, msg.sender, currencyId);
    _mint(p.channelOwner, channelId);
  }

  // ----------------- Request (ADR-0003/0011/0016) -----------------

  function openPosition(OpenRequest calldata r) external notPaused returns (uint256 positionId) {
    return _open(r, 0);
  }

  /// @notice Same as `openPosition`, in the given currency (ADR-0021): deposit, reward, fees and
  ///         royalty share all in that currency, from that currency's vault. A currency that is not
  ///         permitless takes the operator's entry permit for `r.owner` (ADR-0023); otherwise the permit
  ///         arguments are ignored (pass 0 and empty bytes).
  function openPositionIn(OpenRequest calldata r, uint8 currencyId, uint64 permitDeadline, bytes calldata permitSig)
    external
    notPaused
    returns (uint256 positionId)
  {
    if (currencyId != 0 && !S.s().currencies[currencyId].permitless) {
      _verifyPermit(r.owner, currencyId, permitDeadline, permitSig);
    }
    return _open(r, currencyId);
  }

  function _open(OpenRequest calldata r, uint8 currencyId) private returns (uint256 positionId) {
    uint256 channelId = r.channelId;
    if (channelId == 0) {
      channelId = GameEntry.createChannel(r.newChannel, msg.sender, currencyId);
      _mint(r.newChannel.channelOwner, channelId);
    }
    S.Channel storage c = S.s().channels[channelId];
    if (c.endTs == 0) revert UnknownChannel(channelId);
    _verifyQuote(r.quote, r.quoteSignature, c.feedId);
    return GameEntry.open(r, channelId, currencyId);
  }

  /// @notice Requests an early close (ADR-0012). Irreversible (ADR-0007).
  function requestClose(uint256 positionId) external {
    S.GameStorage storage $ = S.s();
    S.Position storage p = $.positions[positionId];
    if (p.status != S.PositionStatus.Active) revert WrongStatus(positionId, p.status);
    if (p.owner != msg.sender) revert NotPositionOwner(positionId);
    S.Channel storage c = $.channels[p.channelId];
    if (block.timestamp >= c.endTs) revert ChannelExpired(p.channelId);
    if (c.breachedAt != 0) revert ChannelClosedForEntries(p.channelId);
    _markCloseRequested(p, positionId);
  }

  /// @notice Early-close requests for several of the caller's positions in one transaction (owner 2026-10-11), one
  ///         CloseRequested event each. A position that can no longer be closed (settled, channel ended or breached
  ///         since the player selected it) or isn't the caller's is skipped, so a stale selection never reverts the
  ///         batch; reverts only when nothing was closed. Same rules as requestClose, which stays as it is.
  function requestCloseBatch(uint256[] calldata positionIds) external returns (uint256 closed) {
    if (positionIds.length > MAX_CLOSE_BATCH) revert BatchTooLarge(positionIds.length);
    S.GameStorage storage $ = S.s();
    for (uint256 i = 0; i < positionIds.length; ++i) {
      S.Position storage p = $.positions[positionIds[i]];
      if (!_closableBy(p, $.channels[p.channelId], msg.sender)) continue;
      _markCloseRequested(p, positionIds[i]);
      ++closed;
    }
    if (closed == 0) revert NothingToClose();
  }

  /// @dev requestClose's checks as a predicate: the caller's own Active position on a live, unbreached channel.
  function _closableBy(S.Position storage p, S.Channel storage c, address caller) private view returns (bool) {
    return p.status == S.PositionStatus.Active && p.owner == caller && block.timestamp < c.endTs && c.breachedAt == 0;
  }

  function _markCloseRequested(S.Position storage p, uint256 positionId) private {
    p.status = S.PositionStatus.CloseRequested;
    p.closeRequestTs = uint48(block.timestamp);
    emit CloseRequested(positionId, p.closeRequestTs);
  }

  // ----------------- Operator batch (ADR-0006/0007) -----------------

  /// @notice Reports are verified exactly once each; entries reference them by index.
  function processBatch(bytes[] calldata reports, S.BatchEntry[] calldata entries) external onlyOperator {
    S.GameStorage storage $ = S.s();
    DataStreamsReports.Decoded[] memory decoded = new DataStreamsReports.Decoded[](reports.length);
    for (uint256 i = 0; i < reports.length; i++) {
      decoded[i] = DataStreamsReports.decode($.verifier.verify(reports[i], bytes("")));
    }
    for (uint256 i = 0; i < entries.length; i++) {
      bytes memory reason = GameLogic.applyEntry(entries[i], decoded);
      if (reason.length != 0) emit BatchEntrySkipped(entries[i].id, uint8(entries[i].kind), reason);
    }
  }

  /// @notice Refund once the settlement window has expired — invoked by the position owner (ADR-0002).
  function refundStale(uint256 positionId) external {
    GameLogic.refundStale(positionId);
  }

  // ----------------- Royalties (ADR-0018/0021) -----------------

  /// @notice The OVER royalty of each channel (v2 entry point).
  function claimRoyalties(uint256[] calldata channelIds) external {
    ClaimLogic.claim(channelIds, 0, 0, 0);
  }

  /// @notice The royalty of each channel in one currency; a non-OVER currency is converted into OVER
  ///         along the exchange route and the owner receives OVER (ADR-0021).
  function claimRoyaltiesIn(uint256[] calldata channelIds, uint8 currencyId, uint256 minOverOut, uint256 deadline)
    external
  {
    ClaimLogic.claim(channelIds, currencyId, minOverOut, deadline);
  }

  /// @dev Transfer lock (ADR-0018/0021): closed, settled, and claimed or empty in every currency.
  function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
    address from = _ownerOf(tokenId);
    if (from != address(0) && to != address(0) && ClaimLogic.isTransferLocked(tokenId)) revert TransferLocked(tokenId);
    return super._update(to, tokenId, auth);
  }

  // ----------------- Internal -----------------

  function _verifyQuote(VolatilityQuote calldata q, bytes calldata sig, bytes32 feedId) internal view {
    if (q.feedId != feedId) revert QuoteFeedMismatch(feedId, q.feedId);
    if (block.timestamp > q.deadline) revert QuoteExpired(q.deadline);
    // bounds: σ > 0 (used as a divisor in geometry), δ < 50% (otherwise (1−δ) in the multiplier breaks the price meaning)
    if (q.sigmaWad == 0 || q.sigmaWad > MAX_QUOTE_SIGMA_WAD) revert QuoteOutOfRange();
    bytes32 digest = _hashTypedDataV4(
      keccak256(abi.encode(QUOTE_TYPEHASH, q.feedId, q.sigmaWad, q.modelVersion, q.quotedAt, q.deadline))
    );
    address signer = ECDSA.recover(digest, sig);
    if (!S.s().access.isOperator(signer)) revert QuoteSignerNotOperator(signer);
  }

  /// @dev ADR-0023: the permit binds the position's owner, so a permit cannot be spent on anyone else's
  ///      position, and expires like a quote.
  function _verifyPermit(address owner, uint8 currencyId, uint64 deadline, bytes calldata sig) internal view {
    if (block.timestamp > deadline) revert PermitExpired(deadline);
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(ENTRY_PERMIT_TYPEHASH, owner, currencyId, deadline)));
    address signer = ECDSA.recover(digest, sig);
    if (!S.s().access.isOperator(signer)) revert PermitSignerNotOperator(signer);
  }

  // ----------------- Views -----------------

  function getChannel(uint256 channelId) external view returns (S.Channel memory) {
    return S.s().channels[channelId];
  }

  function getPosition(uint256 positionId) external view returns (S.Position memory) {
    return S.s().positions[positionId];
  }

  function paused() external view returns (bool) {
    return S.s().paused;
  }

  function currencyCount() external view returns (uint8) {
    return S.s().currencyCount;
  }

  /// @notice Everything about one currency: its vault and token, drawdown state, dust floor, route path.
  function currencyInfo(uint8 currencyId)
    external
    view
    returns (address vault, address token, S.CurrencyState memory state, address[] memory path)
  {
    S.GameStorage storage $ = S.s();
    return (address(S.vaultOf($, currencyId)), $.currencyTokens[currencyId], $.currencies[currencyId], $.routePaths[currencyId]);
  }

  function allowanceRemaining(uint8 currencyId) external view returns (uint256 remainder, uint256 capacity) {
    return GameLogic.allowanceRemaining(currencyId);
  }

  function deferredCount() external view returns (uint32) {
    return S.s().deferredCount;
  }

  function router() external view returns (address) {
    return S.s().router;
  }

  // ----------------- UUPS -----------------

  function _authorizeUpgrade(address) internal override onlyTimelock {}
}
