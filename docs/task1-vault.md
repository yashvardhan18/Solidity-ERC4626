# Task 1 — The Vault, Explained Simply

## The one idea everything else builds on

Picture a big glass jar that anyone can put money into. Every time you put money in, you get a
paper ticket that says how big a slice of the jar is yours. That ticket is a **share**. The jar
itself is the **vault**. The money in the jar is the **asset**.

If the jar only ever holds still, your ticket is worth exactly what you put in. But if someone
manages the jar and grows the pile of money inside it — the vault contract calls this
**yield** — your ticket becomes worth *more* than what you originally paid, because the same
number of tickets now points at a bigger pile.

That's the entire idea of an ERC-4626 vault: **shares are a claim on a growing pot of money.**
Everything in `HighWaterMarkVault.sol` is either bookkeeping for that claim, or logic for
paying the person who manages the jar a cut of the growth.

## What the task asked for

1. A vault that mints shares on deposit and burns them on withdrawal — written by hand, not
   using OpenZeppelin's ready-made ERC-4626 contract, so every formula had to be derived from
   scratch.
2. A **performance fee**: whenever the jar's per-ticket value hits a new all-time high, the
   manager takes 20% of *that specific gain* as newly-printed tickets. This is called a
   **high-water mark (HWM)** fee — the manager only ever gets paid for genuinely new profit,
   never for the same profit twice.
3. A **deposit cap** — a maximum size the jar is allowed to grow to via new deposits.
4. Tests proving all of that actually holds up.

## The core formula: how many tickets is your money worth?

Every vault needs two conversions:

- **Assets → Shares** (when you deposit: how many tickets do I get for my money?)
- **Shares → Assets** (when you withdraw: how much money is my ticket worth?)

The formula is just "your slice of the jar, in proportion to everyone else's slice":

```
shares = assets × (total tickets in existence) / (total money in the jar)
assets = shares × (total money in the jar) / (total tickets in existence)
```

**Worked example.** Say the jar has 1,000 tokens in it and 1,000 tickets exist (so each ticket
is worth exactly 1 token). You deposit 100 tokens:

```
shares = 100 × 1,000 / 1,000 = 100 tickets
```

Now say the manager earns some yield and the jar grows to 1,100 tokens, while the ticket count
stays at 1,100 (yours plus the original 1,000). Each ticket is now worth `1,100 / 1,100 = 1`
token still — wait, that's only true if the *ticket count grew with the money*. In reality,
yield lands in the jar **without minting new tickets**, so if the jar grows from 1,100 tokens
to 1,210 tokens with still only 1,100 tickets outstanding, each ticket is now worth
`1,210 / 1,100 = 1.10` tokens. That 10% growth is exactly what makes vault shares valuable to
hold — you didn't do anything, your ticket just became worth more.

In the code (`src/task1/HighWaterMarkVault.sol`), this lives in two internal helper functions:

```solidity
function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
    return assets.mulDiv(totalSupply() + _VIRTUAL_SHARES, totalAssets() + _VIRTUAL_ASSETS, rounding);
}

function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
    return shares.mulDiv(totalAssets() + _VIRTUAL_ASSETS, totalSupply() + _VIRTUAL_SHARES, rounding);
}
```

Ignore `_VIRTUAL_SHARES` and `_VIRTUAL_ASSETS` for a moment (explained below) — strip them out
and you get exactly the two formulas above. `Math.mulDiv` is used instead of writing
`(assets * totalSupply()) / totalAssets()` directly because multiplying two very large numbers
before dividing can overflow a normal calculation and make the whole contract crash; `mulDiv`
is a library function that does the multiplication safely under the hood.

## `deposit()` — putting money in

```solidity
function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
    uint256 max = maxDeposit(receiver);
    if (assets > max) revert ExceededMaxDeposit(receiver, assets, max);

    shares = previewDeposit(assets);
    if (shares == 0) revert ZeroAmount();

    _deposit(msg.sender, receiver, assets, shares);
}
```

Read it as four plain steps:

1. **"Is the jar already full?"** — check the deposit cap first, before touching any money.
2. **"How many tickets does this buy?"** — compute it using the formula above, *before* the
   money has actually moved (this matters — see the box below).
