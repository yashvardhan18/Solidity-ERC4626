# Task 2 — Auditing the Broken Vault, Explained Simply

## The setup

Same jar-and-tickets picture as the Task 1 document: you put money in the jar, you get a
ticket saying how big your slice is. This task hands you a jar that was built by someone
careless, with five separate ways to steal from it. The job is to find each one, prove it
works with a real exploit, then fix it and prove the fix holds.

Every bug below follows the same shape: **what the code says → the exact steps an attacker
takes → why it works → the one-line reason the fix stops it.**

---

## Bug A — Withdraw rounds in the wrong direction (the "free penny" bug)

### The buggy code

```solidity
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
    shares = convertToShares(assets);   // rounds DOWN
    _burn(owner, shares);
    IERC20(asset).transfer(receiver, assets);
}
```

### The story

Say the jar holds 2,000 tokens and 1,000 tickets exist — so each ticket is worth exactly 2
tokens. An attacker who has **never deposited a single token and owns zero tickets** calls:

```
withdraw(1, attacker, attacker)     // "give me 1 wei of the underlying token"
```

The contract computes `shares = convertToShares(1)`. In whole-number division,
`1 × 1,000 tickets / 2,000 tokens` rounds down to **0**. So it tries to burn 0 tickets from the
attacker — which trivially "succeeds" even though they own none — and then transfers 1 wei of
the token out to them anyway. **They paid nothing and received something.**

That's not a one-off wei of loss either — the attacker just calls it again. And again. A
thousand calls, a thousand free wei, no tickets ever burned. It's slow per call, but it costs
the attacker nothing and it never stops on its own.

### Why it happens

The bug is a **rounding direction mistake**. Whenever you convert "I want to take out this
much money" into "here's how many tickets that costs", any fractional leftover has to be
resolved one way or the other. Rounding it *down* means the very last, smallest slice of value
is sometimes free. That's the whole bug in one sentence: **rounding down on a payout treats
"less than one ticket's worth" as "zero tickets", but still pays out the money.**

### The fix

```solidity
function previewWithdraw(uint256 assets) public view returns (uint256) {
    return _convertToShares(assets, Math.Rounding.Ceil);   // now rounds UP
}
```

Rounding **up** instead means any non-zero payout, no matter how small, always costs *at
least* one ticket. There is no longer a "for free" band. Combined with a `maxWithdraw` check
that rejects the call outright for someone with zero tickets, the exploit path is closed twice
over.

### How the test proves it

The test deposits normally, doubles the jar's value with fake yield (so 1 ticket = 2 tokens,
matching the story above), then has an attacker with zero tickets call `withdraw(1, ...)` a
thousand times against the broken vault — and shows the attacker's balance really did grow by
exactly 1,000 wei while the vault's `totalSupply()` never moved. Then it points the *identical*
call at the fixed vault and shows it reverts immediately with `ExceededMaxWithdraw`.

---

## Bug B — No allowance check (anyone can spend anyone's tickets)

### The buggy code

```solidity
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
    assets = convertToAssets(shares);
    IERC20(asset).transfer(receiver, assets);
    _burn(owner, shares);
}
```

### The story

`owner` is just a plain argument — nothing in the function checks that `msg.sender` (whoever
is actually calling) has any right to touch `owner`'s tickets. Alice has deposited 1,000
tokens and holds 1,000 tickets. An attacker, who has never interacted with Alice at all, calls:

```
redeem(1000, attackerAddress, aliceAddress)
```

The contract reads Alice's ticket balance, pays out her 1,000 tokens **to the attacker**, and
burns Alice's tickets. There's no approval step anywhere in this path — the attacker simply
named Alice as the victim and walked away with her money. Repeat for every depositor in the
jar and the whole thing is empty within one transaction.

### Why it happens

Real-world analogy: imagine a bank teller who will hand out money from *any* account you name,
no ID required, no signature, nothing. The bug is simply a missing permission check.

### The fix

```solidity
if (caller != owner) {
    _spendAllowance(owner, caller, shares);
}
```

If you're withdrawing your own tickets, nothing changes. If you're withdrawing *someone else's*
tickets, they now have to have explicitly pre-approved you for that exact amount (the same
`approve()` mechanism as a normal ERC-20 token) — and that approval is consumed, not reusable.
This is exactly how a real bank works: your own money, no questions asked; someone else's
money, only with their signed permission.

