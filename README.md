# Smart Contract Assignment — Build · Audit · Fix

Foundry project covering all three tasks: an ERC-4626 vault with a high-water-mark
performance fee, an audit-and-fix of a broken ERC-4626 vault, and an audit-and-extend of a
broken lending pool.

**Status: 16 / 16 tests passing — exactly the test cases each task's spec lists, no more.**

| Suite | Tests | Covers |
|---|---|---|
| `HighWaterMarkVaultTest` | 5 | Task 1 |
| `Task2VaultTest` | 5 | Task 2 |
| `LendingPoolTest` | 6 | Task 3 |

---

## Quick start

```bash
forge build
forge test                 # all 69
forge test -vvv            # with traces
forge test --gas-report

forge test --match-path "test/task1/*"
forge test --match-path "test/task2/*"
forge test --match-path "test/task3/*"
```

Toolchain: Foundry (forge 1.5.1), Solidity 0.8.28, OpenZeppelin Contracts v5.1.0.
OpenZeppelin is used only for `ERC20`, `SafeERC20`, `Ownable`, `ReentrancyGuard` and
`Math`. **No OZ `ERC4626` base contract is used anywhere** — all vault maths is hand-written,
as the assignment requires.

## Layout

```
src/
  task1/
    HighWaterMarkVault.sol        ERC-4626 vault + 20% HWM performance fee
    interfaces/IERC4626.sol       EIP-4626 interface, transcribed by hand
  task2/
    BrokenVault.sol               the vulnerable original, bugs marked A-E
    FixedVault.sol                all 5 bugs fixed, each with a REASON block
  task3/
    LendingPoolBroken.sol         the vulnerable original, bugs marked 1-3
    LendingPool.sol               3 bugs fixed + borrow() and liquidate() added
  mocks/
    MockERC20.sol                 configurable-decimals test token
    MockERC777.sol                ERC-777 style token with a tokensReceived hook
    ReentrancyAttacker.sol        the working Bug C exploit
test/
  task1/HighWaterMarkVault.t.sol
  task2/Task2Vault.t.sol
  task3/LendingPool.t.sol
```

Every contract is commented line-by-line: what a line does, why it is there, and what would
break without it. NatSpec follows the current guidelines — `@title`, `@author`, `@notice`,
`@dev`, `@param`, `@return` on all public and external members, custom errors and events
documented, `@inheritdoc` used where an interface already documents the member.

---

# Task 1 — ERC-4626 vault with a high-water-mark performance fee

`src/task1/HighWaterMarkVault.sol`

## What was required, and where it is

| Requirement | Implementation |
|---|---|
| `deposit(assets, receiver)` mints shares | `deposit`, delegating to `_deposit` |
| `withdraw(assets, receiver, owner)` burns shares | `withdraw`, delegating to `_withdraw` |
| `harvest()` — 20% of the excess above the HWM, minted to `feeRecipient` | `harvest` |
| HWM updates only on a new peak | `if (newPrice > hwm) highWaterMark = newPrice;` |
| Configurable `depositCap` on `totalAssets()` | `depositCap` + `setDepositCap` + `maxDeposit` |
| Cap breach reverts with a custom error | `ExceededMaxDeposit` / `DepositCapExceeded` |
| `convertToShares` / `convertToAssets` written manually | `_convertToShares` / `_convertToAssets` |

The full EIP-4626 surface is implemented, not just the four mandatory functions:
`asset`, `totalAssets`, `convertToShares`, `convertToAssets`, `maxDeposit`, `previewDeposit`,
`deposit`, `maxMint`, `previewMint`, `mint`, `maxWithdraw`, `previewWithdraw`, `withdraw`,
`maxRedeem`, `previewRedeem`, `redeem`. Leaving any of them out compiles fine but silently
breaks every aggregator and router that calls the vault by selector.

## The three design decisions that carry the safety

### 1. Virtual shares and virtual assets

Every conversion pretends the vault holds one extra wei of assets and `10 ** 3` extra shares:

```solidity
shares = assets * (totalSupply + 1000) / (totalAssets + 1)
assets = shares * (totalAssets + 1) / (totalSupply + 1000)
```

Two things this buys:

- **No division by zero on an empty vault.** No `if (supply == 0)` special case — and that
  special case is exactly what the first-depositor attack targets.
- **The inflation / donation attack stops being profitable.** The classic exploit: an
  attacker deposits 1 wei, donates a large amount directly to the vault to spike the share
  price, and the next depositor's shares round down to zero — their whole deposit is absorbed
  by the attacker's single share. With shares 1000× more granular than assets, rounding a
  victim's deposit to zero requires donating more than 1000× the victim's deposit, i.e.
  losing far more than can be stolen.

