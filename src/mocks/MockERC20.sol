// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @author Assignment submission
/// @notice A plain, well-behaved ERC-20 used as the underlying asset in tests.
/// @dev Test-only helper. It is deliberately permissionless: any address may mint,
///      because tests need to fund actors and simulate yield without an owner dance.
contract MockERC20 is ERC20 {
    /// @dev Cached decimals value. ERC20 hardcodes 18; real assets such as USDC use 6,
    ///      and vault math must survive both, so we make it constructor-configurable.
    uint8 private immutable _DECIMALS;

    /// @param name_ ERC-20 token name.
    /// @param symbol_ ERC-20 token symbol.
    /// @param decimals_ Number of decimals this mock should report.
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    /// @inheritdoc ERC20
    /// @dev Overridden so tests can exercise 6-decimal assets, not just 18-decimal ones.
    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Mints `amount` tokens to `to`.
    /// @dev Unrestricted on purpose. Never deploy this outside a test environment:
    ///      without an access check, anyone could inflate supply to zero value.
    /// @param to Recipient of the freshly minted tokens.
    /// @param amount Number of token units to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns `amount` tokens from `from`.
    /// @dev Used to simulate a loss of assets inside a vault (NAV going down).
    /// @param from Address whose balance is reduced.
    /// @param amount Number of token units to burn.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
