// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IERC4626
/// @author Assignment submission
/// @notice The full EIP-4626 Tokenized Vault Standard interface, transcribed by hand.
/// @dev The assignment forbids inheriting OpenZeppelin's `ERC4626` implementation, so the
///      interface is declared here rather than imported from OZ. Every function below is
///      mandatory under EIP-4626 — integrators (aggregators, routers, front-ends) call
///      these by selector, so omitting any one of them silently breaks composability even
///      though the contract would still compile.
///
///      Rounding rules are part of the standard, not a style choice. The rule is always
///      "round in the direction that favours the vault", because the opposite direction
///      lets a caller extract a wei of value per call and repeat it forever.
interface IERC4626 is IERC20, IERC20Metadata {
    // ---------------------------------------------------------------------
    //                                Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when assets are deposited and shares minted.
    /// @param sender Address that supplied the assets.
    /// @param owner Address that received the shares.
    /// @param assets Amount of underlying asset taken in.
    /// @param shares Amount of vault shares minted.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when shares are burned and assets paid out.
    /// @param sender Address that initiated the exit.
    /// @param receiver Address that received the assets.
    /// @param owner Address whose shares were burned.
    /// @param assets Amount of underlying asset paid out.
    /// @param shares Amount of vault shares burned.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    // ---------------------------------------------------------------------
    //                          Asset & accounting
    // ---------------------------------------------------------------------

    /// @notice Address of the underlying ERC-20 the vault accepts and pays out.
    /// @return assetTokenAddress The underlying asset contract address.
    function asset() external view returns (address assetTokenAddress);

    /// @notice Total amount of underlying asset the vault manages on behalf of shareholders.
    /// @return totalManagedAssets Total assets under management, in asset units.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Converts an asset amount to the share amount it is currently worth.
    /// @dev Ideal-conditions quote: ignores caps, fees and slippage. Rounds down.
    /// @param assets Amount of underlying asset.
    /// @return shares Equivalent amount of shares.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts a share amount to the asset amount it is currently worth.
    /// @dev Ideal-conditions quote: ignores caps, fees and slippage. Rounds down.
    /// @param shares Amount of vault shares.
    /// @return assets Equivalent amount of underlying asset.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    // ---------------------------------------------------------------------
    //                          Deposit / mint
    // ---------------------------------------------------------------------

    /// @notice Maximum assets `receiver` may currently deposit without reverting.
    /// @param receiver Address that would receive the shares.
    /// @return maxAssets Upper bound on the `assets` argument of `deposit`.
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Simulates the shares that a `deposit` of `assets` would mint right now.
    /// @param assets Amount of underlying asset to be deposited.
    /// @return shares Shares that would be minted.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Deposits `assets` of underlying and mints shares to `receiver`.
    /// @param assets Amount of underlying asset to pull from the caller.
    /// @param receiver Address that receives the newly minted shares.
    /// @return shares Amount of shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Maximum shares `receiver` may currently mint without reverting.
    /// @param receiver Address that would receive the shares.
    /// @return maxShares Upper bound on the `shares` argument of `mint`.
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Simulates the assets that minting `shares` would cost right now.
    /// @param shares Amount of shares to be minted.
    /// @return assets Assets the caller would pay.
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Mints exactly `shares` to `receiver`, pulling the required assets from the caller.
    /// @param shares Exact amount of shares to mint.
    /// @param receiver Address that receives the newly minted shares.
    /// @return assets Amount of underlying asset pulled from the caller.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    // ---------------------------------------------------------------------
    //                          Withdraw / redeem
    // ---------------------------------------------------------------------

    /// @notice Maximum assets `owner` can currently withdraw.
    /// @param owner Address whose shares would be burned.
    /// @return maxAssets Upper bound on the `assets` argument of `withdraw`.
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Simulates the shares that withdrawing `assets` would burn right now.
    /// @dev Must round **up**: the vault must never hand out assets for too few shares.
    /// @param assets Amount of underlying asset to be withdrawn.
    /// @return shares Shares that would be burned.
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Burns shares from `owner` and sends exactly `assets` to `receiver`.
    /// @param assets Exact amount of underlying asset to send out.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return shares Amount of shares burned.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Maximum shares `owner` can currently redeem.
    /// @param owner Address whose shares would be burned.
    /// @return maxShares Upper bound on the `shares` argument of `redeem`.
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Simulates the assets that redeeming `shares` would return right now.
    /// @dev Must round **down**: the vault must never pay out more than the shares are worth.
    /// @param shares Amount of shares to be redeemed.
    /// @return assets Assets that would be paid out.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Burns exactly `shares` from `owner` and sends the resulting assets to `receiver`.
    /// @param shares Exact amount of shares to burn.
    /// @param receiver Address that receives the assets.
    /// @param owner Address whose shares are burned.
    /// @return assets Amount of underlying asset sent out.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