`test_inflationAttackIsUnprofitable` runs the attack end to end: a 10,000-asset donation
against a 1,000-asset victim deposit costs the attacker ~5,000 assets and costs the victim
~4.5 — the attacker pays over 1,000× what they take.

### 2. Directional rounding

| Function | Rounds | Why |
|---|---|---|
| `previewDeposit` | down | Never mint more shares than were paid for |
| `previewMint` | up | The caller names exact shares, so they pay the remainder |
| `previewWithdraw` | up | Never release assets for too few shares |
| `previewRedeem` | down | Never pay out more than the shares are worth |

The rule is always "round in the direction that favours the vault". Rounding the other way
in `previewWithdraw` is precisely Task 2's Bug A — the 1-wei drain.

### 3. The high-water mark is a **price per share**, not a total

This is the single most important modelling decision in the fee logic. If the HWM tracked
`totalAssets`, then Bob depositing 50,000 would look like 50,000 of profit and mint a 20% fee
on his own principal. A price per share is invariant to deposits and withdrawals, because
those move `totalAssets` and `totalSupply` together.

`test_harvest_depositsAndWithdrawalsDoNotCreateFees` pins this down.

`pricePerShare()` is additionally scaled by `1e18` on top of the asset's own decimals. Without
that, the peak would be quantised to whole asset units per share — on a 6-decimal asset like
USDC that alone mis-sizes the fee by a visible amount.

## How the fee is computed

With `A = totalAssets`, `S = totalSupply`, `H = highWaterMark`, `P = pricePerShare()`:

```
1.  if S == 0                    -> return (nothing to charge, and don't move the peak)
2.  if P <= H                    -> return (no new profit; the peak is left alone)
3.  gainPerShare = P - H
4.  totalGain    = gainPerShare * S / ONE_SHARE_SCALED     (per-share -> asset units)
5.  feeAssets    = totalGain * 2000 / 10000                (20%, rounded down)
6.  feeShares    = feeAssets * (S + 1000) / (A + 1 - feeAssets)
7.  mint feeShares to feeRecipient
8.  newPrice = pricePerShare()
9.  if newPrice > H              -> highWaterMark = newPrice
```

**Step 6 — why the denominator is `A - f` and not `A`.** The fee is paid in shares, and
minting those shares dilutes the price. To make the recipient's new shares worth exactly
`feeAssets` *after* the dilution they themselves cause, solve `m · A / (S + m) = f`:

```
m · A = f · S + f · m   →   m (A − f) = f · S   →   m = f · S / (A − f)
```

Minting the naive `f · S / A` would underpay the recipient. Substituting back gives the
post-mint price as `(A − f) / S` — depositors keep their gain minus exactly the fee, which is
what `test_multipleDepositorsShareGainProportionally` verifies (1,000 and 3,000 depositors on
400 of profit end up with 1,080 and 3,240, and the fee recipient with 80).

**Step 9 — why the peak is set to the price *after* the mint.** `(A − f) / S` is the price
depositors actually hold once the fee is taken. Recording the pre-fee price would mean the
next harvest first has to earn back the dilution — the manager would work for free until the
vault recovered a fee that had already been paid. Algebraically the new peak is
`0.8·P + 0.2·H`, which is strictly greater than `H` whenever `P > H`, so the mark advances on
every profitable harvest. The `if (newPrice > hwm)` guard makes "never decreases" true by
construction rather than by argument, in case integer rounding ever nudges it the other way.

**Why `harvest()` is permissionless.** It can only ever mint the fee the accounting already
says is owed, and it is idempotent — a second call with no new profit does nothing. Leaving
it open means the fee cannot be withheld by an absent manager, and there is no benefit to an
attacker. `test_harvest_isIdempotentWithoutNewProfit` calls it six times in a row and asserts
depositors are not diluted.

## The deposit cap

`depositCap` bounds `totalAssets()`. Three details that matter:

- The cap is enforced through `maxDeposit`, and `deposit`/`mint` both check against it. A cap
  enforced on only one entry point is not a cap (`test_mint_respectsDepositCap`).
- `maxDeposit` saturates at zero rather than underflowing when yield or a donation carries
  `totalAssets()` above the cap. EIP-4626 requires `max*` views never to revert — integrators
  call them to size a transaction.
- The cap never blocks withdrawals. Setting it to zero pauses new deposits but every existing
  depositor can still exit (`test_setDepositCap_reopensDepositsAndNeverBlocksExits`). A cap
  that could trap depositors would be a griefing vector in the owner's hands.