3. **"Did that round down to nothing?"** — if someone tries to deposit an amount so tiny it
   would buy zero tickets, reject it. A zero-ticket deposit would just be a donation.
4. **Actually move the money and hand out the tickets** — done in `_deposit`:

```solidity
function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
    _ASSET.safeTransferFrom(caller, address(this), assets);
    _mint(receiver, shares);
    emit Deposit(caller, receiver, assets, shares);
}
```

> **Why quote the price *before* the money moves?**
> If you calculated "how many tickets does this buy" *after* the money had already landed in
> the jar, you'd be using a jar total that already includes the depositor's own cash — which
> means their own money would raise the price they're buying at, and they'd get fewer tickets
> than they should. Quote first, then transfer.

`nonReentrant` on the function signature is a guard that stops a malicious token from calling
back into the vault mid-transaction and doing something sneaky before this function finishes.
More on why that matters in the Task 2 document — it's the fix for one of the five bugs there.

## `withdraw()` — taking money out

```solidity
function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256 shares) {
    uint256 max = maxWithdraw(owner);
    if (assets > max) revert ExceededMaxWithdraw(owner, assets, max);

    shares = previewWithdraw(assets);
    if (shares == 0) revert ZeroAmount();

    _withdraw(msg.sender, receiver, owner, assets, shares);
}
```

Same shape as deposit, mirrored: check you're not asking for more than your tickets are worth,
work out how many tickets that costs, then execute:

```solidity
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
    if (caller != owner) {
        _spendAllowance(owner, caller, shares);
    }
    _burn(owner, shares);
    _ASSET.safeTransfer(receiver, assets);
    emit Withdraw(caller, receiver, owner, assets, shares);
}
```

Two details worth calling out:

- **`caller != owner` check.** Normally you withdraw your own money. But ERC-4626 also allows
  someone *else* to withdraw on your behalf — say, a smart contract managing your position for
  you — as long as you've explicitly approved them (the same "allowance" concept as ERC-20
  `approve`). Without this check, anyone could withdraw anyone else's money. Task 2's `BrokenVault` is missing exactly this check — see that document for what happens when it's absent.
- **Burn before transfer.** The tickets are destroyed *before* the money is sent out, not
  after. This order is also load-bearing for security — again, explained fully in the Task 2
  document, because getting it backwards is Bug C there.

## The performance fee — `harvest()`

This is the part of the assignment with the most moving pieces, so let's build it up slowly
with one continuous numbers example.

### Step 1: what is a "high-water mark"?

A high-water mark is simply **the highest price-per-ticket the jar has ever reached.** The
rule the assignment sets is:

> Charge a fee only on genuinely *new* profit — profit that takes the jar to a price it has
> never been at before. If the jar is below a level it already reached in the past, charge
> nothing, even if this month was itself profitable.

**Why this rule exists.** Imagine the manager could charge a fee any time the price went up
during a month, with no memory of the past. The jar goes: 100 → 110 → 90 → 110. The
naive approach would charge a fee on the 100→110 rise, then *again* on the 90→110 rise — but
that second rise didn't create any new profit at all, it just returned to a level the jar had
already been at. The manager would have been paid twice for the same 10 tokens of profit. A
high-water mark stops that: it only pays the manager when the jar sets a genuinely new record.

### Step 2: the full numeric walkthrough

Say Alice deposits 1,000 tokens into an empty vault. She gets 1,000 tickets (price = 1.0 per
ticket). The vault's high-water mark starts at 1.0 too — the price the jar is *born at* counts
as the very first "peak", so the very first profitable harvest doesn't mistake her own
principal for profit.

**The manager earns 100 tokens of yield.** The jar now holds 1,100 tokens, still 1,000 tickets.
New price = `1,100 / 1,000 = 1.10`. That's above the high-water mark of `1.0`, so a fee is due.

```
gain per ticket   = 1.10 − 1.00 = 0.10
total gain        = 0.10 × 1,000 tickets = 100 tokens        (matches the 100 tokens of yield)
fee (20% of gain) = 100 × 20% = 20 tokens
```

