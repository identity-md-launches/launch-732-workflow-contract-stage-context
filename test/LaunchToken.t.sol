// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    LaunchToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "GENESIS PROTOCOL");
        assertEq(token.symbol(), "GENESIS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionMintedToDeployer() public view {
        assertEq(SUPPLY, 1e27);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_constructorEmitsGenesisTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        LaunchToken fresh = new LaunchToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_constructorIsNotPayable() public {
        bytes memory code = type(LaunchToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(code, 0x20), mload(code))
        }
        assertEq(deployed, address(0), "constructor accepted ETH");
    }

    function test_rejectsEtherAndUnknownCalls() public {
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "accepted ETH");
        (ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok, "mint exists");
        (ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok, "burn exists");
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner exists");
        (ok,) = address(token).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "pause exists");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- transfer

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), alice, 123e18);
        assertTrue(token.transfer(alice, 123e18));
        assertEq(token.balanceOf(alice), 123e18);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeSupplyAndZero() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferToSelfKeepsBalance() public {
        assertTrue(token.transfer(address(this), 5e18));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        token.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        token.transfer(bob, 11);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transfer(alice, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAndOverwritesAllowance() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), alice, 100);
        assertTrue(token.approve(alice, 100));
        assertEq(token.allowance(address(this), alice), 100);
        assertTrue(token.approve(alice, 7));
        assertEq(token.allowance(address(this), alice), 7);
        assertTrue(token.approve(alice, 0));
        assertEq(token.allowance(address(this), alice), 0);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        token.approve(alice, 100);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), bob, 60);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 60));
        assertEq(token.balanceOf(bob), 60);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 60);
        assertEq(token.allowance(address(this), alice), 40);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        token.approve(alice, 59);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, 59, 60));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 60);
        assertEq(token.allowance(address(this), alice), 59);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), alice, 1);
    }

    function test_transferFromNeedsAllowanceEvenForOwnTokens() public {
        // msg.sender == from still goes through the allowance; `transfer` is the path for own tokens.
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_transferFromRevertsOnInsufficientBalance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 10, 11));
        vm.prank(bob);
        token.transferFrom(alice, carol, 11);
        // The revert also rolls back the allowance spend.
        assertEq(token.allowance(alice, bob), 100);
    }

    function test_transferFromRevertsToZeroAddress() public {
        token.approve(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(address(this), address(0), 1);
    }

    function test_unlimitedAllowanceIsNotDecreased() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1e18);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_allowanceIsPerOwnerAndSpender() public {
        token.transfer(alice, 100);
        token.approve(bob, 50);
        // bob's allowance is from this contract, not from alice.
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        // carol has no allowance from this contract.
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, carol, 0, 1));
        vm.prank(carol);
        token.transferFrom(address(this), carol, 1);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
    }

    function testFuzz_transferFrom(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, type(uint256).max - 1);
        amount = bound(amount, 0, SUPPLY);
        token.approve(alice, approved);
        vm.prank(alice);
        if (amount > approved) {
            vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, approved, amount));
            token.transferFrom(address(this), bob, amount);
            assertEq(token.balanceOf(bob), 0);
        } else {
            assertTrue(token.transferFrom(address(this), bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(address(this), alice), approved - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- bytecode

    /// @dev Mirrors the launch floor: no DELEGATECALL, CALLCODE or SELFDESTRUCT, and additionally
    /// no CALL/STATICCALL/CREATE/CREATE2, since the token never talks to another contract.
    function test_runtimeHasNoExternalCallOrEscapeOpcodes() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
            assertTrue(op != 0xf1 && op != 0xfa && op != 0xf0 && op != 0xf5, "external call or create opcode");
        }
    }
}