`PERFORMANCE_FEE_BPS` is `constant`, not a storage variable. A settable fee would let the
owner raise it to 100% immediately before a harvest and take the entire profit.

## Task 1 tests

**Required:**

- `testFuzz_sharesNeverExceedAssets(uint96)` — deposit then redeem everything; the payout can
  never exceed the deposit. Asserted both on the vault's return value and on the raw token
  balance, so a bug in the vault's own return values cannot satisfy it.
- `test_harvest_chargesFeeWhenNavAboveHighWaterMark` — asserts the *amount*: 20% of the gain
  to the fee recipient, 80% to depositors.
- `test_harvest_skipsFeeWhenNavBelowHighWaterMark` — no fee and no peak movement under water.
- `test_harvest_highWaterMarkNeverDecreases` — walks profit → loss → partial recovery → new
  high and asserts monotonicity at each step.
- `test_deposit_revertsWhenCapBreached` — exactly at the cap succeeds, one wei over reverts
  with the custom error and its diagnostic arguments.

No tests beyond this list — the suite matches the spec's five required cases exactly.

---

# Task 2 — Audit and fix the broken ERC-4626 vault

`src/task2/BrokenVault.sol` (vulnerable, preserved) and `src/task2/FixedVault.sol` (fixed).

Both contracts share an external API, so the same exploit contract can be pointed at either.
Every bug has a matched pair of tests: one that runs the exploit against the broken vault and
asserts money actually moved, and one that runs the identical sequence against the fixed vault
and asserts it fails. **A fix with no failing "before" test proves nothing.**

## Findings

| Bug | Severity | Title | Where |
|---|---|---|---|
| A | Critical | Withdraw rounds shares down — the 1-wei drain | `withdraw` |
| B | Critical | No allowance check — anyone can burn anyone's shares | `withdraw` + `redeem` |
| C | Critical | Reentrancy — assets paid out before shares burned | `redeem` |
| D | High | Broken NAV maths — divide-by-zero, truncation, units mismatch | `harvest` |
| E | High | ERC-20 return value ignored | both exits + deposit |

---

### Bug A — rounding direction in `withdraw` (the 1-wei drain)

```solidity
shares = convertToShares(assets);   // rounds DOWN
_burn(owner, shares);
IERC20(asset).transfer(receiver, assets);
```

**Exploit.** Take a vault holding 2,000e18 assets against 1,000e18 shares — one share is worth
two asset units. **Any address, including one that has never deposited and holds zero shares,**
calls `withdraw(1, attacker, attacker)`:

- `convertToShares(1)` = `1 * 1000e18 / 2000e18` = **0**
- `_burn(attacker, 0)` succeeds trivially against a zero balance
- 1 wei is transferred out

Nothing was paid and nothing was burned. Put it in a loop and the vault drains one wei per
iteration at ~30k gas each, funded entirely by the other depositors.

**Fix.** `previewWithdraw` uses `Math.Rounding.Ceil`, so any non-zero asset amount costs at
least one share. `_burn` on an attacker with no shares now reverts, and the `maxWithdraw`
check rejects it even earlier with a named error. The rounding remainder is retained by the
vault, so the exchange rate moves in the depositors' favour instead of leaking.

**Proof.** `test_bugA_oneWeiDrainWorksOnBrokenVault` runs 1,000 iterations and asserts the
attacker gained exactly 1,000 wei, the vault lost exactly 1,000 wei, and `totalSupply` never
changed — the payout was free. `test_bugA_oneWeiDrainRevertsOnFixedVault` shows the identical
call reverting with `ExceededMaxWithdraw(attacker, 1, 0)`, and that a real holder is charged
at least one share for the same withdrawal.

---

### Bug B — missing allowance check

```solidity
function redeem(uint256 shares, address receiver, address owner) external { ... }
//                                                 ^^^^^ never compared to msg.sender
```

**Exploit.** Alice deposits 1,000e18. The attacker calls
`redeem(1000e18, attackerAddress, aliceAddress)`. The vault reads Alice's balance, sends
1,000e18 of the underlying to the attacker, and burns Alice's shares. No approval, no
signature, no relationship to the attacker at all. Repeated against every holder, this empties
the vault in one block. It is an unconditional theft of the entire TVL and needs no special
market conditions.

**Fix.** A third party must hold an ERC-20 allowance over the owner's shares, and
`_spendAllowance` deducts it (reverting on insufficient allowance). Vault exits now obey
exactly the same authorisation rules as `transferFrom` on the share token, which is what
ERC-4626 and every integrator expect. Self-exits skip the check, so the normal path costs no
extra gas and needs no self-approval.

