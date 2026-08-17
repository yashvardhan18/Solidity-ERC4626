// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HighWaterMarkVault} from "../../src/task1/HighWaterMarkVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @title HighWaterMarkVaultTest
/// @author Assignment submission
/// @notice Task 1 test suite: exactly the tests specified in the assignment.
/// @dev Required:
///        - testFuzz_sharesNeverExceedAssets(uint96): a user cannot withdraw more than
///          they deposited.
///        - harvest() charges fee when NAV > HWM, skips when NAV < HWM, HWM never decreases.
///        - deposit reverts when depositCap is breached.
contract HighWaterMarkVaultTest is Test {
    MockERC20 internal asset;
    HighWaterMarkVault internal vault;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");

    /// @dev Uncapped by default so tests unrelated to the cap are never constrained by it.
    uint256 internal constant CAP = type(uint256).max;

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new HighWaterMarkVault(IERC20(address(asset)), "Vault mUSD", "vmUSD", owner, feeRecipient, CAP);

        _fund(alice, 1_000_000e18);
    }

    /// @dev Mints `amount` to `who` and approves the vault for the full balance.
    function _fund(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @dev Simulates strategy profit by sending assets straight into the vault. Because
    ///      `totalAssets()` is the vault's token balance, this raises NAV per share exactly
    ///      as a real yield-bearing strategy would.
    function _simulateYield(uint256 amount) internal {
        asset.mint(address(vault), amount);
    }

    /// @dev Simulates a strategy loss by burning assets out of the vault.
    function _simulateLoss(uint256 amount) internal {
        asset.burn(address(vault), amount);
    }

    // =====================================================================
    //  REQUIRED FUZZ TEST
    //  "a user cannot withdraw more than they deposited"
    // =====================================================================

    /// @notice A deposit followed immediately by a full exit can never return more asset than
    ///         went in.
    /// @dev Holds because `previewDeposit` rounds shares down and `previewRedeem` rounds
    ///      assets down, so every rounding remainder is retained by the vault rather than
    ///      handed to the caller.
    /// @param assets Fuzzed deposit size (uint96 keeps it inside a realistic token supply).
    function testFuzz_sharesNeverExceedAssets(uint96 assets) public {
        vm.assume(assets > 0);

        uint256 depositAmount = uint256(assets);
        _fund(alice, depositAmount);

        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertLe(assetsOut, depositAmount, "round trip returned more assets than were deposited");
        assertLe(asset.balanceOf(alice), balanceBefore, "user token balance grew across a round trip");
    }

    // =====================================================================
    //  REQUIRED UNIT TESTS - harvest() / high-water mark
    // =====================================================================

    /// @notice `harvest()` charges the 20% fee when NAV per share rises above the HWM.
    function test_harvest_chargesFeeWhenNavAboveHighWaterMark() public {
        uint256 principal = 1_000e18;
        vm.prank(alice);
        vault.deposit(principal, alice);

        uint256 hwmBefore = vault.highWaterMark();

        uint256 profit = 100e18;
        _simulateYield(profit);

        assertGt(vault.pricePerShare(), hwmBefore, "yield did not raise NAV per share");
        assertEq(vault.balanceOf(feeRecipient), 0, "fee recipient held shares before harvest");

        uint256 feeShares = vault.harvest();

        assertGt(feeShares, 0, "harvest minted no fee shares despite a new peak");

        uint256 expectedFeeAssets = (profit * 2_000) / 10_000;
        assertApproxEqAbs(
            vault.maxWithdraw(feeRecipient), expectedFeeAssets, 1e6, "performance fee is not 20% of the gain"
        );
        assertGt(vault.highWaterMark(), hwmBefore, "high-water mark did not advance after a profitable harvest");
    }

    /// @notice `harvest()` charges nothing while NAV per share is below the high-water mark.
    function test_harvest_skipsFeeWhenNavBelowHighWaterMark() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        _simulateYield(100e18);
        vault.harvest();
        uint256 peak = vault.highWaterMark();
        uint256 feeSharesAfterFirstHarvest = vault.balanceOf(feeRecipient);

        _simulateLoss(200e18);
        assertLt(vault.pricePerShare(), peak, "loss did not push NAV below the peak");

        uint256 feeShares = vault.harvest();

        assertEq(feeShares, 0, "fee charged while under water");
        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirstHarvest, "fee recipient share balance changed");
        assertEq(vault.highWaterMark(), peak, "high-water mark moved on a losing harvest");
    }

    /// @notice The high-water mark is monotonically non-decreasing across a full profit / loss
    ///         / recovery cycle.
    function test_harvest_highWaterMarkNeverDecreases() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        uint256[] memory marks = new uint256[](5);
        marks[0] = vault.highWaterMark();

        // 1. Profit -> fee charged, peak rises.
        _simulateYield(200e18);
        vault.harvest();
        marks[1] = vault.highWaterMark();

        // 2. Loss -> no fee, peak held.
        _simulateLoss(150e18);
        vault.harvest();
        marks[2] = vault.highWaterMark();

        // 3. Partial recovery, still under the peak -> no fee, peak held.
        _simulateYield(100e18);
        vault.harvest();
        marks[3] = vault.highWaterMark();

        // 4. Push clearly above the old peak -> fee on the excess only.
        _simulateYield(300e18);
        uint256 feeSharesFinal = vault.harvest();
        marks[4] = vault.highWaterMark();

        for (uint256 i = 1; i < marks.length; i++) {
            assertGe(marks[i], marks[i - 1], "high-water mark decreased between harvests");
        }

        assertEq(marks[2], marks[1], "peak moved during a loss");
        assertEq(marks[3], marks[1], "peak moved during a partial recovery below the peak");
        assertGt(marks[4], marks[1], "peak did not advance on a genuine new high");
        assertGt(feeSharesFinal, 0, "no fee charged on a genuine new high");
    }

    // =====================================================================
    //  REQUIRED UNIT TEST - deposit cap
    // =====================================================================

    /// @notice A deposit that would push `totalAssets()` past the cap reverts with the custom
    ///         error, and one that lands exactly on the cap succeeds.
    function test_deposit_revertsWhenCapBreached() public {
        uint256 cap = 1_000e18;
        vm.prank(owner);
        vault.setDepositCap(cap);

        vm.prank(alice);
        vault.deposit(cap, alice);
        assertEq(vault.totalAssets(), cap, "deposit up to the cap did not go through");

        address bob = makeAddr("bob");
        _fund(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HighWaterMarkVault.ExceededMaxDeposit.selector, bob, 1, 0));
        vault.deposit(1, bob);
    }
}
