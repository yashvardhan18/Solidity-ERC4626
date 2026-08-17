// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrokenVault} from "../../src/task2/BrokenVault.sol";
import {FixedVault} from "../../src/task2/FixedVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockERC777} from "../../src/mocks/MockERC777.sol";
import {ReentrancyAttacker, IVaultLike} from "../../src/mocks/ReentrancyAttacker.sol";

/// @title Task2VaultTest
/// @author Assignment submission
/// @notice Task 2 test suite: exactly the tests specified in the assignment.
/// @dev Required:
///        - testFuzz_cannotWithdrawMoreThanDeposited(uint96): vm.assume(assets > 0), 10,000
///          runs.
///        - A mock ERC-777 receiver that exploits Bug C before the fix, actually
///          double-withdrawing. Shown failing after the fix.
///        - Bug A numeric proof: the 1-wei drain works before the fix, reverts after.
contract Task2VaultTest is Test {
    MockERC20 internal asset;
    BrokenVault internal broken;
    FixedVault internal fixedVault;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        broken = new BrokenVault(address(asset), "Broken Vault", "bVLT", feeRecipient);
        fixedVault = new FixedVault(address(asset), "Fixed Vault", "fVLT", feeRecipient);

        _fund(alice);
        _fund(bob);
        _fund(attacker);
    }

    /// @dev Mints a large balance to `who` and approves both vaults.
    function _fund(address who) internal {
        asset.mint(who, 10_000_000e18);
        vm.startPrank(who);
        asset.approve(address(broken), type(uint256).max);
        asset.approve(address(fixedVault), type(uint256).max);
        vm.stopPrank();
    }

    // =====================================================================
    //  REQUIRED FUZZ TEST
    // =====================================================================

    /// @notice A user can never take out more of the underlying than they put in.
    /// @dev Run against the FIXED vault: this is the property the fixes are supposed to
    ///      restore.
    /// @param assets Fuzzed deposit size.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_cannotWithdrawMoreThanDeposited(uint96 assets) public {
        vm.assume(assets > 0);

        uint256 depositAmount = uint256(assets);
        asset.mint(alice, depositAmount);

        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 shares = fixedVault.deposit(depositAmount, alice);

        vm.prank(alice);
        uint256 assetsOut = fixedVault.redeem(shares, alice, alice);

        assertLe(assetsOut, depositAmount, "withdrew more than deposited");
        assertLe(asset.balanceOf(alice), balanceBefore, "token balance grew across a round trip");
    }

    // =====================================================================
    //  BUG C - REENTRANCY (assets transferred before shares burned)
    //  Required: a mock ERC-777 receiver that ACTUALLY double-withdraws.
    // =====================================================================

    /// @notice The ERC-777 reentrancy exploit succeeds against the broken vault and the
    ///         attacker walks away with roughly 10% more than they put in.
    /// @dev Full mechanism is documented on `ReentrancyAttacker`. In short: `redeem` pays out
    ///      before it burns, so during the `tokensReceived` callback the vault holds 900e18
    ///      assets while still reporting 1,000e18 shares outstanding. The attacker deposits the
    ///      assets it was just paid at that fake 0.9 price, mints 111.1e18 shares instead of
    ///      100e18, and the outer burn only removes 100e18 of them.
    function test_bugC_erc777ReentrancyDrainsBrokenVault() public {
        MockERC777 token = new MockERC777("Reentrant Token", "R777");
        BrokenVault vault = new BrokenVault(address(token), "Broken 777 Vault", "b777", feeRecipient);

        token.mint(bob, 900e18);
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(900e18, bob);
        vm.stopPrank();

        ReentrancyAttacker exploit = new ReentrancyAttacker(IVaultLike(address(vault)), IERC20(address(token)));
        token.mint(address(exploit), 100e18);
        exploit.openPosition(100e18);

        token.setHookEnabled(address(exploit), true);

        assertEq(vault.totalAssets(), 1_000e18, "unexpected vault assets before the attack");
        assertEq(vault.totalSupply(), 1_000e18, "unexpected vault supply before the attack");
        assertEq(vault.balanceOf(address(exploit)), 100e18, "attacker position not opened");

        uint256 honestClaimBefore = vault.convertToAssets(vault.balanceOf(bob));

        // Fire the exploit, then cash out the shares it manufactured.
        exploit.attack(100e18);
        exploit.cashOut();

        uint256 stolen = token.balanceOf(address(exploit));

        // The smoking gun recorded during the callback: the vault had already paid out
        // 100e18 assets while still crediting the attacker with all 100e18 shares - a genuine
        // double-withdraw.
        assertEq(exploit.assetsReceivedDuringCallback(), 100e18, "callback did not observe a payout");
        assertEq(exploit.shareBalanceDuringCallback(), 100e18, "shares were already burned during the callback");

        assertGt(stolen, 100e18, "exploit did not turn a profit");
        assertApproxEqAbs(stolen, 109.89e18, 0.01e18, "profit differs from the predicted amount");

        uint256 honestClaimAfter = vault.convertToAssets(vault.balanceOf(bob));
        assertLt(honestClaimAfter, honestClaimBefore, "honest depositor was not the one who paid");
    }

    /// @notice The identical exploit contract fails against the fixed vault.
    /// @dev Two independent reasons: `_burn` happens before the transfer so the price during
    ///      the callback is correct, and `nonReentrant` rejects the nested `deposit` outright.
    function test_bugC_erc777ReentrancyFailsOnFixedVault() public {
        MockERC777 token = new MockERC777("Reentrant Token", "R777");
        FixedVault vault = new FixedVault(address(token), "Fixed 777 Vault", "f777", feeRecipient);

        token.mint(bob, 900e18);
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(900e18, bob);
        vm.stopPrank();

        ReentrancyAttacker exploit = new ReentrancyAttacker(IVaultLike(address(vault)), IERC20(address(token)));
        token.mint(address(exploit), 100e18);
        exploit.openPosition(100e18);

        token.setHookEnabled(address(exploit), true);

        uint256 honestClaimBefore = vault.convertToAssets(vault.balanceOf(bob));
        uint256 attackerSharesBefore = vault.balanceOf(address(exploit));p

        vm.expectRevert();
        exploit.attack(attackerSharesBefore);

        assertEq(token.balanceOf(address(exploit)), 0, "attacker extracted assets");
        assertEq(vault.balanceOf(address(exploit)), attackerSharesBefore, "attacker's share balance changed");
        assertEq(vault.convertToAssets(vault.balanceOf(bob)), honestClaimBefore, "honest depositor's claim was reduced");
    }

    // =====================================================================
    //  BUG A - ROUNDING DIRECTION IN withdraw()  (1-wei drain)
    //  Required: numeric proof - works before fix, reverts after.
    // =====================================================================

    /// @notice Numeric proof that the 1-wei drain works on the broken vault.
    /// @dev The setup is a vault where one share is worth exactly two asset units, which makes
    ///      `convertToShares(1) == 0` by truncation. The attacker holds NO shares at all and
    ///      still gets paid, because `_burn(attacker, 0)` succeeds against a zero balance.
    function test_bugA_oneWeiDrainWorksOnBrokenVault() public {
        vm.prank(alice);
        broken.deposit(1_000e18, alice);

        asset.mint(address(broken), 1_000e18);

        assertEq(broken.totalAssets(), 2_000e18, "unexpected asset balance");
        assertEq(broken.totalSupply(), 1_000e18, "unexpected share supply");
        assertEq(broken.convertToShares(1), 0, "precondition for the drain does not hold");

        uint256 attackerAssetsBefore = asset.balanceOf(attacker);
        uint256 vaultAssetsBefore = broken.totalAssets();
        assertEq(broken.balanceOf(attacker), 0, "attacker should start with no shares");

        uint256 iterations = 1_000;
        vm.startPrank(attacker);
        for (uint256 i = 0; i < iterations; i++) {
            broken.withdraw(1, attacker, attacker);
        }
        vm.stopPrank();

        assertEq(asset.balanceOf(attacker) - attackerAssetsBefore, iterations, "drain did not pay out");
        assertEq(vaultAssetsBefore - broken.totalAssets(), iterations, "vault did not lose the assets");
        assertEq(broken.balanceOf(attacker), 0, "attacker paid for the drain with shares");
        assertEq(broken.totalSupply(), 1_000e18, "no shares were burned - the payout was free");
    }

    /// @notice The identical sequence reverts on the fixed vault.
    /// @dev `previewWithdraw` now rounds up, so one wei costs at least one share, and the
    ///      `maxWithdraw` check rejects a zero-share caller before that with a named error.
    function test_bugA_oneWeiDrainRevertsOnFixedVault() public {
        vm.prank(alice);
        fixedVault.deposit(1_000e18, alice);

        uint256 priceBefore = fixedVault.pricePerShare();
        asset.mint(address(fixedVault), 1_000e18);

        assertApproxEqRel(fixedVault.pricePerShare(), priceBefore * 2, 0.001e18, "precondition: price should double");
        assertGe(fixedVault.previewWithdraw(1), 1, "previewWithdraw still rounds down");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FixedVault.ExceededMaxWithdraw.selector, attacker, 1, 0));
        fixedVault.withdraw(1, attacker, attacker);
    }
}
