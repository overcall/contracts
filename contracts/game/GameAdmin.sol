// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {GameState as S} from "./GameState.sol";
import {Vault} from "../vault/Vault.sol";

/**
 * @title GameAdmin
 * @notice The game's currency and route administration (ADR-0021/0022) — an external library,
 *         delegatecalled by ChannelGame, kept out of the contract for size. Access is checked here
 *         against the registry; events are emitted from the proxy's address.
 */
library GameAdmin {
  uint16 internal constant BPS = 10_000;
  /// @dev Claim bits are a uint8 and AssetRegistry.MAX_CURRENCIES is 8.
  uint8 internal constant MAX_CURRENCIES = 8;

  event CurrencyAdded(uint8 indexed currencyId, address vault, address token);
  event CurrencyParamsSet(uint8 indexed currencyId, uint16 drawdownBps, uint128 dustFloor);
  event RouterSet(address router);
  event RoutePathSet(uint8 indexed currencyId, address[] path);
  event CurrencyAccessSet(uint8 indexed currencyId, bool permitless);
  event MaxReportLagSet(uint32 seconds_);

  error NotAdmin();
  error NotTimelock();
  error UnknownCurrency(uint8 currencyId);
  error BadRoute(string what);
  error BadCurrencyParams(string what);
  error VaultNotBound(address vault);
  error InvalidReportLag(uint32 seconds_);

  /// @dev v3 reinitialization body: the pre-v3 vault becomes currency 0 with its drawdown share.
  function initV3(uint16 overDrawdownBps) external {
    S.GameStorage storage $ = S.s();
    // the upgrade runs it inside upgradeToAndCall (caller: timelock); a fresh deploy calls it as the admin —
    // never by anyone, or the first caller would choose the share (audit 2026-10-09)
    if (!$.access.isTimelock(msg.sender) && !$.access.isAdmin(msg.sender)) revert NotAdmin();
    if (overDrawdownBps == 0 || overDrawdownBps > BPS) revert BadCurrencyParams("drawdown");
    $.currencyTokens[0] = $.vault.token();
    $.currencies[0].drawdownBps = overDrawdownBps;
    $.currencyCount = 1;
    emit CurrencyAdded(0, address($.vault), $.currencyTokens[0]);
    emit CurrencyParamsSet(0, overDrawdownBps, 0);
  }

  /// @notice Adds a currency: a vault of our implementation, already bound to this game. Timelock:
  ///         the vault is where players' money goes.
  function addCurrency(address vault_, uint16 drawdownBps, uint128 dustFloor, address[] calldata path)
    external
    returns (uint8 currencyId)
  {
    S.GameStorage storage $ = S.s();
    if (!$.access.isTimelock(msg.sender)) revert NotTimelock();
    if ($.currencyCount == 0 || $.currencyCount >= MAX_CURRENCIES) revert BadCurrencyParams("count");
    if (Vault(vault_).game() != address(this)) revert VaultNotBound(vault_);
    // one vault, one currency: a second registration would give the same capital a second allowance
    address token = Vault(vault_).token();
    for (uint8 i = 0; i < $.currencyCount; i++) {
      if (address(S.vaultOf($, i)) == vault_ || $.currencyTokens[i] == token) revert BadCurrencyParams("duplicate");
    }
    currencyId = $.currencyCount++;
    $.vaults[currencyId] = Vault(vault_);
    $.currencyTokens[currencyId] = Vault(vault_).token();
    emit CurrencyAdded(currencyId, vault_, $.currencyTokens[currencyId]);
    _setParams($, currencyId, drawdownBps, dustFloor);
    _setPath($, currencyId, path);
  }

  /// @notice Drawdown share (0 closes intake and defers every reward) and claim dust floor. Admin.
  function setCurrencyParams(uint8 currencyId, uint16 drawdownBps, uint128 dustFloor) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    if (currencyId >= $.currencyCount) revert UnknownCurrency(currencyId);
    _setParams($, currencyId, drawdownBps, dustFloor);
  }

  /// @notice How long after the anchored second a report may be observed and still price a bind or a
  ///         close (audit 2026-10-19, M-06). Admin; 1 s to 5 min, so a typo can neither stop binding nor
  ///         reopen late pricing.
  function setMaxReportLag(uint32 seconds_) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    if (seconds_ == 0 || seconds_ > 300) revert InvalidReportLag(seconds_);
    $.maxReportLagSec = seconds_;
    emit MaxReportLagSet(seconds_);
  }

  /// @notice The exchange route's router: the one place a claimant's royalty could be stolen — timelock.
  function setRouter(address router_) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isTimelock(msg.sender)) revert NotTimelock();
    $.router = router_;
    emit RouterSet(router_);
  }

  /// @notice Who may open positions in a currency (ADR-0023): only owners holding the operator's entry
  ///         permit (the default), or anyone. Admin; OVER always takes anyone.
  function setCurrencyPermitless(uint8 currencyId, bool permitless) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    if (currencyId == 0 || currencyId >= $.currencyCount) revert UnknownCurrency(currencyId);
    $.currencies[currencyId].permitless = permitless;
    emit CurrencyAccessSet(currencyId, permitless);
  }

  /// @notice The token path of a currency's route (currency token → … → OVER). A bad path can only
  ///         give a bad price, which the claimant's minimum output guards against — admin.
  function setRoutePath(uint8 currencyId, address[] calldata path) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    if (currencyId == 0 || currencyId >= $.currencyCount) revert UnknownCurrency(currencyId);
    _setPath($, currencyId, path);
  }

  function _setParams(S.GameStorage storage $, uint8 currencyId, uint16 drawdownBps, uint128 dustFloor) private {
    if (drawdownBps > BPS) revert BadCurrencyParams("drawdown");
    // the dust floor can never swallow a real royalty: at most one whole unit of the currency
    if (dustFloor > 10 ** IERC20Metadata($.currencyTokens[currencyId]).decimals()) revert BadCurrencyParams("dust");
    S.CurrencyState storage cs = $.currencies[currencyId];
    cs.drawdownBps = drawdownBps;
    cs.dustFloor = dustFloor;
    emit CurrencyParamsSet(currencyId, drawdownBps, dustFloor);
  }

  function _setPath(S.GameStorage storage $, uint8 currencyId, address[] calldata path) private {
    if (path.length < 2) revert BadRoute("length");
    if (path[0] != $.currencyTokens[currencyId]) revert BadRoute("start");
    if (path[path.length - 1] != $.currencyTokens[0]) revert BadRoute("end");
    $.routePaths[currencyId] = path;
    emit RoutePathSet(currencyId, path);
  }
}