The fee is paid **in newly minted tickets**, not by pulling tokens out of the jar. Why? Because
minting tickets dilutes everyone equally without the manager needing to sell anything or the
vault needing spare cash lying around. The trick is sizing the mint correctly — if you just
naively minted "20 tokens' worth of tickets at today's price", the very act of minting them
would push the ticket count up and slightly lower the price again, so the manager would
actually receive *less* than 20 tokens' worth. The contract solves for the exact number of
tickets that will *still* be worth 20 tokens *after* the dilution:

```solidity
uint256 assetsAfterFee = totalAssets() + _VIRTUAL_ASSETS - feeAssets;
feeShares = feeAssets.mulDiv(supply + _VIRTUAL_SHARES, assetsAfterFee, Math.Rounding.Floor);
```

Continuing the example: the manager receives roughly 18.7 new tickets (not a clean number,
because the tickets have to be worth exactly 20 tokens once they exist). After minting, the
jar still holds 1,100 tokens but now has about 1,018.7 tickets outstanding, so the new price
per ticket is `1,100 / 1,018.7 ≈ 1.0798`. **That new price becomes the new high-water mark.**
Alice's own 1,000 tickets are now worth `1,000 × 1.0798 ≈ 1,079.8` — she kept 80 of the 100
tokens of profit, and the manager's tickets are worth the other 20. This is exactly the 80/20
split the assignment specifies.

### Step 3: the full function

```solidity
function harvest() external nonReentrant returns (uint256 feeShares) {
    uint256 supply = totalSupply();
    if (supply == 0) return 0;                              // an empty jar has no price to speak of

    uint256 currentPrice = pricePerShare();
    uint256 hwm = highWaterMark;
    if (currentPrice <= hwm) {                               // no new record — charge nothing
        emit HarvestSkipped(currentPrice, hwm);
        return 0;
    }

    uint256 gainPerShare = currentPrice - hwm;
    uint256 totalGain = gainPerShare.mulDiv(supply, _ONE_SHARE_SCALED, Math.Rounding.Floor);
    uint256 feeAssets = totalGain.mulDiv(PERFORMANCE_FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Floor);

    if (feeAssets > 0) {
        uint256 assetsAfterFee = totalAssets() + _VIRTUAL_ASSETS - feeAssets;
        feeShares = feeAssets.mulDiv(supply + _VIRTUAL_SHARES, assetsAfterFee, Math.Rounding.Floor);
        if (feeShares > 0) _mint(feeRecipient, feeShares);
    }

    uint256 newPrice = pricePerShare();                       // re-check price AFTER minting
    if (newPrice > hwm) highWaterMark = newPrice;              // record the new peak

    emit Harvest(msg.sender, feeRecipient, feeShares, feeAssets, highWaterMark);
}
```

Line by line, in plain terms:

| Line | What it's doing |
|---|---|
| `if (supply == 0) return 0;` | No tickets exist yet — there's nobody to charge a fee to, and no meaningful price. Just stop. |
| `if (currentPrice <= hwm) { ...; return 0; }` | We're at or below the old record — this is the high-water-mark rule itself. No fee, and crucially the peak is **left unchanged**. |
| `gainPerShare = currentPrice - hwm` | How much richer is each ticket than it's ever been before? |
| `totalGain = gainPerShare * supply` | Scale that "per ticket" number up to "for the whole jar". |
| `feeAssets = totalGain * 20%` | The manager's cut of the *new* profit only. |
| the `assetsAfterFee` / `feeShares` block | The "solve for the right number of tickets" math from Step 2 above. |
| `if (newPrice > hwm) highWaterMark = newPrice;` | Record the fresh peak — but note it's the price measured **after** minting the fee tickets, i.e. the price depositors are actually left holding, not the price before dilution. |

**Why is `harvest()` open for anyone to call, with no owner check?** Because it can only ever
mint the fee that the formula says is owed — there's no way to trick it into minting more, and
calling it twice in a row with no new profit does nothing (the second call hits the
`currentPrice <= hwm` branch and returns 0). Since it can't be abused, there's no reason to
restrict it, and leaving it open means the fee gets collected even if the manager forgets to
call it themselves.

## The deposit cap

```solidity
function maxDeposit(address) public view returns (uint256) {
    uint256 currentAssets = totalAssets();
    if (currentAssets >= depositCap) return 0;
    return depositCap - currentAssets;
}
```