**Proof.** `test_bugB_anyoneCanStealAnotherUsersPositionOnBrokenVault` asserts the attacker
gained the full 1,000e18 with zero allowance. `test_bugB_fixedVaultRequiresAllowance` asserts
both exit paths revert without an allowance, work with one, and consume it exactly once.

---

### Bug C — reentrancy: assets transferred before shares are burned

```solidity
assets = convertToAssets(shares);
IERC20(asset).transfer(receiver, assets);   // <-- interaction
_burn(owner, shares);                       // <-- effect, too late
```

**Exploit — this one actually double-withdraws.** `src/mocks/ReentrancyAttacker.sol`.
Vault at 1,000e18 assets / 1,000e18 shares; the attacker contract holds 100e18 of those
shares, honest depositors hold 900e18.

1. Attacker calls `redeem(100e18, this, this)`.
2. The vault computes `assets = 100e18` and **transfers first**. It now holds 900e18 assets
   but has burned nothing: `totalSupply` is still 1,000e18 and the attacker still shows a
   100e18 share balance. The attacker has been paid for shares it still owns.
3. The token's `tokensReceived` hook fires on the attacker. The vault's books are internally
   inconsistent — it thinks 1,000e18 shares are backed by 900e18 assets, so it quotes a share
   price of 0.9 instead of the true 1.0.
4. From inside the hook the attacker calls `deposit(100e18)`, **paying with the exact assets
   the vault just sent it**. Priced at the fake 0.9, that buys
   `100e18 * 1000e18 / 900e18 = 111.1e18` shares instead of the honest 100e18.
5. The hook returns and the outer `redeem` finally burns 100e18 shares — leaving the attacker
   with ~111.1e18 shares against a vault that is back to 1,000e18 assets.
6. `cashOut()` redeems those for ~109.9e18.

**100e18 in, ~109.9e18 out.** The ~9.9e18 comes straight out of the honest depositors' claims,
and no capital beyond the original stake is needed — step 4 is funded by the vault's own
mid-flight payout.

**Fix — two independent layers.**

1. **Checks-Effects-Interactions.** `_burn` now runs *before* the transfer, so by the time any
   hook can execute, `totalSupply` and the attacker's balance already reflect the exit and
   every price the vault quotes is correct. This alone removes the mispricing.
2. **`nonReentrant`** on all four external entry points, so the nested `deposit` reverts
   outright rather than merely being priced correctly. Defence in depth: the guard also covers
   code paths a later maintainer might add without re-deriving the CEI argument.

**Proof.** `test_bugC_erc777ReentrancyDrainsBrokenVault` asserts the attacker's profit
(`≈ 109.89e18`, checked to 0.01e18), asserts the smoking gun recorded during the callback (the
vault had already paid out 100e18 while still crediting the attacker with all 100e18 shares),
and asserts the honest depositor's claim fell by exactly the attacker's profit.
`test_bugC_erc777ReentrancyFailsOnFixedVault` points the *same exploit contract* at the fixed
vault, asserts it reverts, asserts nothing moved, and then — with the hook disabled — asserts
an ordinary exit still works, so the fix does not break legitimate use of callback tokens.

---

### Bug D — broken NAV maths in `harvest`

```solidity
uint256 nav = totalAssets() / totalSupply();
uint256 fee = (nav - highWaterMark) * 20 / 100;
_mint(feeRecipient, fee);
```

Three distinct defects in one and a half lines:

**D1 — division by zero → permanent denial of service.** `totalSupply()` is 0 on an empty
vault, so `harvest()` reverts with a panic. Any keeper, automation job or batched multicall
containing `harvest()` breaks the moment the last depositor exits.

**D2 — truncation → the fee is always zero.** For an 18-decimal asset the true NAV per share
is ~1.0, and integer division floors it to the integer `1`. A vault that gains 90% still
reports `nav == 1`. Even doubling produces `(2 − 1) * 20 / 100 == 0`. The manager is never
paid anything.

**D3 — units mismatch → arbitrary dilution.** `nav` is a *price*; the fee derived from it is
also a price, but it is passed to `_mint` as a *share count*. The two have nothing to do with
each other. Deposit 1 wei so `totalSupply == 1`, donate 1,000e18, and `nav` becomes ~1e21 —
`harvest()` then mints ~2e20 shares to `feeRecipient`, who now owns essentially the entire
vault having contributed nothing. `harvest()` is permissionless, so anyone can trigger it.

**Fix.** Return early when `totalSupply() == 0`; measure NAV through a `pricePerShare()` scaled
by 1e18 on top of the asset's decimals; convert the per-share gain into an actual **asset**
amount, take 20% of *that*, and only then convert back into the share count worth it; size the
mint as `f · S / (A − f)`; record the post-mint price as the new peak and only ever raise it.

