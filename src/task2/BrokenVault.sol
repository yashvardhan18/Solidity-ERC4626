// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BrokenVault
/// @author Assignment submission
/// @notice The vulnerable ERC-4626 vault from Task 2, kept intact so the exploits can be run
///         against it in tests. **Never deploy this.**
/// @dev The three functions given in the assignment (`withdraw`, `redeem`, `harvest`) are
///      reproduced character-for-character. The surrounding scaffolding (`deposit`,
///      `totalAssets`, the two converters) is the minimum needed to make the contract
///      compile and hold funds, and is written the way a naive implementation would be —
///      it is not the source of any of the five bugs.
///
///      The five bugs are marked `BUG A` ... `BUG E` at the exact lines that carry them.
///      Each one is fixed, with a full REASON block, in `FixedVault.sol`.
///
///      | Bug | Location            | One-line summary                                        |
///      |-----|---------------------|---------------------------------------------------------|
///      | A   | `withdraw`          | Share count rounds down, so small withdrawals are free   |
///      | B   | `withdraw`/`redeem` | No allowance check, so anyone can burn anyone's shares   |
///      | C   | `redeem`            | Pays out before burning, so the payout can be re-entered |
///      | D   | `harvest`           | NAV maths divides by zero, truncates, and mixes units    |
///      | E   | both exits          | `transfer` return value ignored, so failures are silent  |
contract BrokenVault is ERC20 {
    /// @notice Underlying asset held by the vault.
    address public immutable asset;

    /// @notice Address that receives performance-fee shares.
    address public feeRecipient;

    /// @notice Highest NAV per share seen so far, as computed by the broken `harvest`.
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
    }

    /// @notice Total underlying held by the vault.
    /// @return Assets under management.
    function totalAssets() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice Converts assets to shares at the current exchange rate, rounding down.
    /// @param assets Amount of underlying.
    /// @return Share equivalent.
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    /// @notice Converts shares to assets at the current exchange rate, rounding down.
    /// @param shares Amount of shares.
    /// @return Asset equivalent.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    /// @notice Deposits `assets` and mints shares to `receiver`.
    /// @param assets Amount of underlying to pull from the caller.
    /// @param receiver Address that receives the shares.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    // =====================================================================
    //   The three functions exactly as supplied in the assignment.
    // =====================================================================

    /// @notice Burns shares from `owner` and sends `assets` to `receiver`.
    /// @param assets Amount of underlying to send out.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        // BUG A - ROUNDING DIRECTION.
        // `convertToShares` divides and truncates. Whenever one share is worth more than one
        // asset unit, a small `assets` value maps to ZERO shares, and the caller is paid for
        // free. Repeat in a loop and the vault is drained.
        //
        // BUG B - MISSING ALLOWANCE CHECK.
        // `owner` is an unvalidated parameter. `msg.sender` is never compared against it and
        // no allowance is ever spent, so any address can name a victim as `owner`, burn the
        // victim's shares, and take the assets.
        shares = convertToShares(assets);
        _burn(owner, shares);

        // BUG E - UNCHECKED TRANSFER RETURN VALUE.
        // The boolean is discarded. Tokens that return `false` on failure instead of
        // reverting let this function "succeed" having paid out nothing.
        IERC20(asset).transfer(receiver, assets);
    }

    /// @notice Burns `shares` from `owner` and sends the resulting assets to `receiver`.
    /// @param shares Amount of shares to burn.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return assets Assets sent out.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);

        // BUG C - REENTRANCY / CHECKS-EFFECTS-INTERACTIONS VIOLATION.
        // The external transfer happens BEFORE `_burn`. With a callback-bearing asset such as
        // ERC-777, the receiver regains control while the vault's books still show the shares
        // as outstanding and `totalSupply` still includes them, even though the assets backing
        // them have already left. Every price the vault quotes inside that window is wrong.
        //
        // BUG B (again) - no allowance is spent here either.
        //
        // BUG E (again) - the return value is discarded.
        IERC20(asset).transfer(receiver, assets);
        _burn(owner, shares);
    }

    /// @notice Charges a performance fee when NAV per share exceeds the high-water mark.
    function harvest() external {
        // BUG D - BROKEN NAV MATHS. Three distinct defects in one line-and-a-half:
        //
        //   1. Division by zero. `totalSupply()` is zero on an empty vault, so `harvest()`
        //      reverts instead of no-opping.
        //   2. Total precision loss. Integer division of two 18-decimal numbers collapses the
        //      NAV per share to a bare integer: a vault at 1.0 and a vault at 1.99 both report
        //      `nav == 1`, so a 99% gain earns no fee at all.
        //   3. Unit mismatch. `nav` is a price ratio, but the result of the fee formula is
        //      minted as a share COUNT. The number of shares minted has no relationship to the
        //      profit actually earned.
        uint256 nav = totalAssets() / totalSupply();
        if (nav > highWaterMark) {
            uint256 fee = (nav - highWaterMark) * 20 / 100;
            _mint(feeRecipient, fee);
            highWaterMark = nav;
        }
    }
}
