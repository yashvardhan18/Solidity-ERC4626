# Task 3 — The Lending Pool, Explained Simply

## The picture

Think of a neighborhood lending club instead of a single jar. Two kinds of people show up:

- **Lenders** put money into the pool and expect to earn interest on it over time.
- **Borrowers** put up something valuable as **collateral** (a security deposit), and in
  exchange the pool lets them borrow money, which they must eventually pay back **with
  interest**.

The pool has to track, for every single person, exactly how much they're owed (lenders) or how
much they owe (borrowers), and that number has to keep growing correctly as time passes —
interest doesn't sit still.

## What the task asked for

1. Find and fix **three bugs** in a lending pool that already had the basic shape of this idea,
   but got the mechanics wrong.
2. Implement the two pieces that were missing entirely: **`borrow()`** (get money out, using
   your collateral as backing) and **`liquidate()`** (what happens if a borrower's position
   becomes too risky and someone needs to step in).

## Some vocabulary first, explained plainly

- **Utilization** — what fraction of the money lenders put in has actually been lent out right
  now. If lenders supplied 1,000 and borrowers have taken out 800, utilization is 80%.
- **APR (annual percentage rate)** — the interest rate, quoted per year. "10% APR" means a 100
  debt grows to 110 over one full year, if nothing else changes.
- **LTV (loan-to-value)** — how large a borrower's debt is *relative to* their collateral. If
  you posted 1,000 as collateral and owe 900, your LTV is 90%. The higher this number, the
  riskier your position — if it gets too close to 100%, your debt is close to being worth as
  much as what's backing it, and the pool could lose money if you simply never pay it back.
- **WAD** — a fixed-point scaling trick. Solidity has no built-in decimals, so "1.0" is
  represented internally as the number `1,000,000,000,000,000,000` (`1e18`, called "one WAD"),
  and "0.10" (10%) is represented as `1e17`. Every rate and ratio in this contract is a WAD
  number under the hood — this document uses plain percentages like "10%" for readability, but
  remember every one of them is secretly a very large integer in the code.

## Bug 1 — `utilization()` throws away the decimal point

### The buggy code

```solidity
function utilization() public view returns (uint256) {
    if (totalDeposited == 0) return 0;
    return totalBorrowed / totalDeposited;
}
```

### The story

800 borrowed, 1,000 deposited — utilization should read 80%. But `totalBorrowed` and
`totalDeposited` are both plain whole-number token amounts, so `800 / 1,000` in whole-number
division is **0**, because 800 doesn't divide evenly into 1,000 even once. The function can
only ever report `0` (any utilization under 100%), or `1` (at or above 100%) — nothing in
between, ever.

This breaks two separate things at once:

- **The interest rate curve goes flat.** The rate formula is supposed to be
  `baseRate + utilization × slope` — the busier the pool, the higher the rate, which is what
  naturally nudges borrowers to repay when lenders want their money back. But if `utilization`
  is always reported as `0`, that whole second term vanishes and the rate is stuck at the
  bare-minimum `baseRate` no matter what's actually happening in the pool.
- **Every safety cap built on top of utilization is dead.** This pool is supposed to cap
  borrowing at 80% utilization, so at least 20% of lenders' money is always sitting there,
  withdrawable. But a check like "does new utilization exceed 80%?" is comparing against a
  number that's *always 0* — the check always passes. A borrower can drain the pool to 100%
  utilization in one transaction, and after that, **no lender can withdraw anything** until
  someone voluntarily repays. That's every lender's money frozen, for free, by one borrower.

### The fix

```solidity
return totalBorrowed.mulDiv(WAD, deposited, Math.Rounding.Ceil);
```

Multiply by WAD (`1e18`) *before* dividing. `800 × 1e18 / 1,000 = 0.8e18`, which correctly
represents "0.8", i.e. 80%. This is the general fix for "whole-number division throws away
fractions": scale the numerator up first so there's room for a fractional answer to survive
the division. (`Math.mulDiv` is used instead of a plain `*` and `/` because multiplying by
`1e18` on a large number can overflow a basic calculation — `mulDiv` handles that safely.)

---

## Bug 2 — Interest ignores how much time actually passed

### The buggy code

```solidity
function accrueInterest() public {
    uint256 util = utilization();
    uint256 rate = baseRate + mulWad(util, slope);
    totalBorrowed += mulWad(totalBorrowed, rate);
    lastAccrualTime = block.timestamp;
}
```

### The story