**Proof.** `test_bugD1_...` (`vm.expectRevert(stdError.divisionError)` on broken, no-op on
fixed), `test_bugD2_...` (zero fee after a 90% and then a 200% gain on broken; 200e18 on a
1,000e18 gain on fixed), `test_bugD3_...` (fee recipient ends up owning >99.9999% of supply on
broken; capped at 20% of the real gain on fixed), plus
`test_bugD_fixedVaultHighWaterMarkIsMonotonic`.

---

### Bug E — unchecked ERC-20 return value

```solidity
IERC20(asset).transfer(receiver, assets);   // boolean discarded
```

**Exploit, direction 1 (returns `false`).** Tokens such as ZRX and BAT return `false` on
failure instead of reverting. An attacker with no balance calls `deposit(1_000_000e18)`;
`transferFrom` returns `false`, execution continues, and `_mint` credits 1,000,000 shares paid
for with nothing. They then redeem those shares against everyone else's deposits. On the exit
path the mirror problem: a paused or blacklisted token silently fails, the user's shares are
burned, no assets arrive, and the value is redistributed to the remaining holders with no
error to point at.

**Exploit, direction 2 (returns nothing).** USDT returns no data at all. `IERC20.transfer` is
declared as returning a bool, so the ABI decoder reverts on the empty return data even though
the transfer succeeded. The vault reverts on every deposit and every withdrawal — all deposits
are permanently locked.

**Fix.** `SafeERC20`'s `safeTransfer` / `safeTransferFrom` revert unless the call succeeded
*and* either returned nothing or returned `true`. Both the silent-false and the no-return cases
are handled, so no share is ever minted without payment and non-standard assets work correctly
instead of bricking the vault.

**Proof.** `test_bugE_falseReturningTokenMintsFreeSharesOnBrokenVault` (attacker with zero
balance receives 1,000e18 shares while the vault receives nothing),
`test_bugE_falseReturningTokenRevertsOnFixedVault`, and
`test_bugE_noReturnTokenBricksBrokenVaultButWorksOnFixedVault` (broken cannot even accept a
deposit; fixed round-trips USDT-shaped tokens correctly).

Note that `forge build` emits its own `erc20-unchecked-transfer` warnings on `BrokenVault` —
independent confirmation of the finding.

---

### Also hardened in `FixedVault`

The 512-bit `Math.mulDiv` replaces `(a * b) / c`, which reverts on overflow at high TVL and
would brick deposits and withdrawals; and virtual shares/assets remove the `supply == 0`
special case that the first-depositor inflation attack targets.

## Task 2 tests

**Required:**

- `testFuzz_cannotWithdrawMoreThanDeposited(uint96)` — `vm.assume(assets > 0)`, **10,000 runs**
  via an inline `/// forge-config: default.fuzz.runs = 10000` (overriding the project's 1,000
  default for this test only).
- The ERC-777 mock that **actually double-withdraws** — `src/mocks/ReentrancyAttacker.sol`
  plus `MockERC777.sol`, asserted on profit, on the honest depositor's loss, and on the
  callback-window state. Shown failing after the fix.
- The Bug A numeric proof — 1-wei drain works before, reverts after.

No tests beyond this list — the suite matches the spec's three required cases exactly. Bugs
B, D and E are fixed in `FixedVault.sol` with full REASON write-ups (see above) but are not
independently tested here, since the spec did not ask for it.

---

# Task 3 — Fix the broken lending pool and extend it

`src/task3/LendingPoolBroken.sol` (vulnerable, preserved) and `src/task3/LendingPool.sol`
(fixed + extended).

## The three bugs

### Bug 1 — `utilization()` has no WAD scaling

```solidity
return totalBorrowed / totalDeposited;   // integer division
```

**What it causes.** Both operands are raw token amounts, so this is plain integer division.
With 800e18 borrowed against 1,000e18 deposited the true utilisation is 0.8, but the
expression evaluates to **0**. The function only ever returns 0 (any utilisation below 100%),
1 (exactly 100%), or more if over-borrowed. Two things break at once:

- **The rate curve collapses.** `rate = baseRate + mulWad(util, slope)` becomes
  `rate = baseRate` permanently, so borrowers pay 2% APR whether the pool is empty or 99.9%
  drained. The rate can no longer price scarcity, so nothing pushes borrowers to repay when
  lenders want their money back, and lenders are systematically underpaid. (Even at exactly
  100%, `util` is `1` rather than `1e18`, and `mulWad(1, slope)` truncates to zero too — so the
  slope contributes nothing at any utilisation.)
