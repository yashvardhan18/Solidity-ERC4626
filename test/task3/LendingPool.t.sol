// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingPool} from "../../src/task3/LendingPool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @title LendingPoolHarness
/// @notice Test-only subclass that exposes the internal `mulWad`.
/// @dev `mulWad` stays `internal` in production; the harness is how it gets fuzzed without
///      widening the pool's external surface.
contract LendingPoolHarness is LendingPool {
    /// @param asset_ Underlying asset.
    /// @param owner_ Initial owner.
    constructor(IERC20 asset_, address owner_) LendingPool(asset_, owner_) {}

    /// @notice Exposes `mulWad` for testing.
    /// @param a First operand.
    /// @param b Second operand.
    /// @return Product, WAD-scaled.
    function exposedMulWad(uint256 a, uint256 b) external pure returns (uint256) {
        return mulWad(a, b);
    }
}

/// @title LendingPoolTest
/// @author Assignment submission
/// @notice Task 3 test suite: exactly the tests specified in the assignment.
/// @dev Required:
///        - borrow() reverts at 81% utilization, succeeds at 79%.
///        - after 365 days at 10% APR, debt on 1e18 = 1.1e18 +/- 100 wei.
///        - liquidate() reverts at 89% LTV, succeeds at 91%.
///        - testFuzz_mulWad(uint128, uint128): safe mulWad matches a mulmod-based reference.
contract LendingPoolTest is Test {
    MockERC20 internal asset;
    LendingPoolHarness internal pool;

    address internal owner = makeAddr("owner");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        pool = new LendingPoolHarness(IERC20(address(asset)), owner);

        _fund(lender);
        _fund(borrower);
        _fund(liquidator);
    }

    /// @dev Mints a large balance to `who` and approves the pool.
    function _fund(address who) internal {
        asset.mint(who, 1_000_000e18);
        vm.prank(who);
        asset.approve(address(pool), type(uint256).max);
    }

    /// @dev Switches the pool to a flat 10% APR (base 10%, slope 0) so interest tests have a
    ///      single, hand-checkable rate that does not move with utilisation.
    function _useFlatTenPercentApr() internal {
        vm.prank(owner);
        pool.setRateParameters(0.1e18, 0);
    }

    /// @dev Lender supplies `amount` of liquidity.
    function _supply(uint256 amount) internal {
        vm.prank(lender);
        pool.deposit(amount);
    }

    /// @dev Borrower posts `amount` of collateral.
    function _postCollateral(uint256 amount) internal {
        vm.prank(borrower);
        pool.depositCollateral(amount);
    }

    // =====================================================================
    //  REQUIRED UNIT TEST - borrow() utilisation cap
    // =====================================================================

    /// @notice `borrow()` succeeds at 79% utilisation.
    function test_borrow_succeedsAt79PercentUtilization() public {
        _supply(1_000e18);
        _postCollateral(100_000e18);

        vm.prank(borrower);
        pool.borrow(790e18);

        assertEq(pool.debtOf(borrower), 790e18, "debt not recorded");
        assertApproxEqAbs(pool.utilization(), 0.79e18, 1e6, "utilisation should be 79%");
    }

    /// @notice `borrow()` reverts at 81% utilisation.
    function test_borrow_revertsAt81PercentUtilization() public {
        _supply(1_000e18);
        _postCollateral(100_000e18);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.UtilizationCapExceeded.selector, 0.81e18, pool.MAX_UTILIZATION())
        );
        pool.borrow(810e18);

        assertEq(pool.debtOf(borrower), 0, "state changed despite the revert");
    }

    // =====================================================================
    //  REQUIRED UNIT TEST - 365 days at 10% APR
    // =====================================================================

    /// @notice After 365 days at 10% APR, a 1e18 debt is 1.1e18 to within 100 wei.
    /// @dev The rate curve is flattened to a constant 10% so the expected value is exact and
    ///      hand-checkable: index goes 1.0 -> 1.1, and debt follows.
    function test_debtAfter365DaysAt10PercentApr() public {
        _useFlatTenPercentApr();
        _supply(100_000e18);
        _postCollateral(100e18);

        vm.prank(borrower);
        pool.borrow(1e18);

        assertEq(pool.debtOf(borrower), 1e18, "initial debt should be exactly the amount borrowed");

        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();

        assertApproxEqAbs(pool.debtOf(borrower), 1.1e18, 100, "debt after one year at 10% APR");
    }

    // =====================================================================
    //  REQUIRED UNIT TEST - liquidate() LTV threshold
    // =====================================================================

    /// @notice `liquidate()` reverts at 89% LTV.
    function test_liquidate_revertsAt89PercentLtv() public {
        _supply(100_000e18);
        _postCollateral(1_000e18);

        vm.prank(borrower);
        pool.borrow(890e18);

        assertEq(pool.ltv(borrower), 0.89e18, "precondition: LTV should be exactly 89%");

        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.PositionHealthy.selector, borrower, 0.89e18, pool.LIQUIDATION_LTV())
        );
        pool.liquidate(borrower, 100e18);
    }

    /// @notice `liquidate()` succeeds at 91% LTV.
    /// @dev The position is pushed over the line by accrued interest rather than by direct
    ///      state manipulation, which is how it happens in production: `borrow()` refuses to
    ///      open a position above 90%, so the only route past it is time.
    function test_liquidate_succeedsAt91PercentLtv() public {
        _useFlatTenPercentApr();
        _supply(100_000e18);
        _postCollateral(1_000e18);

        vm.prank(borrower);
        pool.borrow(880e18); // 88% LTV

        // 125 days at 10% APR grows the debt by ~3.42%, taking 88% LTV to ~91%.
        vm.warp(block.timestamp + 125 days);
        pool.accrueInterest();

        assertApproxEqAbs(pool.ltv(borrower), 0.91e18, 0.005e18, "precondition: LTV should be about 91%");

        uint256 debtBefore = pool.debtOf(borrower);
        uint256 repayAmount = 400e18;

        vm.prank(liquidator);
        uint256 seized = pool.liquidate(borrower, repayAmount);

        assertApproxEqAbs(seized, (repayAmount * 105) / 100, 1e6, "seizure should include the 5% bonus");
        assertApproxEqAbs(pool.debtOf(borrower), debtBefore - repayAmount, 1e6, "debt not reduced");
        assertLt(pool.ltv(borrower), pool.LIQUIDATION_LTV(), "position is still liquidatable after liquidation");
    }

    // =====================================================================
    //  REQUIRED FUZZ TEST - safe mulWad
    // =====================================================================

    /// @notice The pool's `mulWad` matches a `mulmod`-based full-precision reference for every
    ///         pair of uint128 inputs.
    /// @dev The reference builds the true 512-bit product from its low and high limbs using
    ///      `mulmod`, asserts the high limb is zero (which it must be for uint128 operands,
    ///      since `(2^128 - 1)^2 < 2^256`), and divides the exact low limb by WAD.
    /// @param a First operand.
    /// @param b Second operand.
    function testFuzz_mulWad(uint128 a, uint128 b) public view {
        assertEq(pool.exposedMulWad(a, b), _mulWadReference(a, b), "mulWad diverged from the exact reference");
    }

    /// @dev Exact `(a * b) / WAD` computed from a `mulmod`-derived 512-bit product.
    /// @param a First operand.
    /// @param b Second operand.
    /// @return The exact quotient.
    function _mulWadReference(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 lo;
        uint256 hi;
        unchecked {
            lo = a * b;
            uint256 mm = mulmod(a, b, type(uint256).max);
            hi = mm - lo;
            if (mm < lo) hi -= 1;
        }
        require(hi == 0, "reference: product exceeds 256 bits");
        return lo / 1e18;
    }
}
