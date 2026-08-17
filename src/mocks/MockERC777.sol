// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IERC777Recipient
/// @notice Minimal version of the ERC-777 "I was sent tokens" callback interface.
/// @dev The real ERC-777 standard routes this through the ERC-1820 registry. We keep
///      only the part that matters for the exploit: the receiver gets control flow
///      handed to it *in the middle of* the sender's transfer.
interface IERC777Recipient {
    /// @notice Called by the token on the recipient after its balance has been credited.
    /// @param operator Address that triggered the transfer.
    /// @param from Address the tokens came from.
    /// @param to Address the tokens went to (the callee itself).
    /// @param amount Number of token units transferred.
    function tokensReceived(address operator, address from, address to, uint256 amount) external;
}

/// @title MockERC777
/// @author Assignment submission
/// @notice An ERC-20 token that also fires an ERC-777 style `tokensReceived` hook.
/// @dev This is the weapon used to prove Bug C (reentrancy) in Task 2. A vault that
///      transfers assets out *before* updating its own accounting hands the attacker
///      a moment where the books say they still own shares they have already been paid for.
///
///      Registration is explicit (`setHookEnabled`) rather than ERC-1820-based so the
///      tests stay self-contained and readable.
contract MockERC777 is ERC20 {
    /// @notice Addresses that should receive the `tokensReceived` callback.
    /// @dev Without this flag every EOA transfer would attempt a call to a non-contract
    ///      and waste gas; more importantly it lets a test toggle the hook off to get a
    ///      clean "normal ERC-20" baseline.
    mapping(address account => bool enabled) public hookEnabled;

    /// @dev Re-entrancy latch used *by the token itself*. The attacker only wants to
    ///      re-enter once; without this, the nested transfer would fire the hook again
    ///      and recurse until the call stack or gas runs out, which would mask the bug
    ///      behind an out-of-gas revert instead of showing a clean double-withdraw.
    bool private _inHook;

    /// @param name_ ERC-20 token name.
    /// @param symbol_ ERC-20 token symbol.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Turns the receive hook on or off for `account`.
    /// @param account Address whose hook registration is being changed.
    /// @param enabled True to fire `tokensReceived` on inbound transfers to `account`.
    function setHookEnabled(address account, bool enabled) external {
        hookEnabled[account] = enabled;
    }

    /// @notice Mints `amount` tokens to `to`. Test-only, unrestricted.
    /// @param to Recipient of the minted tokens.
    /// @param amount Number of token units to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev The single behavioural difference from a normal ERC-20.
    ///      `super._update` performs the actual balance movement, so by the time the hook
    ///      runs the recipient genuinely holds the tokens — exactly like real ERC-777.
    ///      Any state the *caller* (the vault) had not yet written is still stale, which
    ///      is precisely the window a reentrancy attack exploits.
    /// @param from Sender address (zero on mint).
    /// @param to Recipient address (zero on burn).
    /// @param value Number of token units moved.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        // Only call out on real transfers to a registered recipient, and never recurse.
        if (to != address(0) && hookEnabled[to] && !_inHook) {
            _inHook = true;
            IERC777Recipient(to).tokensReceived(msg.sender, from, to, value);
            _inHook = false;
        }
    }
}