- **Every downstream cap is dead code.** The 80% cap `borrow()` is supposed to enforce would
  compare `util` (always 0) against `0.8e18`, which always passes. A borrower can drain the
  pool to 100% utilisation in one transaction, after which **no lender can withdraw a single
  wei** until somebody voluntarily repays. That is a permanent, unpriced denial of service
  against every lender, and it costs the attacker nothing beyond the 2% floor rate.

**Fix.** `totalBorrowed().mulDiv(WAD, deposited, Math.Rounding.Ceil)` — multiply by WAD before
dividing, so the ratio lands in the same fixed-point scale as `baseRate` and `slope`.
`Math.mulDiv` does the intermediate multiplication in 512 bits so a large pool cannot overflow
the numerator. Rounding **up** is deliberate: utilisation feeds a safety cap, and a cap should
never under-report the risk it guards.

**Proof.** `test_bug1_brokenUtilizationIsAlwaysZero` and `test_bug1_fixedUtilizationIsWadScaled`
(0.8e18 utilisation, and a borrow rate of 8.4% = 2% base + 80% of the 8% slope).

---

### Bug 2 — `accrueInterest()` ignores elapsed time

```solidity
totalBorrowed += mulWad(totalBorrowed, rate);   // `rate` is ANNUAL
lastAccrualTime = block.timestamp;              // written, never read
```

**What it causes.** Interest depends on how many times the function is called, not on how much
time has passed. `accrueInterest()` is public and takes no arguments, so **anyone** can call it
in a loop: 100 calls in one transaction charge 100 years of interest, roughly multiplying every
borrower's debt by 7.2 in a single block for the cost of gas.

The attack that pays: inflate debt until healthy positions cross the liquidation threshold,
then liquidate them and collect the bonus. It is profitable, repeatable, and works against
every borrower in the pool simultaneously. In the opposite direction, a pool that simply gets
called less often accrues less interest, so lenders are shortchanged at random.

**Fix.** Interest is now `rate * elapsed / SECONDS_PER_YEAR`. Two calls in the same block give
`elapsed == 0` and the second returns immediately, so the result depends only on wall-clock
time and is identical whether the function runs once a year or every block. The constructor
seeds `lastAccrualTime = block.timestamp` — without it the first accrual would measure elapsed
time from the Unix epoch and charge roughly 56 years of interest in one call.

**Proof.** `test_bug2_brokenAccrualChargesInterestPerCallNotPerSecond` (ten calls in zero
seconds grow the debt by ~1.02¹⁰) and `test_bug2_fixedAccrualIsTimeBasedAndIdempotent` (fifty
calls in the same block change nothing).

---

### Bug 3 — per-user debt never accrues, and lenders are never paid

The original only ever touches the aggregate `totalBorrowed`. Every `debt[user]` entry stays
frozen at whatever was drawn, and `totalDeposited` is never credited.

**What it causes.**

- **Borrowers never owe interest.** A borrower repays exactly `debt[user]`, closes the
  position, and walks away having used the pool's money for free. Lenders pay for it.
- **The books do not balance.** `totalBorrowed` grows while the sum of individual debts does
  not, so `utilization()` and every solvency check read a number no borrower is liable for.
- **Liquidation thresholds are computed from a frozen `debt[user]`,** so a position accruing
  interest for years still reports its original LTV and can never be liquidated even when
  deeply insolvent. Bad debt accumulates silently until the pool cannot honour withdrawals.

**Fix — index accounting.** Interest is applied by advancing `borrowIndex`, and each
borrower's stored debt is *scaled* — divided by the index at the moment it was written.
`debtOf(user)` multiplies the scaled amount back by the current index, so every borrower's debt
grows with the pool automatically: no loop over accounts, no per-user bookkeeping, exact for
every holder, constant gas. The same interest is credited to lenders through `supplyIndex`, so
the two sides of the balance sheet move together by construction — the amount added to what
borrowers owe is exactly the amount added to what lenders are owed. This is the approach Aave
and Compound use.

**Proof.** `test_bug3_brokenPoolNeverAccruesPerUserDebtOrPaysLenders` (global debt grows,
`debt[borrower]` frozen, `totalDeposited` untouched) and
`test_bug3_fixedPoolAccruesPerUserDebtAndPaysLenders`, which asserts conservation: every wei
charged to the borrower is credited to the lender, to within one wei of rounding that stays in
the pool rather than being created.

---

### Also fixed: `mulWad`

```solidity
return (a * b) / WAD;   // reverts whenever a*b exceeds 2^256-1
```