Plain English: "how much more can go in before the jar hits its limit?" If the jar is already
at or past the cap (which can happen — yield can push it over even with no new deposits), the
answer is simply zero, not a crash. `deposit()` calls this and reverts with
`ExceededMaxDeposit` if you ask for more than that.

The owner can move the cap with `setDepositCap`, but the cap **only ever blocks new deposits,
never withdrawals** — setting it to zero pauses the jar to newcomers, it can never trap
existing depositors' money inside.

## Virtual shares and virtual assets — the "always start the jar with a little extra" trick

Look back at the conversion formulas — they don't use `totalSupply()` and `totalAssets()`
directly, they use `totalSupply() + 1000` and `totalAssets() + 1`. Why the padding?

**The problem it prevents, told as a story.** Imagine there were no padding. An attacker is the
very first person to ever use the vault. They deposit 1 tiny unit of currency and receive 1
ticket. Then, instead of depositing normally, they just *send* a huge pile of money straight
into the jar's address (which a plain token transfer can always do, bypassing `deposit()`
entirely). Now the jar holds a huge pile of money but there's still only 1 ticket in existence,
so that one ticket is suddenly worth the *entire* pile. Along comes an honest victim who wants
to deposit a normal amount. The formula `shares = assets * 1 / (huge pile)` rounds down to
**zero tickets** for any deposit that isn't itself gigantic — the victim's money goes into the
jar and they get nothing back for it. The attacker then redeems their single ticket for
everything, including the victim's money. This is called the **inflation attack** or
**donation attack**, and it's one of the best-known ERC-4626 exploits.

**The fix.** Pretend the jar was born with `1000` extra tickets and `1` extra token already in
it, permanently, that nobody actually owns. This makes the "1 real ticket against a huge pile"
trick pointless: with the padding, that same attacker's 1 ticket is now competing against
`1000` phantom tickets for the pile, so the price-per-real-ticket can never be inflated as
dramatically. To push a victim's deposit down to zero shares, the attacker now has to donate
*more than a thousand times* the victim's deposit — which means the attacker loses far more
than they could ever steal. The attack stops being profitable, which is what actually matters;
it doesn't need to be impossible, just not worth doing.

This also quietly solves a second problem: with real code, `totalSupply()` and `totalAssets()`
both start at literal zero on a brand-new vault, and dividing by zero would crash the very
first deposit. The padding means the denominator is never actually zero, so no special
"first deposit ever" case is needed anywhere in the code.

## Rounding: which way, and why it always favors the jar

Every conversion in the contract rounds in a specific direction, and the direction always
protects the jar rather than the caller:

| Function | Rounds | Plain-English reason |
|---|---|---|
| `previewDeposit` (buying tickets) | down | Never hand out slightly more tickets than were actually paid for. |
| `previewMint` (buying an exact number of tickets) | up | You named the exact ticket count, so you cover the rounding remainder, not the other depositors. |
| `previewWithdraw` (naming an exact payout) | up | Never let someone cash out for more than their tickets are worth. |
| `previewRedeem` (cashing in an exact number of tickets) | down | Same idea, mirrored. |

**Why does the direction matter at all, concretely?** Suppose rounding for withdrawals went
the *other* way (down instead of up). Someone could ask to withdraw a tiny amount — small
enough that the true cost is a fraction of a ticket — and if that rounds *down* to zero
tickets, they'd get paid for free, with nothing burned. Repeat that a thousand times and the
jar is drained for nothing. Rounding up instead means any non-zero payout always costs at
least one whole ticket. (This exact bug, done the wrong way round, is Bug A in the Task 2
document — it's worth reading alongside this section.)

## What was built, in one paragraph

`HighWaterMarkVault.sol` implements the full ERC-4626 interface by hand: deposit, withdraw,
mint, redeem, and every `preview`/`max` helper the standard requires, all built from the same
two conversion formulas. A configurable `depositCap` blocks new deposits (never withdrawals)
once the jar is full. `harvest()` charges a 20% fee purely on genuinely new profit, measured as
"has the price-per-ticket ever been this high before", paid as newly minted tickets sized to be
worth exactly the right amount after their own dilution. Virtual shares and assets make the
classic first-depositor inflation attack unprofitable and remove the empty-vault
divide-by-zero as a side effect. Every conversion rounds in the direction that protects
existing depositors.
