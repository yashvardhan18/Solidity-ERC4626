// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC4626} from "./interfaces/IERC4626.sol";

/// @title HighWaterMarkVault
/// @author Assignment submission
/// @notice An ERC-4626 tokenized vault that charges a 20% performance fee on new profits only.
/// @dev Task 1. The ERC-4626 accounting is written by hand — `OZ ERC4626` is deliberately not
///      inherited. Only the plumbing that has nothing to do with vault math is reused:
///      `ERC20` for the share token, `SafeERC20` for transfers, `Ownable` for admin,
///      `ReentrancyGuard` for the external-call ordering, and `Math.mulDiv` for
///      full-precision 512-bit multiply-then-divide.
///
///      Three design decisions carry most of the safety:
///
///      1. **Virtual shares and virtual assets.** Every conversion pretends the vault holds
///         one extra wei of assets and `10 ** _DECIMALS_OFFSET` extra shares. This makes the
///         classic "first depositor inflation / donation" attack economically pointless.
///         Without it, an attacker mints 1 wei-share, donates a large amount directly to the
///         vault to push the share price up, and the next depositor's shares round down to
///         zero — their whole deposit is absorbed by the attacker's single share.
///
///      2. **Directional rounding.** Anything that mints shares or pays out assets rounds
///         *against* the caller and *in favour of* the vault. If it rounded the other way, a
///         caller could loop a tiny operation and skim one wei of value per iteration.
///
///      3. **High-water mark stored as price-per-share, not as a total.** Fees must not be
///         charged twice on the same profit, and must not be charged at all merely because
///         someone deposited more principal. A per-share price is invariant to
///         deposits/withdrawals, so it is the only correct thing to compare against.
contract HighWaterMarkVault is ERC20, IERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // -----------------------------------------------------------------------
    //                                Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when a deposit would push `totalAssets()` past `depositCap`.
    /// @param attemptedTotalAssets What `totalAssets()` would have become.
    /// @param cap The configured ceiling.
    error DepositCapExceeded(uint256 attemptedTotalAssets, uint256 cap);

    /// @notice Thrown when a caller asks to deposit more than `maxDeposit(receiver)`.
    /// @param receiver Address that would have received the shares.
    /// @param assets Amount requested.
    /// @param max Amount currently allowed.
    error ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);

    /// @notice Thrown when a caller asks to mint more than `maxMint(receiver)`.
    /// @param receiver Address that would have received the shares.
    /// @param shares Amount requested.
    /// @param max Amount currently allowed.
    error ExceededMaxMint(address receiver, uint256 shares, uint256 max);

    /// @notice Thrown when a caller asks to withdraw more than `maxWithdraw(owner)`.
    /// @param owner Address whose shares would have been burned.
    /// @param assets Amount requested.
    /// @param max Amount currently allowed.
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);

    /// @notice Thrown when a caller asks to redeem more than `maxRedeem(owner)`.
    /// @param owner Address whose shares would have been burned.
    /// @param shares Amount requested.
    /// @param max Amount currently allowed.
    error ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    /// @notice Thrown when an operation would move zero shares or zero assets.
    /// @dev A no-op deposit/withdraw only burns gas and emits a misleading event, and a
    ///      zero-share deposit would be a pure donation to existing holders. Rejecting it
    ///      makes the failure obvious to the caller instead of silent.
    error ZeroAmount();

    /// @notice Thrown when an address argument that must be non-zero is the zero address.
    error ZeroAddress();

    // -----------------------------------------------------------------------
    //                                Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when `harvest()` crystallises a performance fee.
    /// @param caller Address that called `harvest()`.
    /// @param feeRecipient Address that received the fee shares.
    /// @param feeShares Shares minted as the fee.
    /// @param feeAssets Asset value the minted shares represented at mint time.
    /// @param newHighWaterMark Price-per-share recorded as the new peak.
    event Harvest(
        address indexed caller,
        address indexed feeRecipient,
        uint256 feeShares,
        uint256 feeAssets,
        uint256 newHighWaterMark
    );

    /// @notice Emitted when `harvest()` runs but the vault is at or below its previous peak.
    /// @param currentPricePerShare Price per share at the time of the call.
    /// @param highWaterMark The unchanged peak.
    event HarvestSkipped(uint256 currentPricePerShare, uint256 highWaterMark);

    /// @notice Emitted when the owner changes the deposit cap.
    /// @param oldCap Previous cap.
    /// @param newCap New cap.
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the owner changes the fee recipient.
    /// @param oldRecipient Previous recipient.
    /// @param newRecipient New recipient.
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // -----------------------------------------------------------------------
    //                              Constants
    // -----------------------------------------------------------------------

    /// @notice Performance fee in basis points (2000 bps = 20%), as required by the spec.
    /// @dev `constant` rather than a storage variable: an immutable, publicly readable fee is
    ///      a trust guarantee for depositors. A settable fee would let the owner raise it to
    ///      100% right before a harvest and take the entire profit.
    uint256 public constant PERFORMANCE_FEE_BPS = 2_000;

    /// @notice Denominator for basis-point maths (100% = 10_000 bps).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Number of extra decimals the share token has over the asset token.
    ///      Shares are therefore ~1000x more granular than assets, which is what makes the
    ///      inflation attack unprofitable: to round a victim's deposit down to zero shares an
    ///      attacker must donate more than 1000x the victim's deposit, i.e. lose more than
    ///      they could ever steal. `3` is the conventional trade-off — larger offsets eat
    ///      into the uint256 headroom of `totalSupply`.
    uint8 private constant _DECIMALS_OFFSET = 3;

    /// @dev The "virtual" shares baked into every conversion: `10 ** _DECIMALS_OFFSET`.
    ///      Also removes the division-by-zero that a fresh, empty vault would otherwise hit.
    uint256 private constant _VIRTUAL_SHARES = 10 ** uint256(_DECIMALS_OFFSET);

    /// @dev The "virtual" assets baked into every conversion. One wei is enough: its only job
    ///      is to keep the asset side of the ratio non-zero.
    uint256 private constant _VIRTUAL_ASSETS = 1;

    /// @dev Extra fixed-point precision carried by `pricePerShare()` and therefore by the
    ///      high-water mark. Without it the price would be an integer count of asset units per
    ///      whole share, which for a 6-decimal asset such as USDC means the peak can only be
    ///      recorded to one part in a million — enough to mis-size the fee by a visible amount.
    ///      Scaling by 1e18 makes that error negligible for any realistic token.
    uint256 private constant _PRICE_SCALE = 1e18;

    // -----------------------------------------------------------------------
    //                          Immutable configuration
    // -----------------------------------------------------------------------

    /// @dev The underlying asset. `immutable` because a vault whose asset can change is a
    ///      vault whose entire share price can be rewritten by the owner in one transaction.
    IERC20 private immutable _ASSET;

    /// @dev Decimals of the underlying asset, read once at construction.
    uint8 private immutable _UNDERLYING_DECIMALS;

    /// @dev `10 ** decimals()` — the number of share units in one whole share.
    ///      Price-per-share is quoted as "assets per whole share", so this is the unit we
    ///      convert with. Cached because `10 ** x` is not free and it is used on every harvest.
    uint256 private immutable _ONE_SHARE;

    /// @dev `_ONE_SHARE * _PRICE_SCALE`, precomputed. This is the numerator multiplier used by
    ///      `pricePerShare()`, and the divisor that converts a scaled per-share gain back into
    ///      plain asset units inside `harvest()`.
    uint256 private immutable _ONE_SHARE_SCALED;

    // -----------------------------------------------------------------------
    //                              Storage
    // -----------------------------------------------------------------------

    /// @notice Maximum value `totalAssets()` is allowed to reach through deposits.
    /// @dev A cap is a risk control: strategies have capacity limits, and an uncapped vault
    ///      can take in more than it can safely deploy or unwind. Note it bounds deposits
    ///      only — yield and direct donations may legitimately carry `totalAssets()` above it,
    ///      which simply means no further deposits are accepted until it falls back.
    uint256 public depositCap;

    /// @notice Address that receives freshly minted performance-fee shares.
    address public feeRecipient;

    /// @notice Highest price-per-share ever recorded, in asset units per whole share.
    /// @dev The core of the fee model. Fees are charged only on the amount by which the
    ///      current price exceeds this peak, so a manager who loses 20% and then earns it back
    ///      gets paid nothing for the recovery. Updated only upward — see `harvest()`.
    uint256 public highWaterMark;

    // -----------------------------------------------------------------------
    //                             Constructor
    // -----------------------------------------------------------------------

    /// @param asset_ Underlying ERC-20 the vault accepts.
    /// @param name_ Name of the share token.
    /// @param symbol_ Symbol of the share token.
    /// @param owner_ Initial owner (can set the cap and the fee recipient).
    /// @param feeRecipient_ Initial recipient of performance-fee shares.
    /// @param depositCap_ Initial ceiling on `totalAssets()`.
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address feeRecipient_,
        uint256 depositCap_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        // Reject the zero address early. A vault pointed at address(0) would accept deposits
        // that silently do nothing, and every later transfer would revert with no useful
        // message — an unrecoverable, permanently bricked deployment.
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();

        _ASSET = asset_;

        // Read the asset's decimals defensively. `decimals()` is optional in ERC-20 and some
        // real tokens omit it or return non-standard data; a plain call would revert here and
        // make the vault undeployable for those assets. 18 is the safe default.
        _UNDERLYING_DECIMALS = _tryGetAssetDecimals(address(asset_));

        // Shares carry the offset on top of the asset's decimals so that one whole share is
        // worth roughly one whole asset at launch, which keeps price-per-share readable.
        _ONE_SHARE = 10 ** (uint256(_UNDERLYING_DECIMALS) + uint256(_DECIMALS_OFFSET));
        _ONE_SHARE_SCALED = _ONE_SHARE * _PRICE_SCALE;

        feeRecipient = feeRecipient_;
        depositCap = depositCap_;

        // Seed the high-water mark at the launch price-per-share. Leaving it at zero would
        // make the very first harvest treat the entire principal as "profit" and mint a 20%
        // fee on money nobody earned.
        highWaterMark = pricePerShare();

        emit FeeRecipientUpdated(address(0), feeRecipient_);
        emit DepositCapUpdated(0, depositCap_);
    }

    // -----------------------------------------------------------------------
    //                          ERC-20 share metadata
    // -----------------------------------------------------------------------

    /// @inheritdoc IERC20Metadata
    /// @dev Shares are reported with `assetDecimals + offset` decimals. Front-ends divide by
    ///      this, so reporting the asset's decimals instead would display share balances
    ///      1000x too large.
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _UNDERLYING_DECIMALS + _DECIMALS_OFFSET;
    }

    // -----------------------------------------------------------------------
    //                        ERC-4626: asset & accounting
    // -----------------------------------------------------------------------

    /// @inheritdoc IERC4626
    function asset() public view returns (address) {
        return address(_ASSET);
    }

    /// @inheritdoc IERC4626
    /// @dev This vault holds its assets idly, so assets under management is simply its own
    ///      token balance. A strategy-deploying vault would override this to add the amount
    ///      currently sitting in external protocols; getting that wrong misprices every share.
    function totalAssets() public view returns (uint256) {
        return _ASSET.balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    /// @dev Rounds down. `convertToShares` is a quote, and quoting *more* shares than a
    ///      deposit really buys would let integrators over-credit users.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Rounds down, for the mirror-image reason: never quote more assets than the shares
    ///      can actually be redeemed for.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @notice Current value of one whole share, in asset units scaled by 1e18.
    /// @dev This is the "NAV per share" the high-water mark tracks. Two properties matter:
    ///
    ///      - It uses the same virtual-offset ratio as every other conversion, so it is well
    ///        defined on an empty vault (it returns the launch price instead of dividing by
    ///        zero) and can never disagree with what `redeem` actually pays out.
    ///      - It is scaled by `_PRICE_SCALE`, so the peak is stored with 18 digits of headroom
    ///        below one asset unit. An unscaled integer price would quantise the high-water
    ///        mark to whole asset units per share, and on a 6-decimal asset that quantisation
    ///        alone is a meaningful fraction of the fee.
    ///
    ///      Rounds down, so a stale peak is never recorded higher than reality.
    /// @return price Assets per `10 ** decimals()` shares, multiplied by 1e18.
    function pricePerShare() public view returns (uint256 price) {
        return Math.mulDiv(
            _ONE_SHARE_SCALED, totalAssets() + _VIRTUAL_ASSETS, totalSupply() + _VIRTUAL_SHARES, Math.Rounding.Floor
        );
    }

    // -----------------------------------------------------------------------
    //                        ERC-4626: deposit and mint
    // -----------------------------------------------------------------------

    /// @inheritdoc IERC4626
    /// @dev Reports the remaining room under `depositCap`. EIP-4626 requires that any value up
    ///      to this can be deposited without reverting, so the cap must be reflected here and
    ///      not only inside `deposit`; integrators that call `maxDeposit` first would otherwise
    ///      build transactions that always fail.
    function maxDeposit(address) public view returns (uint256) {
        uint256 currentAssets = totalAssets();
        // Yield or a direct donation can carry the vault above the cap. Saturate at zero
        // instead of letting the subtraction underflow and revert on a plain view call.
        if (currentAssets >= depositCap) return 0;
        return depositCap - currentAssets;
    }

    /// @inheritdoc IERC4626
    /// @dev Rounds down, so the caller can never be quoted more shares than they will receive.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        // Enforce the cap before doing anything else. Checking after the transfer would mean
        // reverting a state change we already paid for, and — worse — a token with transfer
        // hooks could observe the intermediate state.
        uint256 max = maxDeposit(receiver);
        if (assets > max) revert ExceededMaxDeposit(receiver, assets, max);

        // Quote against the *pre-transfer* balance. `totalAssets()` grows the moment the
        // tokens arrive; converting afterwards would price the depositor's own money into the
        // share price and mint them fewer shares than they paid for.
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroAmount();

        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @dev The deposit cap expressed in share terms.
    ///
    ///      Both early returns exist because a `max*` view must never revert — integrators
    ///      call them to size a transaction, and a reverting view breaks them before they ever
    ///      reach the vault. A cap of `type(uint256).max` means "unlimited", and EIP-4626 says
    ///      to report that verbatim rather than trying to convert it (the multiplication inside
    ///      the conversion would overflow). The second guard covers a cap that is finite but
    ///      still too large to express in shares; saturating there is the honest answer, since
    ///      such a cap is not a real constraint on anybody.
    function maxMint(address receiver) public view returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;

        uint256 shareBase = totalSupply() + _VIRTUAL_SHARES;
        if (maxAssets > type(uint256).max / shareBase) return type(uint256).max;

        return maxAssets.mulDiv(shareBase, totalAssets() + _VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Rounds **up**: the caller names an exact share amount, so any rounding remainder
    ///      must be paid by them, not absorbed by existing shareholders.
    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) public nonReentrant returns (uint256 assets) {
        uint256 max = maxMint(receiver);
        if (shares > max) revert ExceededMaxMint(receiver, shares, max);

        assets = previewMint(shares);
        if (assets == 0) revert ZeroAmount();

        _deposit(msg.sender, receiver, assets, shares);
    }

    // -----------------------------------------------------------------------
    //                      ERC-4626: withdraw and redeem
    // -----------------------------------------------------------------------

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Rounds **up**. This single rounding direction is what blocks the classic 1-wei
    ///      drain: if it rounded down, withdrawing an amount whose fair price is 0.4 shares
    ///      would burn 0 shares, and the caller could repeat that until the vault is empty.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256 shares) {
        uint256 max = maxWithdraw(owner);
        if (assets > max) revert ExceededMaxWithdraw(owner, assets, max);

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroAmount();

        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    /// @inheritdoc IERC4626
    /// @dev Rounds down: burning an exact share amount must never pay out more than those
    ///      shares are worth, or the remainder is stolen from everyone else in the vault.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        uint256 max = maxRedeem(owner);
        if (shares > max) revert ExceededMaxRedeem(owner, shares, max);

        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAmount();

        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // -----------------------------------------------------------------------
    //                        Performance fee (harvest)
    // -----------------------------------------------------------------------

    /// @notice Crystallises the 20% performance fee on any profit above the all-time peak
    ///         price-per-share, minting the fee to `feeRecipient` as new shares.
    /// @dev Permissionless by design. The function can only ever mint the fee that the
    ///      accounting already says is owed, and it is monotone — calling it twice in a row
    ///      does nothing the second time — so there is no benefit to restricting who calls it,
    ///      and leaving it open means the fee cannot be withheld by an absent manager.
    ///
    ///      Fee is paid in **shares**, not assets. Paying in assets would require selling or
    ///      holding idle liquidity; minting shares dilutes existing holders by exactly the fee
    ///      amount and leaves the vault's asset balance untouched.
    ///
    ///      The mint is sized so the recipient's new shares are worth `feeAssets` *after* the
    ///      dilution they themselves cause — solving `m * A / (S + m) = f` for `m` gives
    ///      `m = f * S / (A - f)`. Naively minting `f * S / A` would underpay the recipient.
    /// @return feeShares Number of shares minted as the fee (zero if no new peak).
    function harvest() external nonReentrant returns (uint256 feeShares) {
        uint256 supply = totalSupply();

        // With no shareholders there is nobody to charge and no meaningful NAV. Returning
        // early also stops a donation into an empty vault from ratcheting the high-water mark
        // to an absurd value that no future performance could ever exceed.
        if (supply == 0) return 0;

        uint256 currentPrice = pricePerShare();
        uint256 hwm = highWaterMark;

        // Below or at the peak: no new profit exists, so no fee is owed and — critically —
        // the high-water mark is left untouched. This is the "skips when NAV < HWM, HWM never
        // decreases" requirement. Lowering it here would let a manager reset the benchmark
        // after a loss and charge fees on merely recovering it.
        if (currentPrice <= hwm) {
            emit HarvestSkipped(currentPrice, hwm);
            return 0;
        }

        // Profit measured per share, then scaled to the whole vault. Doing it per share is
        // what makes the fee immune to deposits and withdrawals: new principal changes
        // `supply` and `totalAssets` together, leaving the price untouched.
        uint256 gainPerShare = currentPrice - hwm;
        // Divide by `_ONE_SHARE_SCALED` rather than `_ONE_SHARE` because `gainPerShare` carries
        // the 1e18 price scale; dividing by the unscaled unit would overstate the gain by 1e18x.
        uint256 totalGain = gainPerShare.mulDiv(supply, _ONE_SHARE_SCALED, Math.Rounding.Floor);

        // 20% of the new profit, rounded down so dust stays with depositors.
        uint256 feeAssets = totalGain.mulDiv(PERFORMANCE_FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Floor);

        if (feeAssets > 0) {
            // Denominator is the asset base *net of the fee*, matching m = f * S / (A - f).
            // `_VIRTUAL_ASSETS`/`_VIRTUAL_SHARES` keep this consistent with every other
            // conversion in the contract. `feeAssets` is at most 20% of `totalGain`, which is
            // itself bounded by the asset base, so the subtraction cannot underflow.
            uint256 assetsAfterFee = totalAssets() + _VIRTUAL_ASSETS - feeAssets;
            feeShares = feeAssets.mulDiv(supply + _VIRTUAL_SHARES, assetsAfterFee, Math.Rounding.Floor);

            if (feeShares > 0) _mint(feeRecipient, feeShares);
        }

        // Re-read the price *after* the dilution. The recipient's shares are backed by real
        // assets, so the post-mint price is the price depositors actually hold from now on,
        // and that is the correct benchmark for the next harvest. Recording the pre-mint price
        // instead would mean the next harvest first has to earn back the dilution — the
        // manager would work for free until the vault recovered a fee it had already taken.
        uint256 newPrice = pricePerShare();

        // Guarded assignment rather than a bare write. Integer rounding inside the mint sizing
        // could in principle leave `newPrice` a wei below `hwm`; the comparison makes
        // "the high-water mark never decreases" true by construction rather than by argument.
        if (newPrice > hwm) highWaterMark = newPrice;

        emit Harvest(msg.sender, feeRecipient, feeShares, feeAssets, highWaterMark);
    }

    // -----------------------------------------------------------------------
    //                                Admin
    // -----------------------------------------------------------------------

    /// @notice Updates the ceiling on `totalAssets()`.
    /// @dev Owner-only. An open setter would let anyone raise the cap to `type(uint256).max`
    ///      and defeat the risk control entirely, or lower it to zero to halt all deposits.
    ///      Lowering below current assets is allowed and simply pauses new deposits; it never
    ///      blocks withdrawals, so it cannot be used to trap depositors.
    /// @param newCap New maximum for `totalAssets()`.
    function setDepositCap(uint256 newCap) external onlyOwner {
        emit DepositCapUpdated(depositCap, newCap);
        depositCap = newCap;
    }

    /// @notice Updates the address that receives performance-fee shares.
    /// @param newRecipient New fee recipient.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        // Minting fee shares to address(0) reverts in ERC20._update, which would make every
        // profitable `harvest()` revert and permanently freeze fee collection.
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    // -----------------------------------------------------------------------
    //                          Internal: conversions
    // -----------------------------------------------------------------------

    /// @dev Assets -> shares, with an explicit rounding direction.
    ///
    ///      shares = assets * (totalSupply + virtualShares) / (totalAssets + virtualAssets)
    ///
    ///      `Math.mulDiv` performs the multiplication in 512 bits, so `assets * totalSupply`
    ///      cannot overflow and truncate even for very large balances — a plain
    ///      `(a * b) / c` would revert on overflow and brick the vault at high TVL.
    ///      The virtual terms guarantee the denominator is never zero, which is what makes
    ///      the very first deposit into an empty vault work without a special case.
    /// @param assets Amount of underlying asset.
    /// @param rounding Direction to round the result.
    /// @return Shares equivalent.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + _VIRTUAL_SHARES, totalAssets() + _VIRTUAL_ASSETS, rounding);
    }

    /// @dev Shares -> assets, the exact inverse ratio of `_convertToShares`.
    ///
    ///      assets = shares * (totalAssets + virtualAssets) / (totalSupply + virtualShares)
    ///
    ///      Using the identical virtual terms on both sides is what keeps deposit and withdraw
    ///      symmetric; mismatched offsets would leak value on every round trip.
    /// @param shares Amount of vault shares.
    /// @param rounding Direction to round the result.
    /// @return Assets equivalent.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + _VIRTUAL_ASSETS, totalSupply() + _VIRTUAL_SHARES, rounding);
    }

    // -----------------------------------------------------------------------
    //                       Internal: entry and exit
    // -----------------------------------------------------------------------

    /// @dev Shared body of `deposit` and `mint`.
    /// @param caller Address paying the assets.
    /// @param receiver Address receiving the shares.
    /// @param assets Amount of asset to pull in.
    /// @param shares Amount of shares to mint.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        // Pull assets *before* minting. If it were the other way round, a token with a
        // transfer hook could re-enter while shares existed that had not yet been paid for.
        // `safeTransferFrom` is mandatory: tokens such as USDT return no boolean at all, and a
        // raw `transferFrom` call would revert on decoding, while some tokens return `false`
        // instead of reverting — a bare call would ignore that and mint shares for free.
        _ASSET.safeTransferFrom(caller, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Shared body of `withdraw` and `redeem`.
    /// @param caller Address initiating the exit.
    /// @param receiver Address receiving the assets.
    /// @param owner Address whose shares are burned.
    /// @param assets Amount of asset to pay out.
    /// @param shares Amount of shares to burn.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        // A third party may only spend shares they have been approved for. Without this check
        // anyone could pass someone else's address as `owner` and drain their position.
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Checks-Effects-Interactions: burn first, pay second. The burn is the state change
        // that makes the position unusable; performing it before the external transfer means a
        // reentrant call sees the already-reduced balance and cannot withdraw twice.
        _burn(owner, shares);

        _ASSET.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    // -----------------------------------------------------------------------
    //                          Internal: utilities
    // -----------------------------------------------------------------------

    /// @dev Reads `decimals()` off the asset without reverting on tokens that do not implement
    ///      it or that return malformed data.
    /// @param asset_ Address of the underlying token.
    /// @return Decimals reported by the token, or 18 if it cannot be determined.
    function _tryGetAssetDecimals(address asset_) private view returns (uint8) {
        // A low-level `staticcall` rather than `try/catch`, because a token that returns data
        // of the wrong length would make an abi-decoding `try` revert rather than fall through.
        (bool success, bytes memory encodedDecimals) = asset_.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));

        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            // Anything above 255 cannot be a real `uint8` decimals value; ignore it rather
            // than truncate, since a truncated value would silently misprice every share.
            // The cast is safe because the branch above proves the value fits in a uint8.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (returnedDecimals <= type(uint8).max) return uint8(returnedDecimals);
        }
        return 18;
    }
}