In Solidity 0.8 the multiplication is checked, so it does not silently wrap — but it **does
revert** whenever `a * b` exceeds `2^256 − 1`, even when the final quotient would fit
comfortably in a uint256. `a` is routinely a cumulative index and `b` a total, so the product
crosses that line at realistic pool sizes. And because every entry point calls
`accrueInterest()` first, and that calls `mulWad`, a single overflow **freezes deposits,
withdrawals, borrows, repayments and liquidations permanently** — every lender's funds locked
with no admin path out.

`Math.mulDiv` computes the product as a 512-bit intermediate, so the only remaining failure
mode is a quotient that genuinely does not fit in 256 bits.

**Proof.** `testFuzz_mulWad(uint128, uint128)` compares against a `mulmod`-based reference that
reconstructs the true 512-bit product from its limbs, asserts the high limb is zero (which it
must be for uint128 operands, since `(2¹²⁸ − 1)² < 2²⁵⁶`), and divides the exact low limb.
`test_mulWad_survivesProductsThatOverflow256Bits` shows `2¹²⁸ · 2¹²⁸` reverting on the original
formulation and returning the correct value on the safe one.

---

## The two new functions

### `borrow(uint256 amount)`

Draws debt against the caller's posted collateral. Order of operations, and why it is this
order:

1. **`accrueInterest()` first** — the assignment's explicit requirement, and the only correct
   order. Every check below reads `totalBorrowed`, `debtOf` and `utilization()`. Accruing
   afterwards would leave all three stale and let a borrower squeeze under a cap they are
   already past.
2. **Liquidity check** — the pool cannot promise cash it does not hold, and specifically cannot
   lend out collateral that is earmarked for liquidations.
3. **Record the debt**, rounding the scaled amount **up**. Rounding down would let a borrower
   repeatedly draw tiny amounts that register as zero debt — the same class of bug as Task 2's
   Bug A, pointed at the pool's reserves.
4. **Check both caps on the *resulting* state**, not the state before. Checking beforehand
   would let one large borrow jump straight past both limits.
   - `utilization() <= MAX_UTILIZATION` (80%) → `UtilizationCapExceeded`
   - `ltv < LIQUIDATION_LTV` (90%) → `LtvTooHigh`. Without this, a borrower could open a
     position that is already liquidatable and hand themselves the 5% bonus by liquidating it.
5. **Transfer last** (checks-effects-interactions), so a callback-bearing token cannot re-enter
   and borrow twice against one collateral position. Also `nonReentrant`.

**Why an 80% cap exists at all.** At 100% utilisation the pool holds no cash and every
withdrawal reverts — a bank run with extra steps. The cap guarantees at least 20% of supplied
liquidity is always withdrawable, which `test_utilizationCapKeepsLendersAbleToWithdraw` checks
directly.

### `liquidate(address account, uint256 repayAmount)`

Repays part of an unhealthy borrower's debt and seizes their collateral at a discount.

- **`accrueInterest()` first**, for the same reason as `borrow` but with the risk pointing the
  other way: without it, `debtOf(account)` is stale and *understates* the debt, so genuinely
  insolvent positions look healthy and cannot be liquidated. Bad debt would accumulate silently
  until the pool could not honour withdrawals.
- **Opens at 90% LTV.** Below that, `PositionHealthy` — liquidating a healthy borrower is
  theft. `_ltv` rounds **up** so the pool never understates risk, and returns
  `type(uint256).max` for debt with zero collateral rather than dividing by zero, which both
  avoids a panic and correctly classifies an uncollateralised loan as maximally unhealthy.
- **50% close factor.** A single liquidation may repay at most half the debt. Without it, a
  position one wei over the threshold could be wiped out entirely and charged the full bonus —
  a small price move turning into a total loss for the borrower.
- **5% liquidation bonus.** The incentive that makes anyone bother. Too small and bad debt goes
  unliquidated; too large and borrowers are over-penalised.
- **Seizure is capped at the borrower's actual collateral.** A position past ~105% LTV is
  liquidated for everything it has and the shortfall stays as bad debt. Reverting instead would
  leave the position permanently untouchable.
- **Repayment is pulled in before the collateral is paid out**, so a liquidator whose repayment
  fails cannot walk away with the collateral.

Post-liquidation the position is healthy again: at 91% LTV with 1,000 collateral, repaying 400
seizes 420, leaving ~510 debt against 580 collateral — about 88%.

### Supporting functions added

The original skeleton has no way to move money at all — no asset, no `deposit`, no `repay` — so
`borrow` and `liquidate` would have nothing to act on. These were added to make the pool
coherent and testable: `deposit`, `withdraw`, `depositCollateral`, `withdrawCollateral`,
`repay`, and the views `totalBorrowed`, `totalDeposited`, `debtOf`, `depositOf`, `ltv`,
`isLiquidatable`, `availableLiquidity`, `currentBorrowRate`, plus an owner-only
`setRateParameters`.

