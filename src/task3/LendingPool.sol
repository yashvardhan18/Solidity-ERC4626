// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LendingPool
/// @author Assignment submission
/// @notice Task 3: the lending pool with its three bugs fixed and the two missing functions
///         (`borrow` and `liquidate`) implemented.
/// @dev Each fix carries a `REASON` block naming the bug, the vulnerability it creates, and
///      why the change removes it.
///
///      **Model.** Debt and collateral are denominated in the same ERC-20 asset, matching the
///      original skeleton, which had no oracle and no second token. A production pool would
///      price collateral through an oracle; that is the one simplification kept from the
///      original design, and it is called out again on `_ltv`.
///
///      **Index accounting.** Interest is tracked with two monotonically increasing indices
///      rather than by looping over accounts. A lender's or borrower's stored balance is
///      "scaled" — divided by the index at the time it was written — so multiplying it back by
///      the current index yields the balance including all interest since. This is how Aave
///      and Compound do it, and it is the only approach that keeps per-user interest exact
///      without unbounded gas.
///
///      | Bug | Location           | Vulnerability                                          |
///      |-----|--------------------|--------------------------------------------------------|
///      | 1   | `utilization()`    | Integer division: utilisation is always 0, caps are dead|
///      | 2   | `accrueInterest()` | No time scaling: interest is a function of call count  |
///      | 3   | `accrueInterest()` | Per-user debt never accrues: borrowers repay principal |
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------------
    //                              Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown when an amount argument that must be non-zero is zero.
    error ZeroAmount();

    /// @notice Thrown when a borrow or withdrawal exceeds the pool's uncommitted cash.
    /// @param requested Amount asked for.
    /// @param available Amount actually on hand.
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice Thrown when a borrow would push utilisation past `MAX_UTILIZATION`.
    /// @param resulting Utilisation the borrow would produce, WAD-scaled.
    /// @param cap The configured ceiling, WAD-scaled.
    error UtilizationCapExceeded(uint256 resulting, uint256 cap);

    /// @notice Thrown when an action would leave an account at or above the liquidation LTV.
    /// @param account Borrower in question.
    /// @param resulting LTV the action would produce, WAD-scaled.
    /// @param cap Highest LTV allowed for a voluntary action, WAD-scaled.
    error LtvTooHigh(address account, uint256 resulting, uint256 cap);

    /// @notice Thrown when liquidating an account that is still healthy.
    /// @param account Borrower in question.
    /// @param currentLtv Current LTV, WAD-scaled.
    /// @param threshold LTV at which liquidation opens, WAD-scaled.
    error PositionHealthy(address account, uint256 currentLtv, uint256 threshold);

    /// @notice Thrown when liquidating an account with no debt.
    /// @param account Borrower in question.
    error NoDebt(address account);

    /// @notice Thrown when a repayment exceeds the close factor for a single liquidation.
    /// @param requested Amount the liquidator tried to repay.
    /// @param maxRepay Maximum repayable in one call.
    error RepayExceedsCloseFactor(uint256 requested, uint256 maxRepay);

    /// @notice Thrown when a rate parameter is set outside its sane range.
    error InvalidRateParameter();

    // ---------------------------------------------------------------------
    //                              Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when a lender supplies liquidity.
    /// @param account Lender.
    /// @param amount Underlying supplied.
    event Deposited(address indexed account, uint256 amount);

    /// @notice Emitted when a lender removes liquidity.
    /// @param account Lender.
    /// @param amount Underlying removed.
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice Emitted when a borrower posts collateral.
    /// @param account Borrower.
    /// @param amount Collateral posted.
    event CollateralDeposited(address indexed account, uint256 amount);

    /// @notice Emitted when a borrower removes collateral.
    /// @param account Borrower.
    /// @param amount Collateral removed.
    event CollateralWithdrawn(address indexed account, uint256 amount);

    /// @notice Emitted when a borrower draws debt.
    /// @param account Borrower.
    /// @param amount Underlying borrowed.
    /// @param newUtilization Utilisation after the borrow, WAD-scaled.
    event Borrowed(address indexed account, uint256 amount, uint256 newUtilization);

    /// @notice Emitted when debt is repaid.
    /// @param payer Address that paid.
    /// @param account Borrower whose debt was reduced.
    /// @param amount Underlying repaid.
    event Repaid(address indexed payer, address indexed account, uint256 amount);

    /// @notice Emitted when a position is liquidated.
    /// @param liquidator Address that repaid the debt.
    /// @param account Borrower who was liquidated.
    /// @param repaid Debt repaid by the liquidator.
    /// @param seized Collateral transferred to the liquidator.
    event Liquidated(address indexed liquidator, address indexed account, uint256 repaid, uint256 seized);

    /// @notice Emitted on every accrual that actually moves the indices.
    /// @param interest Interest added to outstanding debt.
    /// @param borrowIndex New borrow index.
    /// @param supplyIndex New supply index.
    event InterestAccrued(uint256 interest, uint256 borrowIndex, uint256 supplyIndex);

    /// @notice Emitted when the owner changes the interest-rate curve.
    /// @param baseRate New base rate.
    /// @param slope New slope.
    event RateParametersUpdated(uint256 baseRate, uint256 slope);

    // ---------------------------------------------------------------------
    //                             Constants
    // ---------------------------------------------------------------------

    /// @notice Fixed-point scale (1.0 == 1e18).
    uint256 public constant WAD = 1e18;

    /// @notice Seconds in the interest year the annual rates are quoted against.
    /// @dev A named constant rather than a bare `31536000`: the whole point of Bug 2's fix is
    ///      that interest is proportional to elapsed time, so the denominator has to be
    ///      unambiguous and testable.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Highest utilisation a borrow may leave the pool at (80%).
    /// @dev Utilisation is borrowed / supplied. A cap below 100% is what guarantees lenders can
    ///      still withdraw: at 100% the pool holds no cash and every withdrawal reverts, which
    ///      is a bank run with extra steps. It also keeps the pool on the shallow part of the
    ///      rate curve where the interest rate is still a meaningful signal.
    uint256 public constant MAX_UTILIZATION = 0.8e18;

    /// @notice LTV at or above which a position may be liquidated (90%).
    uint256 public constant LIQUIDATION_LTV = 0.9e18;

    /// @notice Fraction of a borrower's debt a single liquidation may repay (50%).
    /// @dev A close factor keeps liquidations proportionate. Without it, a position one wei
    ///      over the threshold could be wiped out entirely and charged the full bonus, which
    ///      turns a small price move into a total loss for the borrower.
    uint256 public constant CLOSE_FACTOR = 0.5e18;

    /// @notice Discount the liquidator receives on seized collateral (5%).
    /// @dev The incentive that makes anyone bother. Too small and bad debt goes unliquidated;
    ///      too large and borrowers are over-penalised.
    uint256 public constant LIQUIDATION_BONUS = 0.05e18;

    // ---------------------------------------------------------------------
    //                              Storage
    // ---------------------------------------------------------------------

    /// @notice The asset that is lent, borrowed and posted as collateral.
    IERC20 public immutable ASSET;

    /// @notice Interest rate at 0% utilisation, per year, WAD-scaled (2% by default).
    uint256 public baseRate = 2e16;

    /// @notice Extra interest rate added at 100% utilisation, per year, WAD-scaled (8%).
    uint256 public slope = 8e16;

    /// @notice Timestamp of the most recent accrual.
    uint256 public lastAccrualTime;

    /// @notice Cumulative borrow index. Starts at WAD and only ever increases.
    uint256 public borrowIndex = WAD;

    /// @notice Cumulative supply index. Starts at WAD and only ever increases.
    uint256 public supplyIndex = WAD;

    /// @notice Sum of every lender's scaled balance.
    uint256 public totalScaledDeposit;

    /// @notice Sum of every borrower's scaled debt.
    uint256 public totalScaledDebt;

    /// @notice Total collateral posted across all borrowers.
    /// @dev Tracked separately from lending liquidity. Collateral belongs to the borrower who
    ///      posted it and must never be lent out, or a liquidation could find nothing to seize.
    uint256 public totalCollateral;

    /// @notice Lender balances, scaled by `supplyIndex`.
    mapping(address account => uint256 scaled) public scaledDeposit;

    /// @notice Borrower debts, scaled by `borrowIndex`.
    mapping(address account => uint256 scaled) public scaledDebt;

    /// @notice Collateral posted per borrower.
    mapping(address account => uint256 amount) public collateral;

    /// @param asset_ ERC-20 used for lending, borrowing and collateral.
    /// @param owner_ Initial owner, able to tune the rate curve.
    constructor(IERC20 asset_, address owner_) Ownable(owner_) {
        ASSET = asset_;
        // Without this, the first accrual would measure elapsed time from the unix epoch and
        // charge roughly 56 years of interest in one call.
        lastAccrualTime = block.timestamp;
    }

    // =====================================================================
    //  BUG 1 FIX
    // =====================================================================

    /// @notice Current utilisation of the pool, WAD-scaled (1e18 == 100%).
    /// @return Utilisation ratio.
    function utilization() public view returns (uint256) {
        uint256 deposited = totalDeposited();
        if (deposited == 0) return 0;

        // REASON — BUG 1 FIX: MISSING WAD SCALING IN utilization().
        //
        // Bug name:  Integer-division utilisation (dead rate curve, dead borrow cap).
        // Vulnerability caused:
        //   The original was `return totalBorrowed / totalDeposited`. Both are raw token
        //   amounts, so this is integer division and the result is 0 for every utilisation
        //   below 100%. Two things break at once:
        //     (a) The rate curve collapses. `rate = baseRate + mulWad(util, slope)` becomes
        //         `rate = baseRate` permanently, so borrowers pay 2% APR whether the pool is
        //         empty or 99.9% drained. The rate can no longer do its job of pricing
        //         scarcity, so nothing pushes borrowers to repay when lenders want their money
        //         back and lenders are systematically underpaid.
        //     (b) Every downstream cap is dead. The 80% utilisation limit that `borrow()` is
        //         supposed to enforce compares `util` (always 0) against 0.8e18, which always
        //         passes. A borrower can therefore drain the pool to 100% utilisation in a
        //         single transaction, after which no lender can withdraw a single wei until
        //         somebody voluntarily repays. That is a permanent, unpriced denial of service
        //         against every lender, and it costs the attacker nothing beyond the 2% floor
        //         rate they were going to pay anyway.
        // Why fixed:
        //   Multiplying by WAD before dividing keeps the ratio in the same fixed-point scale
        //   as `baseRate` and `slope`, so 800e18 borrowed against 1000e18 supplied now returns
        //   0.8e18 rather than 0. `Math.mulDiv` performs the intermediate multiplication in
        //   512 bits, so a large pool cannot overflow the numerator and brick the pool.
        //   Rounding up is deliberate: utilisation feeds a safety cap, and a cap should never
        //   under-report the risk it is guarding against.
        return totalBorrowed().mulDiv(WAD, deposited, Math.Rounding.Ceil);
    }

    // =====================================================================
    //  BUG 2 AND BUG 3 FIX
    // =====================================================================

    /// @notice Accrues interest up to the current block timestamp.
    /// @dev Permissionless and idempotent within a block. Every state-changing entry point
    ///      calls it first, so all reads downstream are already up to date.
    function accrueInterest() public {
        // REASON — BUG 2 FIX: INTEREST WAS NOT SCALED BY ELAPSED TIME.
        //
        // Bug name:  Call-count interest (unbounded debt inflation / griefing).
        // Vulnerability caused:
        //   The original computed `totalBorrowed += mulWad(totalBorrowed, rate)` where `rate`
        //   is an ANNUAL rate, and it wrote `lastAccrualTime` without ever reading it. Interest
        //   therefore depended on how many times the function was called, not on how much time
        //   had passed. `accrueInterest()` is public and takes no arguments, so anyone can call
        //   it in a loop: 100 calls in one transaction charge 100 years of interest, roughly
        //   multiplying every borrower's debt by 7.2 in a single block for the cost of gas.
        //   An attacker uses this to force healthy positions past the liquidation threshold and
        //   then liquidates them for the 5% bonus — a profitable, repeatable attack on every
        //   borrower in the pool. In the opposite direction, a pool that is simply called less
        //   often accrues less interest, so lenders are shortchanged at random.
        // Why fixed:
        //   Interest is now `rate * elapsed / SECONDS_PER_YEAR`. Two calls in the same block
        //   produce `elapsed == 0` and the second is a no-op, so the result depends only on
        //   wall-clock time and is identical whether the function is called once a year or
        //   every block. The early return also saves gas on the common repeated-call path.
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return;

        // Written before the early exits below so an idle pool still moves its clock forward
        // rather than accumulating a backlog of "elapsed" time to charge later.
        lastAccrualTime = block.timestamp;

        uint256 scaledDebtTotal = totalScaledDebt;
        if (scaledDebtTotal == 0) return;

        uint256 borrowed = totalBorrowed();
        if (borrowed == 0) return;

        // Annual rate at the current utilisation, then pro-rated to the elapsed window.
        uint256 rate = baseRate + mulWad(utilization(), slope);
        uint256 interestFactor = rate.mulDiv(elapsed, SECONDS_PER_YEAR, Math.Rounding.Floor);
        if (interestFactor == 0) return;

        uint256 interest = mulWad(borrowed, interestFactor);
        if (interest == 0) return;

        // REASON — BUG 3 FIX: PER-USER DEBT NEVER ACCRUED, AND LENDERS WERE NEVER PAID.
        //
        // Bug name:  Detached interest accounting (free loans and unbacked lender claims).
        // Vulnerability caused:
        //   The original only ever touched the aggregate `totalBorrowed`. Every `debt[user]`
        //   entry stayed frozen at the amount originally drawn, and `totalDeposited` was never
        //   credited. Consequences:
        //     (a) Borrowers never owe interest. A borrower repays exactly `debt[user]`, closes
        //         the position, and walks away having used the pool's money for free. Every
        //         lender pays for that.
        //     (b) The books do not balance. `totalBorrowed` grows while the sum of individual
        //         debts does not, so `utilization()` and every solvency check read a number
        //         that no borrower actually owes. The pool believes it is owed money that no
        //         account is liable for.
        //     (c) Liquidation thresholds are computed from a `debt[user]` that never moves, so
        //         a position that has been accruing interest for years still reports its
        //         original LTV and can never be liquidated, even when it is deeply insolvent.
        // Why fixed:
        //   Interest is applied by advancing `borrowIndex`, and each borrower's stored debt is
        //   SCALED by the index at the moment it was written. `debtOf(user)` multiplies the
        //   scaled amount back by the current index, so every borrower's debt grows with the
        //   pool automatically — no loop over accounts, no per-user bookkeeping, exact for
        //   every holder. The same interest is credited to lenders through `supplyInde₹x`, so
        //   the two sides of the balance sheet move together by construction: the amount added
        //   to what borrowers owe is exactly the amount added to what lenders are owed.
        borrowIndex += mulWad(borrowIndex, interestFactor);

        uint256 deposited = totalDeposited();
        if (deposited > 0) {
            // Lenders' claims grow by the same absolute interest, expressed as a proportion of
            // what they already hold. Doing it this way rather than reusing `interestFactor`
            // matters: the interest is a percentage of *borrowed*, not of *deposited*, and the
            // two are only equal at 100% utilisation.
            supplyIndex += supplyIndex.mulDiv(interest, deposited, Math.Rounding.Floor);
        }

        emit InterestAccrued(interest, borrowIndex, supplyIndex);
    }

    // =====================================================================
    //  NEW FUNCTION 1 - borrow()
    // =====================================================================

    /// @notice Borrows `amount` of the underlying against the caller's posted collateral.
    /// @dev Required by the assignment: enforces the 80% utilisation cap and accrues interest
    ///      first.
    ///
    ///      Order of operations, and why it is this order:
    ///        1. `accrueInterest()` first. Every check below reads `totalBorrowed`, `debtOf`
    ///           and `utilization()`. If interest were accrued afterwards, all three would be
    ///           stale and a borrower could squeeze under a cap they are actually already past.
    ///           This is the assignment's explicit requirement and it is also the only correct
    ///           order.
    ///        2. Liquidity check, so the pool cannot promise cash it does not hold — and
    ///           specifically cannot lend out collateral that is earmarked for liquidations.
    ///        3. Record the debt.
    ///        4. Check the caps on the RESULTING state, not the state before. Checking
    ///           beforehand would let a single large borrow jump straight past both limits.
    ///        5. Transfer last (checks-effects-interactions), so a callback-bearing token
    ///           cannot re-enter and borrow twice against one collateral position.
    /// @param amount Amount of underlying to borrow.
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        accrueInterest();

        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity(amount, available);

        // Round the scaled debt UP. Rounding down would let a borrower repeatedly borrow tiny
        // amounts that register as zero debt — the same class of bug as Task 2's Bug A, but
        // pointed at the pool's reserves instead of a vault's.
        uint256 scaledAmount = amount.mulDiv(WAD, borrowIndex, Math.Rounding.Ceil);
        scaledDebt[msg.sender] += scaledAmount;
        totalScaledDebt += scaledAmount;

        uint256 resultingUtilization = utilization();
        if (resultingUtilization > MAX_UTILIZATION) {
            revert UtilizationCapExceeded(resultingUtilization, MAX_UTILIZATION);
        }

        // A borrower must not be able to open a position that is already liquidatable — that
        // would let them hand themselves the 5% bonus by liquidating their own position.
        uint256 resultingLtv = _ltv(msg.sender);
        if (resultingLtv >= LIQUIDATION_LTV) revert LtvTooHigh(msg.sender, resultingLtv, LIQUIDATION_LTV);

        ASSET.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, resultingUtilization);
    }

    // =====================================================================
    //  NEW FUNCTION 2 - liquidate()
    // =====================================================================

    /// @notice Repays part of an unhealthy borrower's debt and seizes their collateral at a
    ///         discount.
    /// @dev Required by the assignment: opens at 90% LTV and accrues interest first.
    ///
    ///      `accrueInterest()` must run before the health check for the same reason as in
    ///      `borrow`, but the risk points the other way: without it, `debtOf(user)` is stale
    ///      and *understates* the debt, so genuinely insolvent positions would look healthy and
    ///      could not be liquidated. Bad debt would then accumulate silently until the pool
    ///      could not honour withdrawals.
    ///
    ///      The liquidator repays at most `CLOSE_FACTOR` of the debt and receives the repaid
    ///      value plus `LIQUIDATION_BONUS` in collateral. The seizure is capped at the
    ///      borrower's actual collateral, so a position that is more than ~105% LTV is simply
    ///      liquidated for everything it has and the shortfall stays as bad debt — the
    ///      alternative would be to revert, which would leave the position untouchable.
    /// @param account Borrower to liquidate.
    /// @param repayAmount Amount of the borrower's debt to repay.
    /// @return seized Collateral transferred to the liquidator.
    function liquidate(address account, uint256 repayAmount) external nonReentrant returns (uint256 seized) {
        if (repayAmount == 0) revert ZeroAmount();

        accrueInterest();

        uint256 currentDebt = debtOf(account);
        if (currentDebt == 0) revert NoDebt(account);

        uint256 currentLtv = _ltv(account);
        if (currentLtv < LIQUIDATION_LTV) revert PositionHealthy(account, currentLtv, LIQUIDATION_LTV);

        uint256 maxRepay = mulWad(currentDebt, CLOSE_FACTOR);
        if (repayAmount > maxRepay) revert RepayExceedsCloseFactor(repayAmount, maxRepay);

        // Collateral owed to the liquidator: what they repaid, plus the bonus.
        seized = mulWad(repayAmount, WAD + LIQUIDATION_BONUS);
        uint256 accountCollateral = collateral[account];
        if (seized > accountCollateral) seized = accountCollateral;

        // Effects before interactions. Reduce the debt by exactly what is being repaid; round
        // the scaled reduction DOWN so a rounding error can never wipe out more debt than was
        // actually paid for.
        uint256 scaledRepaid = repayAmount.mulDiv(WAD, borrowIndex, Math.Rounding.Floor);
        uint256 accountScaledDebt = scaledDebt[account];
        if (scaledRepaid > accountScaledDebt) scaledRepaid = accountScaledDebt;

        scaledDebt[account] = accountScaledDebt - scaledRepaid;
        totalScaledDebt -= scaledRepaid;

        collateral[account] = accountCollateral - seized;
        totalCollateral -= seized;

        // Pull the repayment in before paying the collateral out, so a liquidator whose
        // repayment fails cannot walk away with the collateral.
        ASSET.safeTransferFrom(msg.sender, address(this), repayAmount);
        ASSET.safeTransfer(msg.sender, seized);

        emit Liquidated(msg.sender, account, repayAmount, seized);
    }

    // =====================================================================
    //  Supporting entry points
    // =====================================================================

    /// @notice Supplies `amount` of the underlying to be lent out.
    /// @param amount Amount of underlying to supply.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        // Round the lender's scaled credit DOWN so a deposit never mints a claim on more than
        // was actually paid in.
        uint256 scaledAmount = amount.mulDiv(WAD, supplyIndex, Math.Rounding.Floor);
        if (scaledAmount == 0) revert ZeroAmount();

        scaledDeposit[msg.sender] += scaledAmount;
        totalScaledDeposit += scaledAmount;

        ASSET.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraws `amount` of supplied liquidity plus accrued interest.
    /// @param amount Amount of underlying to withdraw.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 balance = depositOf(msg.sender);
        if (amount > balance) revert InsufficientLiquidity(amount, balance);

        // Cash actually on hand may be less than the lender's claim if borrowers hold it.
        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity(amount, available);

        // Round the scaled reduction UP so a withdrawal never leaves the lender credited with
        // more than they should still hold.
        uint256 scaledAmount = amount.mulDiv(WAD, supplyIndex, Math.Rounding.Ceil);
        uint256 currentScaled = scaledDeposit[msg.sender];
        if (scaledAmount > currentScaled) scaledAmount = currentScaled;

        scaledDeposit[msg.sender] = currentScaled - scaledAmount;
        totalScaledDeposit -= scaledAmount;

        ASSET.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Posts `amount` of collateral for the caller.
    /// @param amount Amount of underlying to post as collateral.
    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        collateral[msg.sender] += amount;
        totalCollateral += amount;

        ASSET.safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Removes `amount` of the caller's collateral.
    /// @dev Accrues first, then checks the LTV that the withdrawal would leave behind.
    ///      Skipping the accrual here would let a borrower pull collateral out against a stale,
    ///      understated debt figure and leave the pool with an instantly-insolvent position.
    /// @param amount Amount of collateral to remove.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 posted = collateral[msg.sender];
        if (amount > posted) revert InsufficientLiquidity(amount, posted);

        collateral[msg.sender] = posted - amount;
        totalCollateral -= amount;

        uint256 resultingLtv = _ltv(msg.sender);
        if (resultingLtv >= LIQUIDATION_LTV) revert LtvTooHigh(msg.sender, resultingLtv, LIQUIDATION_LTV);

        ASSET.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @notice Repays `amount` of `account`'s debt.
    /// @dev Anyone may repay on anyone's behalf. This is safe — it only ever reduces someone's
    ///      liability — and it lets a borrower be rescued by a third party before liquidation.
    /// @param account Borrower whose debt is reduced.
    /// @param amount Amount of underlying to repay. Capped at the outstanding debt.
    /// @return repaid Amount actually repaid.
    function repay(address account, uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 outstanding = debtOf(account);
        if (outstanding == 0) revert NoDebt(account);

        // Cap rather than revert on overpayment: debt grows every second, so a caller trying
        // to clear a position exactly would otherwise have to win a race against the block
        // timestamp. Overshooting is the normal way to close a loan.
        repaid = amount > outstanding ? outstanding : amount;

        // Round DOWN so the scaled reduction never exceeds what was paid for.
        uint256 scaledRepaid = repaid.mulDiv(WAD, borrowIndex, Math.Rounding.Floor);
        uint256 currentScaled = scaledDebt[account];
        if (scaledRepaid > currentScaled) scaledRepaid = currentScaled;

        scaledDebt[account] = currentScaled - scaledRepaid;
        totalScaledDebt -= scaledRepaid;

        ASSET.safeTransferFrom(msg.sender, address(this), repaid);

        emit Repaid(msg.sender, account, repaid);
    }

    // =====================================================================
    //  Views
    // =====================================================================

    /// @notice Total owed by all borrowers, including accrued interest.
    /// @return Outstanding debt in underlying units.
    function totalBorrowed() public view returns (uint256) {
        return mulWad(totalScaledDebt, borrowIndex);
    }

    /// @notice Total owed to all lenders, including accrued interest.
    /// @return Lender claims in underlying units.
    function totalDeposited() public view returns (uint256) {
        return mulWad(totalScaledDeposit, supplyIndex);
    }

    /// @notice Debt of `account`, including all interest accrued up to the last accrual.
    /// @param account Borrower to query.
    /// @return Debt in underlying units.
    function debtOf(address account) public view returns (uint256) {
        return mulWad(scaledDebt[account], borrowIndex);
    }

    /// @notice Lender balance of `account`, including all interest earned.
    /// @param account Lender to query.
    /// @return Balance in underlying units.
    function depositOf(address account) public view returns (uint256) {
        return mulWad(scaledDeposit[account], supplyIndex);
    }

    /// @notice Loan-to-value ratio of `account`, WAD-scaled.
    /// @param account Borrower to query.
    /// @return LTV ratio; `type(uint256).max` when there is debt but no collateral.
    function ltv(address account) external view returns (uint256) {
        return _ltv(account);
    }

    /// @notice Whether `account` may currently be liquidated.
    /// @param account Borrower to query.
    /// @return True when the position is at or above `LIQUIDATION_LTV`.
    function isLiquidatable(address account) external view returns (bool) {
        return scaledDebt[account] > 0 && _ltv(account) >= LIQUIDATION_LTV;
    }

    /// @notice Cash the pool can lend or pay out right now.
    /// @dev Derived from the accounting rather than from `ASSET.balanceOf(address(this))`.
    ///      Reading the raw balance would let anyone inflate the pool's apparent liquidity with
    ///      a direct token transfer, and would count borrowers' collateral as lendable.
    /// @return Available underlying.
    function availableLiquidity() public view returns (uint256) {
        uint256 deposited = totalDeposited();
        uint256 borrowed = totalBorrowed();
        // Interest can round the two apart by a wei; saturate rather than underflow.
        return deposited > borrowed ? deposited - borrowed : 0;
    }

    /// @notice Current annual borrow rate at the pool's utilisation, WAD-scaled.
    /// @return Annual rate.
    function currentBorrowRate() external view returns (uint256) {
        return baseRate + mulWad(utilization(), slope);
    }

    // =====================================================================
    //  Admin
    // =====================================================================

    /// @notice Updates the interest-rate curve.
    /// @dev Bounded so the owner cannot set a rate that would liquidate the whole book in one
    ///      block. `onlyOwner` because an open setter would let anyone do exactly that.
    /// @param newBaseRate New rate at 0% utilisation, per year, WAD-scaled.
    /// @param newSlope New additional rate at 100% utilisation, per year, WAD-scaled.
    function setRateParameters(uint256 newBaseRate, uint256 newSlope) external onlyOwner {
        // 1000% APR combined is already absurd; anything above it is an attack, not a policy.
        if (newBaseRate + newSlope > 10 * WAD) revert InvalidRateParameter();

        // Settle interest at the old curve before switching, so the change applies only from
        // now on and cannot be used to retroactively reprice existing debt.
        accrueInterest();

        baseRate = newBaseRate;
        slope = newSlope;

        emit RateParametersUpdated(newBaseRate, newSlope);
    }

    // =====================================================================
    //  Math
    // =====================================================================

    /// @notice Multiplies two WAD-scaled numbers, rounding down.
    /// @dev REASON — SAFE `mulWad`.
    ///
    ///      The original was `return (a * b) / WAD`. In Solidity 0.8 the multiplication is
    ///      checked, so it does not silently wrap — but it does REVERT whenever `a * b`
    ///      exceeds 2^256-1, even when the final quotient would fit comfortably in a uint256.
    ///      `a` is routinely a cumulative index and `b` a total, so the product crosses that
    ///      line at entirely realistic pool sizes, and when it does, `accrueInterest()` starts
    ///      reverting. Because every entry point calls `accrueInterest()` first, that single
    ///      overflow freezes deposits, withdrawals, borrows, repayments and liquidations
    ///      permanently — every lender's funds are locked with no admin path out.
    ///
    ///      `Math.mulDiv` computes `a * b` as a 512-bit intermediate and divides that, so the
    ///      only failure mode left is a quotient that genuinely does not fit in 256 bits.
    ///      For all `uint128` inputs the two agree exactly, which is what
    ///      `testFuzz_mulWad` checks against a `mulmod`-based reference.
    /// @param a First operand, WAD-scaled.
    /// @param b Second operand, WAD-scaled.
    /// @return Product, WAD-scaled.
    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, WAD);
    }

    /// @dev LTV = debt / collateral, WAD-scaled.
    ///
    ///      Rounds UP so the pool never understates how risky a position is: a rounded-down LTV
    ///      could keep an insolvent position just under the liquidation threshold.
    ///
    ///      Debt with zero collateral returns `type(uint256).max` rather than dividing by zero.
    ///      That both avoids a panic and correctly classifies an uncollateralised loan as
    ///      maximally unhealthy, so `liquidate` can act on it instead of reverting.
    ///
    ///      Note the simplification inherited from the original skeleton: collateral and debt
    ///      are the same asset, so no oracle is involved. A pool with a distinct collateral
    ///      token would price both legs here, and that price feed would become the single most
    ///      security-critical input in the contract.
    /// @param account Borrower to price.
    /// @return LTV ratio.
    function _ltv(address account) private view returns (uint256) {
        uint256 accountDebt = debtOf(account);
        if (accountDebt == 0) return 0;

        uint256 accountCollateral = collateral[account];
        if (accountCollateral == 0) return type(uint256).max;

        return accountDebt.mulDiv(WAD, accountCollateral, Math.Rounding.Ceil);
    }
}