`rate` here is an **annual** rate — say 10% per year. But look at the line that actually
applies it: `totalBorrowed += totalBorrowed × rate`. It applies the *entire annual rate*, every
single time this function is called, with absolutely no regard for how much time has actually
passed since the last call. And even though `lastAccrualTime` gets written at the end, **it is
never read anywhere** — it's a clock that nobody looks at.

`accrueInterest()` has no restrictions on who can call it, or how often. So an attacker simply
calls it in a loop, ten times in the same transaction, with zero seconds having elapsed between
calls. Each call still applies the full annual rate. Ten calls back-to-back roughly means
`(1 + rate)^10` growth — at even a modest rate, that can multiply every borrower's debt several
times over, instantly. And debt exploding upward is exactly what pushes borrowers over the
liquidation threshold (more on liquidation below) — so the attacker can inflate debts, then
immediately liquidate the now-"unhealthy" positions and pocket the liquidation bonus. It's a
free, repeatable attack funded entirely by other people's debt being artificially inflated.

### The fix

```solidity
uint256 elapsed = block.timestamp - lastAccrualTime;
if (elapsed == 0) return;                     // two calls in the same block: nothing to do

lastAccrualTime = block.timestamp;

uint256 rate = baseRate + mulWad(utilization(), slope);          // the annual rate
uint256 interestFactor = rate.mulDiv(elapsed, SECONDS_PER_YEAR); // scaled down to the actual window
```

The key change is `rate.mulDiv(elapsed, SECONDS_PER_YEAR)` — take the annual rate and multiply
it by "what fraction of a year actually passed". If exactly one day passed, that's
`rate × (1 day / 365 days) ≈ rate / 365` — a tiny slice of the annual rate, not the whole
thing. Call the function every block, once a day, or once a year — the total interest charged
over any given stretch of real time comes out the same, because it's now tied to the clock
instead of to how many times someone happened to press the button.

---

## Bug 3 — Nobody's individual balance actually grows

### The buggy code

Look again at the buggy `accrueInterest()` above: the *only* thing it touches is the single
shared number `totalBorrowed`. It never touches `debt[borrower]` for any individual borrower,
and it never touches `totalDeposited` (what lenders are owed) at all.

### The story

Picture two people looking at two different ledgers. The pool's own summary page
(`totalBorrowed`) says "everyone owes 880 in total, growing every day". But each individual
borrower's personal statement (`debt[borrower]`) never gets updated — it's frozen at whatever
they originally borrowed, forever. This creates three separate problems:

- **Borrowing becomes free.** A borrower just repays their original `debt[borrower]` figure —
  which never grew — and walks away, having used the pool's money for however long they liked
  without ever paying a cent of interest. Since interest is the entire reason lenders put money
  in, they get nothing.
- **The books don't add up.** The pool's summary total keeps climbing, but no individual
  account is actually liable for that growth. Ask "who owes this extra money?" and there's no
  answer — it exists in the aggregate number but nowhere else.
- **Risk checks read stale numbers forever.** Whether a position needs to be liquidated is
  decided by looking at *that specific person's* debt versus their collateral. If their
  personal debt figure never moves, a position can quietly become deeply underwater — the pool
  really is owed far more than the collateral is worth — and yet the liquidation check still
  sees the old, small number and says everything's fine. Bad debt piles up completely
  invisibly, right up until lenders try to withdraw and discover the money simply isn't there.

### The fix — an "index" instead of updating everyone one by one

The naive fix would be "loop over every borrower and every lender and update their number by
hand" — but that doesn't scale; a pool with ten thousand accounts would need ten thousand
updates every single time interest accrues.

The trick real lending protocols use (and this fix adopts) is an **index** — a single shared
multiplier that starts at "1.0" and only ever grows:

```solidity
borrowIndex += mulWad(borrowIndex, interestFactor);
```

Instead of storing "Alice owes 100 tokens" directly, the pool stores a **scaled** number:
"Alice owes 100 divided by the index at the moment she borrowed". Whenever anyone wants to know
what Alice *actually* owes right now, they just multiply her scaled number by the **current**
index:

```solidity
function debtOf(address account) public view returns (uint256) {
    return mulWad(scaledDebt[account], borrowIndex);
}
```

**Worked example.** Alice borrows 100 when the index is exactly `1.0`. Her scaled debt is
stored as `100 / 1.0 = 100`. A year passes at 10% APR and the index grows to `1.10`. Nobody
touched Alice's stored number at all — but `debtOf(alice)` now computes
`100 × 1.10 = 110` automatically, because the shared index moved. Every borrower's real-world
debt grows in lockstep with the index, with **one single update per accrual**, no matter how
many borrowers there are.

