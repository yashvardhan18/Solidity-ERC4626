// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LendingPoolBroken
/// @author Assignment submission
/// @notice The vulnerable lending pool from Task 3, preserved so the three bugs can be
///         demonstrated numerically in tests. **Never deploy this.**
/// @dev Everything above the scaffolding section is the assignment's code, unchanged. The
///      `__setState` helper at the bottom exists only so tests can put the contract into a
///      given state — the original has no `deposit`/`borrow`, so there is otherwise no way to
///      reach a state where the bugs are visible.
///
///      | Bug | Location          | One-line summary                                          |
///      |-----|-------------------|-----------------------------------------------------------|
///      | 1   | `utilization()`   | Integer division makes utilisation always 0 (or 1)         |
///      | 2   | `accrueInterest()`| Ignores elapsed time — a full year's interest per call     |
///      | 3   | `accrueInterest()`| Only the global total accrues; `debt[user]` never grows    |
contract LendingPoolBroken {
    /// @notice Fixed-point scale (1.0).
    uint256 public constant WAD = 1e18;
    /// @notice Total supplied by lenders.
    uint256 public totalDeposited;
    /// @notice Total owed by borrowers.
    uint256 public totalBorrowed;
    /// @notice Timestamp of the last accrual.
    uint256 public lastAccrualTime;
    /// @notice Interest rate at 0% utilisation (2% APR).
    uint256 public baseRate = 2e16;
    /// @notice Additional rate at 100% utilisation (8% APR).
    uint256 public slope = 8e16;
    /// @notice Per-borrower debt.
    mapping(address account => uint256 amount) public debt;
    /// @notice Per-borrower collateral.
    mapping(address account => uint256 amount) public collateral;

    /// @notice Multiplies two WAD-scaled numbers.
    /// @param a First operand.
    /// @param b Second operand.
    /// @return Product, WAD-scaled.
    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        // Latent issue: `a * b` is computed in 256 bits and reverts on overflow. For two WAD
        // numbers above ~3.4e38 this bricks every function that touches interest.
        return (a * b) / WAD;
    }

    /// @notice Current utilisation of the pool.
    /// @return Utilisation, intended to be WAD-scaled.
    function utilization() public view returns (uint256) {
        if (totalDeposited == 0) return 0;

        // BUG 1 - MISSING WAD SCALING (integer division).
        // Both operands are raw token amounts, so this is plain integer division. With
        // 800e18 borrowed against 1000e18 deposited the true utilisation is 0.8, but
        // `800e18 / 1000e18` evaluates to 0. The function can only ever return 0 (any
        // utilisation below 100%), 1 (exactly 100%), or higher if the pool is over-borrowed.
        return totalBorrowed / totalDeposited;
    }

    /// @notice Accrues interest on the outstanding debt.
    function accrueInterest() public {
        uint256 util = utilization();
        uint256 rate = baseRate + mulWad(util, slope);

        // BUG 2 - NO TIME SCALING.
        // `rate` is an ANNUAL rate, but it is applied in full on every call, and
        // `lastAccrualTime` is written without ever being read. Calling `accrueInterest()`
        // twice in the same block charges two years of interest in zero seconds.
        //
        // BUG 3 - PER-USER DEBT IS NEVER UPDATED.
        // Only the aggregate `totalBorrowed` grows. Every `debt[user]` entry stays frozen at
        // whatever was borrowed, so no borrower ever owes interest and the sum of individual
        // debts drifts permanently below the pool's own accounting. `totalDeposited` is not
        // credited either, so the interest is charged to nobody and paid to nobody.
        totalBorrowed += mulWad(totalBorrowed, rate);
        lastAccrualTime = block.timestamp;
    }

    // ---------------------------------------------------------------------
    //   Test scaffolding. Not part of the assignment's code.
    // ---------------------------------------------------------------------

    /// @notice Forces the pool into a given state so the bugs above can be measured.
    /// @dev Test-only, deliberately unguarded.
    /// @param deposited Value for `totalDeposited`.
    /// @param borrowed Value for `totalBorrowed`.
    /// @param user Borrower whose per-user entries are set.
    /// @param userDebt Value for `debt[user]`.
    /// @param userCollateral Value for `collateral[user]`.
    function __setState(uint256 deposited, uint256 borrowed, address user, uint256 userDebt, uint256 userCollateral)
        external
    {
        totalDeposited = deposited;
        totalBorrowed = borrowed;
        debt[user] = userDebt;
        collateral[user] = userCollateral;
        lastAccrualTime = block.timestamp;
    }

    /// @notice Exposes the internal `mulWad` for comparison against the fixed version.
    /// @param a First operand.
    /// @param b Second operand.
    /// @return Product, WAD-scaled.
    function exposedMulWad(uint256 a, uint256 b) external pure returns (uint256) {
        return mulWad(a, b);
    }
}