### How the test proves it

Alice deposits, the attacker calls `redeem` naming Alice as owner with zero allowance set —
against the broken vault this succeeds and the attacker walks off with Alice's tokens; against
the fixed vault the identical call reverts with an "insufficient allowance" error.

---

## Bug C — Reentrancy: paying out before updating the books

This is the trickiest bug in the whole assignment, so it gets the longest explanation.

### What "reentrancy" even means, in plain terms

Normal ERC-20 tokens are simple: you tell them to move money, and that's the entire
interaction — nothing "calls you back". But some tokens (this assignment uses an ERC-777-style
token to demonstrate it) notify the *recipient* the instant they receive money, by calling a
function on the recipient's contract mid-transfer. If the recipient is itself a smart contract,
that notification can contain **more instructions** — including a call straight back into the
vault, before the vault has finished what it was originally doing.

Think of it like a cashier at a store: normally you pay, they update the register, then hand
you your receipt — done, in that order. Reentrancy is what happens if the cashier hands you
your change *first*, and while counting it out loud, you interrupt them mid-count to make a
*second* purchase using money they haven't logged in the register yet. If the register isn't
updated until after your interruption, your second purchase gets priced using stale numbers.

### The buggy code

```solidity
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
    assets = convertToAssets(shares);
    IERC20(asset).transfer(receiver, assets);   // <-- pays out FIRST
    _burn(owner, shares);                        // <-- only THEN updates the books
}
```

### The story, with real numbers

The vault holds 1,000 tokens against 1,000 tickets (price = 1.0). An attacker's own contract
holds 100 of those tickets; honest depositors hold the other 900.

1. The attacker calls `redeem(100, attackerContract, attackerContract)`.
2. The vault computes `assets = 100` and **sends the 100 tokens first**. The jar now physically
   holds only 900 tokens — but it hasn't burned anything yet. As far as the ticket bookkeeping
   is concerned, there are still 1,000 tickets outstanding, and the attacker still shows a
   balance of 100 tickets. **The books say something that is no longer true**: 1,000 tickets
   backed by only 900 tokens.
3. Because the token is the notify-on-receive kind, the instant those 100 tokens land in the
   attacker's contract, the token calls a function on that contract to tell it "you just
   received money". The attacker's contract has code sitting there waiting for exactly this
   moment.
4. From inside that notification, *before the original `redeem` call has even returned*, the
   attacker's contract calls `deposit(100)` on the vault — paying with the very 100 tokens it
   was just handed. The vault prices this deposit using its current (temporarily wrong) state:
   `100 × 1,000 tickets / 900 tokens ≈ 111.1` new tickets — more than the honest 100 a correct
   quote would have given, because the vault's own books are pretending it's poorer than it
   really is at that instant.
5. The notification finishes, and control returns to the *original* `redeem` call, which
   finally runs `_burn(owner, 100)` — removing only the original 100 tickets.