The exact same trick is used for lenders via a second index, `supplyIndex`, so that when
interest is charged to borrowers, lenders are credited the matching amount:

```solidity
supplyIndex += supplyIndex.mulDiv(interest, deposited, Math.Rounding.Floor);
```

This closes all three problems from the story: borrowers now genuinely accrue interest (their
`debtOf` grows every time interest accrues, even though nobody touched their individual
entry); the books balance, because the interest added to `borrowIndex` and the interest added
to `supplyIndex` come from the exact same `interest` number; and liquidation checks now see a
borrower's real, currently-accruing debt, not a frozen snapshot from the day they borrowed.

---

## The `mulWad` overflow, fixed as a bonus

```solidity
function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a * b) / WAD;
}
```

This looks harmless, but `a * b` is computed *before* the division. If both `a` and `b` are
large numbers (which cumulative indices and pool totals can become, over enough time and
enough volume), their product can be bigger than the biggest number Solidity can hold — and
Solidity's modern versions crash the transaction the instant that happens, rather than silently
wrapping around. Because *every single function in this pool calls `accrueInterest()` first*,
and `accrueInterest()` calls `mulWad`, one single overflow would freeze deposits, withdrawals,
borrowing, repayment, and liquidation **all at once, permanently**, with no way for anyone to
recover their funds.

The fix swaps in `Math.mulDiv(a, b, WAD)` — a library function that computes the
multiply-then-divide using extra internal precision, so the *product* never has to fit in a
normal number, only the *final answer* does. The two give identical results for any input
small enough that the naive version wouldn't have overflowed anyway; the safe version just
also survives the cases where it would have.

---

## `borrow()` — the new function, walked through

```solidity
function borrow(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();

    accrueInterest();                                     // 1. update the clock first

    uint256 available = availableLiquidity();
    if (amount > available) revert InsufficientLiquidity(amount, available);   // 2. is there cash?

    uint256 scaledAmount = amount.mulDiv(WAD, borrowIndex, Math.Rounding.Ceil);
    scaledDebt[msg.sender] += scaledAmount;               // 3. record the debt
    totalScaledDebt += scaledAmount;

    uint256 resultingUtilization = utilization();
    if (resultingUtilization > MAX_UTILIZATION) {          // 4a. would this push utilization too high?
        revert UtilizationCapExceeded(resultingUtilization, MAX_UTILIZATION);
    }

    uint256 resultingLtv = _ltv(msg.sender);
    if (resultingLtv >= LIQUIDATION_LTV) {                 // 4b. would this leave the position unsafe?
        revert LtvTooHigh(msg.sender, resultingLtv, LIQUIDATION_LTV);
    }

    ASSET.safeTransfer(msg.sender, amount);                // 5. only now hand out the money
}
```

Five steps, in plain terms:

1. **Update the interest clock first** — every check below reads numbers that depend on
   accrued interest (total debt, utilization, LTV). If those were stale, a borrower could
   sneak under a limit they've actually already crossed.
2. **Is there actually spare cash to lend?** — `availableLiquidity()` is deposits minus what's
   already borrowed. Collateral money is never counted here — collateral belongs to whoever
   posted it and must never be lent out to someone else, or there'd be nothing left to seize if
   that person needed to be liquidated.
3. **Record the debt** — using the scaled-by-index trick from Bug 3's fix, rounded *up* so a
   borrower can never sneak a few units of debt that round down to zero (the same rounding
   lesson as Task 2's Bug A, applied here to protect the pool's reserves instead of a vault).
4. **Check both safety caps, but only *after* recording the debt** — checking on the
   *resulting* state (not the state right before the borrow) is deliberate: checking beforehand
   would let one enormous borrow jump straight past a limit in a single step. There are two
   separate caps: utilization can't exceed 80% (so lenders can always get at least 20% of the
   pool back), and the borrower's own LTV can't already be at the liquidation threshold — that
   would let someone open a position and instantly liquidate themselves for the bonus.
5. **Only now, last, send the money out** — this ordering (update your own books completely,
   *then* interact with the outside world) is the exact same checks-effects-interactions
   pattern from Task 2's Bug C. Doing it in this order means a token with a notify-on-receive
   hook can't call back into the pool and borrow twice against the same collateral before the
   first borrow has finished updating the books.

---

