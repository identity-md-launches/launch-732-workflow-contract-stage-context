// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Drives random transfers, approvals and transferFroms between a fixed set of actors. Every
/// token starts with the handler, so the actors' balances must always sum to the whole supply.
contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address[] public actors;

    constructor() {
        token = new LaunchToken();
        actors.push(address(this));
        for (uint160 i = 1; i <= 4; ++i) {
            actors.push(address(0xA11CE000 + i));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        if (allowed != type(uint256).max) {
            assertEq(token.allowance(from, spender), allowed - amount, "allowance not spent exactly");
        }
    }

    /// @dev Arbitrary calldata from an arbitrary caller: nothing reachable may create tokens.
    function arbitraryCall(address caller, bytes calldata data) external {
        vm.assume(caller != address(0));
        for (uint256 i; i < actors.length; ++i) {
            if (caller == actors[i]) return;
        }
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;
        assertEq(token.balanceOf(caller), 0, "outsider obtained tokens");
    }
}

contract LaunchTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1e27;

    LaunchTokenHandler internal handler;
    LaunchToken internal token;

    function setUp() public {
        handler = new LaunchTokenHandler();
        token = handler.token();
        targetContract(address(handler));
    }

    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
    }
}