6. Net result: the attacker started with 100 tickets, and ends the whole sequence holding
   `111.1 − 0 = 111.1` tickets (the 100 that survived the burn were already spent on the
   deposit; what's left is the freshly minted 111.1), against a jar that is back to holding
   1,000 tokens exactly as before. They redeem those for **~109.9 tokens**.

Put simply: **100 tokens in, ~109.9 tokens out**, and no outside capital was needed — step 4
was funded entirely by the vault's own mid-flight payout. The extra ~9.9 tokens came directly
out of the honest depositors' 900-token claim.

### Why it happens

The root cause is **ordering**: the transfer (an *interaction* with the outside world) happened
*before* the burn (an *update to the vault's own books*). The moment you hand control to an
outside contract — which any token transfer to a contract address effectively does — that
outside code can call back in, and it will see whatever state you've left behind at that exact
point. If your own bookkeeping isn't finished yet, it sees a lie.

### The fix — two independent layers

**Layer 1 — reorder: update the books first, pay second.**

```solidity
_burn(owner, shares);                       // update the books FIRST
IERC20(asset).safeTransfer(receiver, assets); // pay out SECOND
```

This is a general rule called **checks-effects-interactions**: check that the action is
allowed, make all your own state changes, and *only then* talk to the outside world. With this
order, by the time the notification fires, the burn has already happened — the vault's
bookkeeping is accurate the instant any outside code gets a chance to run, so there's no
window of stale numbers to exploit.

**Layer 2 — a reentrancy lock (`nonReentrant`).**

Even with correct ordering, it's good practice to also flip a simple "I'm currently busy" flag
at the start of any money-moving function and refuse any nested call into another guarded
function while that flag is set. This is defense in depth: if a future code change ever
reintroduces a bad ordering by accident, the lock still catches it and the transaction reverts
outright instead of quietly mispricing something.

### How the test proves it

`src/mocks/ReentrancyAttacker.sol` is a small contract that plays the attacker role exactly as
described above: it opens a normal position, then calls `redeem`, and its "I just received
money" callback deposits that money right back in. The test records the vault's state *during*
that callback (100 tokens already paid out, but still 100 tickets showing as owned — the smoking
gun) and confirms the attacker's final balance really is about 109.9, a genuine profit, taken
directly from the honest depositor's share. Pointed at the fixed vault, the identical attack
contract simply reverts.

---

## Bug D — The fee math is broken in three separate ways

### The buggy code

```solidity
function harvest() external {
    uint256 nav = totalAssets() / totalSupply();
    if (nav > highWaterMark) {
        uint256 fee = (nav - highWaterMark) * 20 / 100;
        _mint(feeRecipient, fee);
        highWaterMark = nav;
    }
}
```

This single line, `totalAssets() / totalSupply()`, carries three separate bugs at once.

### D1 — Dividing by zero crashes the function

If nobody has deposited yet, `totalSupply()` is 0. Dividing by zero in Solidity doesn't return
some special "undefined" value — it makes the whole transaction fail. So `harvest()` on a
brand-new, empty jar simply crashes every time. If any automated system calls `harvest()` as
part of a routine batch of actions, that entire batch breaks the moment the jar is empty.

### D2 — Whole-number division throws away almost all the information

`nav` here is meant to represent the price-per-ticket, like `1.10` in the Task 1 document's
example. But `totalAssets() / totalSupply()` is *whole-number* division — it can never produce
a fraction, only a whole number like `1` or `2`. A jar that grows from a price of 1.0 to 1.99
(a 99% gain!) still reports `nav = 1`, exactly the same as a jar that hasn't moved at all. The
fee formula then computes `(1 - 1) * 20 / 100 = 0` — **the manager is charged nothing for a
99% gain.** The fee only becomes non-zero once the price crosses a *whole* extra unit, which for
most real vaults essentially never happens.

### D3 — The result is used as the wrong *kind* of number entirely

Even setting aside D1 and D2, there's a deeper mistake: `nav` is a *price*. But the line
`_mint(feeRecipient, fee)` mints `fee` as a **count of tickets**, not a price. Those are
different units and mixing them up is like being told "the price of milk went up by $2" and
then handing someone 2 gallons of milk as a reward.

Here's how bad this gets in practice: deposit just 1 wei into an empty jar (so `totalSupply()`
= 1), then donate 1,000 tokens straight into the jar. Now `nav = 1,000e18 / 1 = 1,000e18` — an
astronomically large number, because it's `totalAssets` divided by a supply of *one*. The fee
line then mints `1,000e18 × 20 / 100 = 200e18` **tickets** to the fee recipient — vastly more
tickets than exist anywhere else in the system. The fee recipient now effectively owns the
entire jar, having contributed nothing, and `harvest()` is a function anyone can call, so
anyone can trigger this against the manager's benefit at any time.

### The fix

```solidity
uint256 supply = totalSupply();
if (supply == 0) return 0;                     // fixes D1

uint256 currentPrice = pricePerShare();         // a properly scaled, precise price — fixes D2
uint256 hwm = highWaterMark;
if (currentPrice <= hwm) return 0;

uint256 totalGain = (currentPrice - hwm).mulDiv(supply, oneShareScaled, Math.Rounding.Floor);
uint256 feeAssets = totalGain.mulDiv(20, 100, Math.Rounding.Floor);   // an ASSET amount, not a price

// only now convert that asset amount into the correctly-sized number of tickets — fixes D3
uint256 assetsAfterFee = totalAssets() + 1 - feeAssets;
feeShares = feeAssets.mulDiv(supply + 1000, assetsAfterFee, Math.Rounding.Floor);
```

Each defect gets its own one-line fix: an early return handles the empty-jar case; a properly
scaled `pricePerShare()` (carrying extra decimal precision instead of being a bare whole
number) means small gains are no longer invisible; and the fee is computed as an *asset amount*
first, then converted into the correctly-sized ticket count as its very last step, instead of
being minted directly as if a price and a ticket count were interchangeable. This is exactly
the same fee formula walked through in the Task 1 document.

### How the test proves it

Three separate tests, one per defect: `harvest()` on an empty broken vault reverts with a
division panic (fixed vault: silently does nothing); a 90%-then-200% gain on the broken vault
mints a fee of exactly zero both times (fixed vault: charges the correct 20%); and the 1-wei /
huge-donation setup mints the fee recipient effectively the entire supply on the broken vault,
while the fixed vault caps the fee at 20% of the real gain.

---

## Bug E — Ignoring whether a token transfer actually worked

### The buggy code

```solidity
IERC20(asset).transfer(receiver, assets);   // return value thrown away
```

### Why this is dangerous at all

The ERC-20 standard says `transfer` should return `true` on success. But it's only a
*suggestion* that got adopted inconsistently across real tokens in the wild:

- **Some tokens return `false` on failure instead of reverting.** If nobody checks that
  boolean, the calling code has no idea the transfer didn't happen and just carries on as if it
  did.
- **Some tokens (most famously USDT) don't return anything at all.** If the calling code is
  written expecting a `bool` back, decoding that missing data can make the whole call revert —
  even though the transfer itself actually succeeded.

### The story, direction 1 — silent failure lets someone mint free shares

An attacker with **zero balance** of a `false`-returning token calls `deposit(1_000_000)`. The
underlying `transferFrom` call returns `false` because the attacker has no funds — but nothing
in the vault checks that return value, so execution just continues as if the transfer had
worked, and the vault happily mints the attacker 1,000,000 tickets for money that never
arrived. They can now redeem those tickets against everyone else's real deposits.

### The story, direction 2 — a working token bricks the vault entirely

A token like USDT returns no data from `transfer` at all. The vault's code is written as
`IERC20(asset).transfer(...)`, which expects a boolean back. Solidity tries to read that
boolean from the response and finds nothing there, and the whole call reverts — **even though
the actual transfer of tokens succeeded fine on the token's side.** Every single deposit and
withdrawal using that kind of token would fail forever, permanently locking anyone's money that
made it in before this was discovered.

### The fix

```solidity
IERC20(asset).safeTransfer(receiver, assets);
IERC20(asset).safeTransferFrom(caller, address(this), assets);
```

`safeTransfer`/`safeTransferFrom` come from OpenZeppelin's `SafeERC20` library. They handle
both broken behaviors in one move: if the call returns `false`, they revert (closing direction
1); if the call returns nothing at all but otherwise succeeded, they treat that as success
instead of trying to decode a boolean that was never there (closing direction 2 and making the
vault compatible with tokens like USDT).

### How the test proves it

A custom mock token that returns `false` on a failed transfer is used to show an
attacker-with-no-balance minting free shares on the broken vault, and reverting cleanly on the
fixed one. A second mock token that returns no data at all is shown bricking every deposit and
withdrawal on the broken vault, while working correctly end-to-end on the fixed one.

---

## The pattern behind all five

Notice that every single bug is a variation on the same handful of themes:

- **Don't trust rounding to fall in your favor** (Bug A) — always round against the caller.
- **Don't trust an argument to describe permission** (Bug B) — an `owner` parameter is just a
  number until you check it against something real.
- **Don't trust your own bookkeeping to still be true after you've handed control away**
  (Bug C) — finish your updates before you call out to anyone else.
- **Don't trust a formula's units** (Bug D) — a price and a count are not interchangeable just
  because they're both numbers.
- **Don't trust that a function call succeeded just because it didn't crash** (Bug E) — check
  what it actually reported.

That's the mental checklist worth carrying into any new contract: rounding direction,
permission checks, ordering of state changes versus external calls, unit consistency, and
return-value checking.
