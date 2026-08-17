// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FixedVault
/// @author Assignment submission
/// @notice The Task 2 vault with all five bugs fixed. Same external API as `BrokenVault`, so
///         the same test can be pointed at either contract.
/// @dev Every fix carries a `REASON` block naming the bug, the exact exploit it enabled
///      (who calls what, with what numbers, to take whose money), and why the change stops it.
///
///      Summary of the five findings:
///
///      | Bug | Severity | Title                                    |
///      |-----|----------|------------------------------------------|
///      | A   | Critical | Withdraw rounds shares down (1-wei drain)|
///      | B   | Critical | No allowance check on withdraw/redeem    |
///      | C   | Critical | Reentrancy: assets paid out before burn  |
///      | D   | High     | Broken NAV maths in harvest              |
///      | E   | High     | ERC-20 transfer return value ignored     |
contract FixedVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------------
    //                              Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown when a caller tries to move more assets than `owner`'s shares are worth.
    /// @param owner Address whose shares would have been burned.
    /// @param assets Amount requested.
    /// @param max Amount currently available.
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);

    /// @notice Thrown when a caller tries to redeem more shares than `owner` holds.
    /// @param owner Address whose shares would have been burned.
    /// @param shares Amount requested.
    /// @param max Amount currently available.
    error ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    /// @notice Thrown when an operation would move zero shares or zero assets.
    error ZeroAmount();

    // ---------------------------------------------------------------------
    //                              Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on a successful deposit.
    /// @param sender Address that supplied the assets.
    /// @param owner Address that received the shares.
    /// @param assets Underlying taken in.
    /// @param shares Shares minted.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted on a successful exit.
    /// @param sender Address that initiated the exit.
    /// @param receiver Address that received the assets.
    /// @param owner Address whose shares were burned.
    /// @param assets Underlying paid out.
    /// @param shares Shares burned.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Emitted when a performance fee is charged.
    /// @param feeShares Shares minted to the fee recipient.
    /// @param feeAssets Asset value those shares represented.
    /// @param newHighWaterMark The new peak price per share.
    event Harvest(uint256 feeShares, uint256 feeAssets, uint256 newHighWaterMark);

    // ---------------------------------------------------------------------
    //                        Constants and storage
    // ---------------------------------------------------------------------

    /// @notice Performance fee in basis points (20%).
    uint256 public constant PERFORMANCE_FEE_BPS = 2_000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Virtual shares and assets, as in Task 1: they remove the divide-by-zero on an
    ///      empty vault and make the first-depositor inflation attack unprofitable.
    uint256 private constant _VIRTUAL_SHARES = 1_000;

    /// @dev See `_VIRTUAL_SHARES`.
    uint256 private constant _VIRTUAL_ASSETS = 1;

    /// @dev Fixed-point scale for `pricePerShare` and therefore for `highWaterMark`.
    uint256 private constant _PRICE_SCALE = 1e18;

    /// @notice Underlying asset held by the vault.
    address public immutable asset;

    /// @notice Address that receives performance-fee shares.
    address public feeRecipient;

    /// @notice Highest price per share ever recorded, scaled by `_PRICE_SCALE`.
    uint256 public highWaterMark;

    /// @param asset_ Underlying ERC-20.
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    /// @param feeRecipient_ Recipient of performance-fee shares.
    constructor(address asset_, string memory name_, string memory symbol_, address feeRecipient_)
        ERC20(name_, symbol_)
    {
        asset = asset_;
        feeRecipient = feeRecipient_;
        // Seeded to the launch price so the first harvest cannot treat principal as profit.
        highWaterMark = pricePerShare();
    }

    // ---------------------------------------------------------------------
    //                            Accounting
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC20
    /// @dev `_VIRTUAL_SHARES` is `10 ** 3`, which effectively makes shares 1000x more granular
    ///      than the underlying. Reporting the extra three decimals keeps "one whole share is
    ///      worth about one whole asset" true, so `pricePerShare()` and the high-water mark
    ///      stay readable. Leaving `decimals()` at 18 would not be a security bug, but every
    ///      share balance would display 1000x larger than the value it represents.
    function decimals() public view override returns (uint8) {
        return super.decimals() + 3;
    }

    /// @notice Total underlying held by the vault.
    /// @return Assets under management.
    function totalAssets() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice Converts assets to shares, rounding down.
    /// @param assets Amount of underlying.
    /// @return Share equivalent.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Converts shares to assets, rounding down.
    /// @param shares Amount of shares.
    /// @return Asset equivalent.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @notice Shares that would be burned to withdraw `assets`, rounded up.
    /// @param assets Amount of underlying to withdraw.
    /// @return Shares that would be burned.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @notice Assets that redeeming `shares` would return, rounded down.
    /// @param shares Amount of shares to redeem.
    /// @return Assets that would be paid out.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @notice Largest asset amount `owner` can withdraw right now.
    /// @param owner Address whose shares would be burned.
    /// @return Maximum withdrawable assets.
    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    /// @notice Current price of one whole share in asset units, scaled by 1e18.
    /// @return Price per share.
    function pricePerShare() public view returns (uint256) {
        return Math.mulDiv(
            10 ** decimals() * _PRICE_SCALE,
            totalAssets() + _VIRTUAL_ASSETS,
            totalSupply() + _VIRTUAL_SHARES,
            Math.Rounding.Floor
        );
    }

    // ---------------------------------------------------------------------
    //                              Deposit
    // ---------------------------------------------------------------------

    /// @notice Deposits `assets` and mints shares to `receiver`.
    /// @param assets Amount of underlying to pull from the caller.
    /// @param receiver Address that receives the shares.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();

        // REASON — BUG E FIX (part 1 of 3): UNCHECKED ERC-20 RETURN VALUE.
        //
        // Bug name:  Unchecked transfer / non-standard ERC-20 incompatibility.
        // Exploit:   The original wrote `IERC20(asset).transferFrom(...)` and discarded the
        //            boolean. Tokens such as ZRX and BAT return `false` on failure instead of
        //            reverting, so an attacker calls `deposit(1_000_000e18, attacker)` from an
        //            account with no balance; `transferFrom` returns false, execution
        //            continues, and `_mint` credits them 1,000,000 shares paid for with
        //            nothing. They then redeem those shares against everyone else's deposits.
        //            The mirror problem is USDT, which returns no data at all: the compiler's
        //            ABI decoder reverts on the missing boolean, making the vault unusable.
        // Why fixed: `safeTransferFrom` reverts unless the call succeeded AND either returned
        //            nothing or returned `true`. Both the silent-false and the no-return cases
        //            are handled, so no share is ever minted without payment.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ---------------------------------------------------------------------
    //                          Withdraw / redeem
    // ---------------------------------------------------------------------

    /// @notice Burns shares from `owner` and sends exactly `assets` to `receiver`.
    /// @param assets Amount of underlying to send out.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        uint256 max = maxWithdraw(owner);
        if (assets > max) revert ExceededMaxWithdraw(owner, assets, max);

        // REASON — BUG A FIX: ROUNDING DIRECTION IN WITHDRAW (the 1-wei drain).
        //
        // Bug name:  Truncating share calculation on exit.
        // Exploit:   `convertToShares` rounds down. Take a vault holding 2,000e18 assets
        //            against 1,000e18 shares, i.e. one share is worth two asset units. Any
        //            address — including one that has never deposited and holds zero shares —
        //            calls `withdraw(1, attacker, attacker)`. The vault computes
        //            `1 * 1000e18 / 2000e18 = 0` shares, calls `_burn(attacker, 0)` which
        //            succeeds trivially against a zero balance, and transfers 1 wei out.
        //            Nothing was paid and nothing was burned. The attacker puts that call in a
        //            loop and drains the vault one wei per iteration, at roughly 30k gas each,
        //            entirely funded by the other depositors.
        // Why fixed: `previewWithdraw` uses `Math.Rounding.Ceil`, so any non-zero asset amount
        //            always costs at least one share. `_burn` on an attacker with no shares
        //            now reverts, and the `maxWithdraw` check above rejects it even earlier
        //            with a named error. The rounding remainder is retained by the vault, so
        //            the exchange rate moves in the depositors' favour rather than leaking.
        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroAmount();

        _exit(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Burns exactly `shares` from `owner` and sends the assets to `receiver`.
    /// @param shares Amount of shares to burn.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return assets Assets sent out.
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        uint256 max = balanceOf(owner);
        if (shares > max) revert ExceededMaxRedeem(owner, shares, max);

        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAmount();

        _exit(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Shared exit path for `withdraw` and `redeem`. Both bugs B and C are fixed here, in
    ///      one place, so the two entry points cannot drift apart later.
    /// @param caller Address that initiated the exit.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @param assets Assets to pay out.
    /// @param shares Shares to burn.
    function _exit(address caller, address receiver, address owner, uint256 assets, uint256 shares) private {
        // REASON — BUG B FIX: MISSING ALLOWANCE CHECK ON THIRD-PARTY EXITS.
        //
        // Bug name:  Broken access control on `owner` (unauthorised share burn).
        // Exploit:   Both original functions accepted `owner` as a free parameter and never
        //            related it to `msg.sender`. Alice deposits 1,000e18 and holds 1,000e18
        //            shares. The attacker calls
        //            `redeem(1000e18, attackerAddress, aliceAddress)`. The vault reads Alice's
        //            balance, sends 1,000e18 of the underlying to the attacker, and burns
        //            Alice's shares. No approval, no signature, no relationship to the
        //            attacker at all. Repeating this against every holder empties the vault in
        //            one block; it is a direct, unconditional theft of the entire TVL.
        // Why fixed: A third party must now hold an ERC-20 allowance over the owner's shares,
        //            and `_spendAllowance` deducts it (reverting on insufficient allowance).
        //            This makes vault exits obey exactly the same authorisation rules as
        //            `transferFrom` on the share token, which is what integrators and the
        //            ERC-4626 standard expect. Self-exits skip the check, so the normal path
        //            costs no extra gas and needs no self-approval.
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // REASON — BUG C FIX: REENTRANCY VIA CHECKS-EFFECTS-INTERACTIONS VIOLATION.
        //
        // Bug name:  Reentrancy in `redeem` (payout before state update).
        // Exploit:   The original `redeem` transferred the assets and only then burned the
        //            shares. With a callback-bearing asset (ERC-777, or any token with a
        //            transfer hook) the receiver gets control back in between, at a moment
        //            when the vault has already paid out but `totalSupply` and the attacker's
        //            share balance are both still un-reduced. Concretely, with the vault at
        //            1,000e18 assets / 1,000e18 shares and the attacker holding 100e18 shares:
        //              1. Attacker calls `redeem(100e18, attacker, attacker)`.
        //              2. Vault sends 100e18 assets. Vault now holds 900e18 assets but still
        //                 reports 1,000e18 shares outstanding.
        //              3. The token's `tokensReceived` hook fires on the attacker, who calls
        //                 `deposit(100e18)` right back — paying with the very assets they were
        //                 just sent. The vault prices that deposit off the deflated balance:
        //                 `100e18 * 1000e18 / 900e18 = 111.1e18` shares instead of 100e18.
        //              4. The outer call finally burns 100e18 shares, leaving the attacker
        //                 with 111.1e18 shares against a vault that is back to 1,000e18 assets.
        //              5. The attacker redeems and walks away with ~109.9e18 for the 100e18
        //                 they started with. The extra ~9.9e18 comes straight out of the other
        //                 depositors' claims.
        // Why fixed: Two independent layers.
        //            (1) Checks-Effects-Interactions: `_burn` now happens BEFORE the transfer,
        //                so by the time any hook can run, `totalSupply` and the attacker's
        //                balance already reflect the exit and every price the vault quotes is
        //                correct. This alone removes the mispricing.
        //            (2) `nonReentrant` on all four external entry points, so the re-entrant
        //                `deposit` reverts outright rather than merely being priced correctly.
        //                Defence in depth: the guard also covers future code paths that a
        //                later maintainer might add without re-deriving the CEI argument.
        _burn(owner, shares);

        // REASON — BUG E FIX (part 2 of 3): UNCHECKED ERC-20 RETURN VALUE ON THE PAYOUT.
        //
        // Bug name:  Unchecked transfer on exit.
        // Exploit:   The original ignored the boolean from `transfer`. With a token that
        //            returns `false` instead of reverting — or one that has been paused, or
        //            has blacklisted the receiver, as USDC can — the call "succeeds", the
        //            user's shares are burned, and no assets ever arrive. The burned shares
        //            are gone permanently and their value is silently redistributed to the
        //            remaining holders. The user has no way to recover and no error to point
        //            at. The reverse case, USDT returning no data, makes the vault revert on
        //            every single withdrawal and permanently locks all deposits.
        // Why fixed: `safeTransfer` bubbles up a revert unless the transfer genuinely
        //            succeeded, so a failed payout undoes the burn atomically. It also accepts
        //            tokens that return no data, so non-standard assets work correctly instead
        //            of bricking the vault.
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    // ---------------------------------------------------------------------
    //                              Harvest
    // ---------------------------------------------------------------------

    /// @notice Charges the 20% performance fee on profit above the all-time peak price
    ///         per share, minting the fee to `feeRecipient`.
    /// @return feeShares Shares minted as the fee (zero if there is no new peak).
    function harvest() external nonReentrant returns (uint256 feeShares) {
        // REASON — BUG D FIX: BROKEN NAV MATHS IN HARVEST.
        //
        // Bug name:  Integer-division NAV, division by zero, and a units mismatch.
        // Exploit / impact — the original line `uint256 nav = totalAssets() / totalSupply();`
        // carried three separate defects:
        //
        //   D1. DIVISION BY ZERO -> PERMANENT DENIAL OF SERVICE.
        //       On an empty vault `totalSupply()` is 0 and `harvest()` reverts with a panic.
        //       Any keeper, automation job or batched multicall that includes `harvest()`
        //       breaks the moment the last depositor exits. An attacker who wants to grief the
        //       fee recipient simply waits for, or engineers, an empty vault.
        //
        //   D2. TRUNCATION -> THE FEE IS EITHER ZERO OR ENORMOUS.
        //       For an 18-decimal asset the true NAV per share is ~1.0, and integer division
        //       floors it to the integer `1`. A vault that doubles its money goes from
        //       `nav == 1` to `nav == 2`, so a 99% gain is charged nothing at all, and then
        //       crossing 100% is charged as if a whole unit of profit had appeared. The fee
        //       bears no relation to performance in either direction.
        //
        //   D3. UNITS MISMATCH -> ARBITRARY DILUTION.
        //       `nav` is a price. `fee = (nav - highWaterMark) * 20 / 100` is therefore also a
        //       price, but the result is passed to `_mint` as a share COUNT. The two have
        //       nothing to do with each other. With a 6-decimal asset such as USDC, `nav`
        //       reaches ~1e12 once share supply is small relative to assets, so a single
        //       `harvest()` mints ~2e11 shares to `feeRecipient` — potentially more than the
        //       entire legitimate supply, handing them the whole vault. `harvest()` is
        //       permissionless, so anyone can trigger it on the fee recipient's behalf.
        //
        // Why fixed: the rewrite below
        //   - returns early when `totalSupply() == 0`, so an empty vault is a no-op (D1);
        //   - measures NAV through `pricePerShare()`, which is scaled by 1e18 on top of the
        //     asset's own decimals, so a 0.0001% move is still visible (D2);
        //   - converts the per-share gain into an actual ASSET amount, takes 20% of that, and
        //     only then converts the asset amount into the share count that is worth it —
        //     every step now has consistent units (D3);
        //   - sizes the mint as `f * S / (A - f)` so the recipient's shares are worth the fee
        //     AFTER the dilution they themselves cause; and
        //   - records the post-mint price as the new peak, and only ever raises it.
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 currentPrice = pricePerShare();
        uint256 hwm = highWaterMark;
        if (currentPrice <= hwm) return 0;

        uint256 oneShareScaled = 10 ** decimals() * _PRICE_SCALE;

        // Per-share gain -> total gain in asset units -> 20% of it.
        uint256 totalGain = (currentPrice - hwm).mulDiv(supply, oneShareScaled, Math.Rounding.Floor);
        uint256 feeAssets = totalGain.mulDiv(PERFORMANCE_FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Floor);

        if (feeAssets > 0) {
            uint256 assetsAfterFee = totalAssets() + _VIRTUAL_ASSETS - feeAssets;
            feeShares = feeAssets.mulDiv(supply + _VIRTUAL_SHARES, assetsAfterFee, Math.Rounding.Floor);
            if (feeShares > 0) _mint(feeRecipient, feeShares);
        }

        uint256 newPrice = pricePerShare();
        if (newPrice > hwm) highWaterMark = newPrice;

        emit Harvest(feeShares, feeAssets, highWaterMark);
    }

    // ---------------------------------------------------------------------
    //                        Internal conversions
    // ---------------------------------------------------------------------

    /// @dev assets -> shares with an explicit rounding direction.
    ///
    ///      REASON — BUG A/E FIX (part 3 of 3): OVERFLOW-SAFE, ZERO-SAFE CONVERSION.
    ///      The original `(assets * supply) / totalAssets()` had two further latent failures:
    ///      the product overflows and reverts at high TVL, permanently bricking deposits and
    ///      withdrawals; and it needs a hand-written `supply == 0` special case, which is
    ///      exactly the branch the first-depositor inflation attack targets. `Math.mulDiv`
    ///      computes the product in 512 bits so it cannot overflow, and the virtual
    ///      shares/assets keep the denominator non-zero without a special case.
    /// @param assets Amount of underlying.
    /// @param rounding Direction to round.
    /// @return Share equivalent.
    function _convertToShares(uint256 assets, Math.Rounding rounding) private view returns (uint256) {
        return assets.mulDiv(totalSupply() + _VIRTUAL_SHARES, totalAssets() + _VIRTUAL_ASSETS, rounding);
    }

    /// @dev shares -> assets with an explicit rounding direction.
    /// @param shares Amount of shares.
    /// @param rounding Direction to round.
    /// @return Asset equivalent.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) private view returns (uint256) {
        return shares.mulDiv(totalAssets() + _VIRTUAL_ASSETS, totalSupply() + _VIRTUAL_SHARES, rounding);
    }
}