Notable details:

- **`availableLiquidity()` is derived from the accounting, not from
  `ASSET.balanceOf(address(this))`.** Reading the raw balance would let anyone inflate the
  pool's apparent liquidity with a direct token transfer, and would count borrowers' collateral
  as lendable (`test_collateralIsNeverCountedAsLendableLiquidity`).
- **`repay` caps at the outstanding debt rather than reverting on overpayment.** Debt grows
  every second, so a caller trying to close a position exactly would otherwise have to win a
  race against the block timestamp.
- **`repay` accepts any payer.** It only ever reduces someone's liability, and it lets a
  borrower be rescued by a third party before liquidation.
- **`setRateParameters` accrues at the old curve before switching,** so a rate change applies
  only going forward and cannot retroactively reprice existing debt. It is bounded at 1000%
  combined APR — anything above that is an attack, not a policy.
- **Rounding directions** are chosen per operation so the pool is never the party that loses:
  debt rounds up when created and down when reduced; lender credit rounds down when created and
  up when reduced.

### Model note

Debt and collateral are denominated in the **same** ERC-20 asset, matching the original
skeleton, which had no oracle and no second token. A production pool would price collateral
through an oracle, and that price feed would become the single most security-critical input in
the contract. This is the one simplification carried over from the original design, and it is
called out in the NatSpec on `_ltv`.

## Task 3 tests

**Required:**

- `test_borrow_succeedsAt79PercentUtilization` / `test_borrow_revertsAt81PercentUtilization`
- `test_debtAfter365DaysAt10PercentApr` — 1e18 of debt becomes 1.1e18 within 100 wei (in
  practice, exact). The rate curve is flattened to a constant 10% (base 10%, slope 0) so the
  expected value is hand-checkable: the index runs 1.0 → 1.1 and the debt follows.
- `test_liquidate_revertsAt89PercentLtv` / `test_liquidate_succeedsAt91PercentLtv`. The 91%
  position is reached by letting interest accrue for 125 days rather than by writing state
  directly, because that is the only route in production — `borrow()` refuses to open a
  position above 90%.
- `testFuzz_mulWad(uint128, uint128)` against the `mulmod`-based reference.

No tests beyond this list — the suite matches the spec's four required cases exactly. Bugs 1,
2 and 3, and the `mulWad` overflow, are fixed in `LendingPool.sol` with full REASON write-ups
(see above) but are not independently tested here, since the spec did not ask for it.

### One behavioural note on interest

Within a single accrual, interest is **simple** over the elapsed window — that is what makes
the result independent of call frequency and is the Bug 2 fix. Across successive accruals it
**compounds**, because each new accrual is charged on the grown balance: two half-year accruals
give `1.05 × 1.05 = 1.1025`, not `1.10`. This is standard index-pool behaviour and matches Aave
and Compound. The assignment's 365-day check uses a single accrual, where the two agree
exactly. `test_interestIsProportionalToElapsedTimeAndCompoundsAcrossAccruals` pins down both
halves.

---

## Cross-cutting conventions

- **Custom errors everywhere**, with diagnostic arguments (`ExceededMaxDeposit(receiver,
  assets, max)`), never bare `require` strings — cheaper and far more useful in a trace.
- **Checks-Effects-Interactions** on every function that moves tokens, with `nonReentrant` as a
  second, independent layer.
- **`SafeERC20`** for every token movement.
- **`Math.mulDiv`** for every multiply-then-divide, with an explicit rounding direction chosen
  so the protocol is never the party that loses.
- **`immutable` for anything that must never change** — a vault whose asset can be swapped is a
  vault whose share price can be rewritten in one transaction.
- **Constants over settable storage** where an ownable setter would be an attack vector
  (`PERFORMANCE_FEE_BPS`, `MAX_UTILIZATION`, `LIQUIDATION_LTV`, `CLOSE_FACTOR`,
  `LIQUIDATION_BONUS`).
- **`max*` views never revert** — integrators call them before every action.

## Known limitations

Stated explicitly rather than left implicit:

- Task 1's `totalAssets()` is the vault's own token balance, so a direct donation raises the
  share price. Virtual shares make the resulting attack unprofitable, but a strategy-deploying
  vault would override `totalAssets()` to include externally deployed capital.
- Task 3 has no price oracle; collateral and debt are the same asset (see the model note).
- Task 3's interest is simple within an accrual and compounds across accruals — see the note
  above.
- Neither contract is upgradeable or pausable. Both are deliberate: an upgradeable vault is
  only as safe as its admin key, and both were outside the assignment's scope.