## `liquidate()` — the new function, walked through

### The idea first

If a borrower's LTV climbs too high — their debt has grown close to the value of what's backing
it — the pool needs a way to protect itself before that debt becomes genuinely
unrecoverable. The mechanism is: let anyone else ("a liquidator") pay off part of that
borrower's debt, and reward them with a small discount on the collateral in return. This gives
outsiders a financial reason to keep the pool healthy without the pool needing its own capital
to do it.

```solidity
function liquidate(address account, uint256 repayAmount) external nonReentrant returns (uint256 seized) {
    if (repayAmount == 0) revert ZeroAmount();
    accrueInterest();                                          // 1. update the clock first

    uint256 currentDebt = debtOf(account);
    if (currentDebt == 0) revert NoDebt(account);

    uint256 currentLtv = _ltv(account);
    if (currentLtv < LIQUIDATION_LTV) {                        // 2. is this position actually unsafe?
        revert PositionHealthy(account, currentLtv, LIQUIDATION_LTV);
    }

    uint256 maxRepay = mulWad(currentDebt, CLOSE_FACTOR);
    if (repayAmount > maxRepay) revert RepayExceedsCloseFactor(repayAmount, maxRepay);  // 3. not too much at once

    seized = mulWad(repayAmount, WAD + LIQUIDATION_BONUS);      // 4. repaid amount + 5% bonus
    if (seized > collateral[account]) seized = collateral[account];

    scaledDebt[account] -= repayAmount.mulDiv(WAD, borrowIndex, Math.Rounding.Floor);   // 5. update books first
    collateral[account] -= seized;

    ASSET.safeTransferFrom(msg.sender, address(this), repayAmount);   // 6. pull payment in
    ASSET.safeTransfer(msg.sender, seized);                           //    then pay the collateral out
}
```

Step by step:

1. **Accrue interest first, and this direction matters even more here than in `borrow()`.** If
   interest weren't updated first, `debtOf(account)` would *understate* the real debt — a
   position that's genuinely gone underwater could still look artificially healthy, and nobody
   would be able to liquidate it in time. Bad debt would quietly pile up unseen.
2. **Confirm the position is actually unsafe.** `LIQUIDATION_LTV` is 90% — below that,
   liquidating someone would just be taking their money for no reason, so it reverts.
3. **A "close factor" limits how much can be seized in a single liquidation — 50% of the debt,
   max, per call.** Without this, a position that's only barely over the 90% line could be
   wiped out entirely in one shot and charged the full bonus on all of it — turning a small
   dip into a total loss for the borrower. Capping it means liquidation is proportionate to how
   bad the position actually is.
4. **The reward: the liquidator gets back what they paid, plus a 5% bonus, taken from the
   borrower's collateral.** That 5% is the entire incentive for a liquidator to bother — too
   small and nobody would do this job; too large and it over-punishes borrowers for small
   dips.
5. **Update the debt and collateral numbers before moving any money** — the same
   checks-effects-interactions ordering as everywhere else in this project.
6. **Pull the liquidator's payment in before sending the collateral out**, so a liquidator whose
   own payment somehow fails can't walk away with collateral they never actually paid for.

**Worked example.** A borrower posted 1,000 collateral and, after interest accrued, now owes
910 — that's a 91% LTV, above the 90% threshold, so it's liquidatable. A liquidator repays 400
(under the 50%-of-910 close-factor limit). They receive `400 × 1.05 = 420` in collateral. The
borrower's debt drops to `910 − 400 = 510`, and their collateral drops to
`1,000 − 420 = 580`. New LTV: `510 / 580 ≈ 88%` — back under the threshold. The position is
healthy again, the liquidator made a 20-token profit for doing the pool a service, and the
pool is protected from the debt growing further unchecked.

## What was built, in one paragraph

`LendingPool.sol` fixes three bugs that each independently broke a core piece of the pool's
math — utilization was silently always zero (killing both the interest curve and every safety
cap built on it), interest was charged per function-call instead of per unit of real time
(letting anyone inflate every borrower's debt for free), and individual balances never
reflected accrued interest at all (making loans effectively free and hiding bad debt from every
risk check). All three are fixed using WAD-scaled fixed-point math and a shared interest
*index* that lets every account's real balance be computed on demand, in constant time, without
looping over accounts. `borrow()` and `liquidate()` were then implemented on top of that fixed
foundation, with interest always accrued first, both safety caps checked against the resulting
(not prior) state, and money always moved last, after every internal number has already been
updated.
