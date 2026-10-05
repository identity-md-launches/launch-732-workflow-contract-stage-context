// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev The nine ERC-20 entry points, declared here so the tests encode calls from the standard's
/// signatures rather than from whatever the implementation happens to expose.
interface IErc20Surface {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Stands in for the launch factory: deploys the token with CREATE2, so the factory is the
/// constructor's msg.sender, and then pays the supply out with plain transfers.
contract FactoryStandIn {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "token constructor reverted");
    }

    function pay(LaunchToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "transfer returned false");
    }
}

/// @notice Adversarial edge cases for LaunchToken that the baseline suite does not reach: raw ABI
/// behaviour, the exact storage each call touches, the exact entry points the runtime answers, aliasing
/// between sender, spender and receiver, error precedence, and that a refused call leaves no trace.
/// @dev One behaviour is deliberately NOT asserted here: `transferFrom(address(0), to, 0)` succeeds for
/// any caller and emits `Transfer(address(0), to, 0)`. That is reported as a finding instead.
/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant MAX = type(uint256).max;

    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    LaunchToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new LaunchToken();
    }

    // ---------------------------------------------------------------- helpers

    function _insufficientBalance(address from, uint256 balance, uint256 needed) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, from, balance, needed);
    }

    function _insufficientAllowance(address spender, uint256 allowed, uint256 needed)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, spender, allowed, needed);
    }

    function _invalidReceiver() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(LaunchToken.InvalidReceiver.selector, address(0));
    }

    /// @dev Calls the token as `caller` and requires a revert carrying exactly `expectedError`.
    function _refused(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(token).call(data);
        assertFalse(ok, "call succeeded but must be refused");
        assertEq(returned, expectedError, "wrong revert data");
    }

    function _balanceSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, uint256(0)));
    }

    function _allowanceSlot(address owner, address spender) internal pure returns (bytes32) {
        return keccak256(abi.encode(spender, keccak256(abi.encode(owner, uint256(1)))));
    }

    function _contains(bytes32[] memory slots, bytes32 slot) internal pure returns (bool) {
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i] == slot) return true;
        }
        return false;
    }

    function _isErc20Selector(bytes4 selector) internal pure returns (bool) {
        return selector == IErc20Surface.name.selector || selector == IErc20Surface.symbol.selector
            || selector == IErc20Surface.decimals.selector || selector == IErc20Surface.totalSupply.selector
            || selector == IErc20Surface.balanceOf.selector || selector == IErc20Surface.allowance.selector
            || selector == IErc20Surface.transfer.selector || selector == IErc20Surface.approve.selector
            || selector == IErc20Surface.transferFrom.selector;
    }

    /// @dev One well-formed call per entry point, indexed 0..8.
    function _wellFormedCall(uint256 index) internal view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(IErc20Surface.name, ());
        if (index == 1) return abi.encodeCall(IErc20Surface.symbol, ());
        if (index == 2) return abi.encodeCall(IErc20Surface.decimals, ());
        if (index == 3) return abi.encodeCall(IErc20Surface.totalSupply, ());
        if (index == 4) return abi.encodeCall(IErc20Surface.balanceOf, (alice));
        if (index == 5) return abi.encodeCall(IErc20Surface.allowance, (alice, bob));
        if (index == 6) return abi.encodeCall(IErc20Surface.transfer, (alice, 0));
        if (index == 7) return abi.encodeCall(IErc20Surface.approve, (alice, 0));
        return abi.encodeCall(IErc20Surface.transferFrom, (alice, bob, 0));
    }

    // ---------------------------------------------------------------- launch shape

    function test_factoryDeployedTokenMintsToTheFactoryNotTheOrigin() public {
        FactoryStandIn factory = new FactoryStandIn();
        bytes memory initCode = type(LaunchToken).creationCode;
        bytes32 salt = bytes32(uint256(1));

        vm.prank(alice, alice);
        LaunchToken launched = LaunchToken(factory.deploy(initCode, salt));

        assertEq(address(launched), vm.computeCreate2Address(salt, keccak256(initCode), address(factory)));
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "factory does not hold the whole supply");
        assertEq(launched.balanceOf(alice), 0, "tx.origin was credited");
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(address(launched)), 0);
    }

    function test_separateDeploymentsShareNoState() public {
        vm.prank(alice);
        LaunchToken other = new LaunchToken();

        token.transfer(bob, 7e18);
        token.approve(bob, 3e18);

        assertEq(other.balanceOf(bob), 0);
        assertEq(other.balanceOf(address(this)), 0);
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.allowance(address(this), bob), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev The launch split, driven through the real token: 2% equally among workers, 8% equally among
    /// seats, the chosen share to the pool and the rest of the 90% to the requester. Whatever the
    /// counts, every unit of the supply ends in a known place and only division dust stays behind.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_factorySplitAccountsForEveryUnit(uint256 workers, uint256 seats, uint256 poolBps) public {
        workers = bound(workers, 1, 24);
        seats = bound(seats, 1, 24);
        poolBps = bound(poolBps, 0, 9000);

        FactoryStandIn factory = new FactoryStandIn();
        LaunchToken launched = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(0)));

        uint256 workerShare = (SUPPLY * 2 / 100) / workers;
        uint256 seatShare = (SUPPLY * 8 / 100) / seats;
        uint256 poolAmount = SUPPLY * poolBps / 10_000;
        uint256 requesterAmount = SUPPLY * 90 / 100 - poolAmount;
        address pool = makeAddr("pool");
        address requester = makeAddr("requester");

        uint256 paid;
        for (uint256 i; i < workers; ++i) {
            address worker = address(uint160(0x1000 + i));
            factory.pay(launched, worker, workerShare);
            assertEq(launched.balanceOf(worker), workerShare);
            paid += workerShare;
        }
        for (uint256 i; i < seats; ++i) {
            address seat = address(uint160(0x2000 + i));
            factory.pay(launched, seat, seatShare);
            assertEq(launched.balanceOf(seat), seatShare);
            paid += seatShare;
        }
        factory.pay(launched, pool, poolAmount);
        factory.pay(launched, requester, requesterAmount);
        paid += poolAmount + requesterAmount;

        assertEq(launched.balanceOf(pool), poolAmount);
        assertEq(launched.balanceOf(requester), requesterAmount);
        assertEq(launched.balanceOf(address(factory)), SUPPLY - paid, "factory remainder is not the unpaid rest");
        assertLt(SUPPLY - paid, workers + seats, "more than division dust was left behind");
        assertEq(launched.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- raw ABI behaviour

    function test_mutatorsReturnExactlyOneTrueWord() public {
        (bool ok, bytes memory returned) = address(token).call(abi.encodeCall(IErc20Surface.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(returned, abi.encode(true));

        (ok, returned) = address(token).call(abi.encodeCall(IErc20Surface.approve, (alice, 1)));
        assertTrue(ok);
        assertEq(returned, abi.encode(true));

        vm.prank(alice);
        (ok, returned) = address(token).call(abi.encodeCall(IErc20Surface.transferFrom, (address(this), bob, 1)));
        assertTrue(ok);
        assertEq(returned, abi.encode(true));
    }

    function test_viewsReturnCanonicalEncodings() public view {
        (bool ok, bytes memory returned) = address(token).staticcall(abi.encodeCall(IErc20Surface.name, ()));
        assertTrue(ok);
        assertEq(returned, abi.encode("GENESIS PROTOCOL"));

        (ok, returned) = address(token).staticcall(abi.encodeCall(IErc20Surface.symbol, ()));
        assertTrue(ok);
        assertEq(returned, abi.encode("GENESIS"));

        (ok, returned) = address(token).staticcall(abi.encodeCall(IErc20Surface.decimals, ()));
        assertTrue(ok);
        assertEq(returned, abi.encode(uint256(18)));

        (ok, returned) = address(token).staticcall(abi.encodeCall(IErc20Surface.totalSupply, ()));
        assertTrue(ok);
        assertEq(returned, abi.encode(uint256(1_000_000_000) * 10 ** 18));

        (ok, returned) = address(token).staticcall(abi.encodeCall(IErc20Surface.balanceOf, (alice)));
        assertTrue(ok);
        assertEq(returned, abi.encode(uint256(0)));

        (ok, returned) = address(token).staticcall(abi.encodeCall(IErc20Surface.allowance, (alice, bob)));
        assertTrue(ok);
        assertEq(returned, abi.encode(uint256(0)));
    }

    function test_everyEntryPointRefusesEther() public {
        vm.deal(address(this), 1 ether);
        for (uint256 i; i < 9; ++i) {
            (bool ok,) = address(token).call{value: 1}(_wellFormedCall(i));
            assertFalse(ok, "an entry point accepted ETH");
        }
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, 1 ether);
    }

    function test_truncatedCalldataIsRefused() public {
        bytes[7] memory calls = [
            abi.encodePacked(IErc20Surface.transfer.selector),
            abi.encodePacked(IErc20Surface.transfer.selector, abi.encode(alice)),
            abi.encodePacked(IErc20Surface.transfer.selector, abi.encode(alice), bytes31(uint248(1))),
            abi.encodePacked(IErc20Surface.approve.selector, abi.encode(alice)),
            abi.encodePacked(IErc20Surface.transferFrom.selector, abi.encode(address(this), alice)),
            abi.encodePacked(IErc20Surface.balanceOf.selector),
            abi.encodePacked(IErc20Surface.allowance.selector, abi.encode(alice))
        ];
        token.approve(alice, MAX);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(i == 4 ? alice : address(this));
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "truncated calldata accepted");
        }
        // Fewer than four bytes never reaches a function either.
        (bool shortOk,) = address(token).call(hex"a9059c");
        assertFalse(shortOk);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev An address word with bits above 160 set must not be silently truncated to a valid address.
    function test_dirtyAddressWordsAreRefused() public {
        uint256 dirtyAlice = uint256(uint160(alice)) | (1 << 160);
        uint256 dirtyThis = uint256(uint160(address(this))) | (1 << 255);
        token.approve(alice, MAX);

        bytes[5] memory calls = [
            abi.encodeWithSelector(IErc20Surface.transfer.selector, dirtyAlice, uint256(1)),
            abi.encodeWithSelector(IErc20Surface.approve.selector, dirtyAlice, uint256(1)),
            abi.encodeWithSelector(IErc20Surface.transferFrom.selector, dirtyThis, alice, uint256(1)),
            abi.encodeWithSelector(IErc20Surface.transferFrom.selector, address(this), dirtyAlice, uint256(1)),
            abi.encodeWithSelector(IErc20Surface.balanceOf.selector, dirtyThis)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(i == 2 || i == 3 ? alice : address(this));
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "dirty address word accepted");
        }
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), alice), MAX);
    }

    function test_trailingCalldataDoesNotShiftArguments() public {
        bytes memory data = abi.encodePacked(abi.encodeCall(IErc20Surface.transfer, (alice, 5)), uint256(999), bob);
        (bool ok, bytes memory returned) = address(token).call(data);
        assertTrue(ok);
        assertEq(returned, abi.encode(true));
        assertEq(token.balanceOf(alice), 5);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 5);
    }

    // ---------------------------------------------------------------- entry points

    /// @dev Reads the function dispatcher out of the deployed runtime: every `PUSH4 <selector> EQ` is
    /// an entry point. There must be exactly the nine ERC-20 ones, so a function behind an unusual
    /// selector cannot hide from the curated lists used elsewhere.
    function test_dispatcherAnswersExactlyTheNineErc20Selectors() public view {
        bytes memory code = address(token).code;
        uint256 found;
        uint256 seenMask;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op < 0x60 || op > 0x7f) continue;
            uint256 width = op - 0x5f;
            if (op == 0x63 && i + 5 < code.length && uint8(code[i + 5]) == 0x14) {
                bytes4 selector = bytes4(
                    (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                        | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]))
                );
                assertTrue(_isErc20Selector(selector), "runtime dispatches a selector that is not ERC-20");
                ++found;
                for (uint256 k; k < 9; ++k) {
                    if (bytes4(_wellFormedCall(k)) == selector) seenMask |= 1 << k;
                }
            }
            i += width;
        }
        assertEq(found, 9, "dispatcher entry count");
        assertEq(seenMask, (1 << 9) - 1, "an ERC-20 entry point is missing from the dispatcher");
    }

    function test_adminAndExtensionEntryPointsDoNotExist() public {
        string[26] memory signatures = [
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "mint(address,uint256)",
            "mintTo(address,uint256)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "nonces(address)",
            "DOMAIN_SEPARATOR()",
            "owner()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "paused()",
            "blacklist(address)",
            "setFee(uint256)",
            "setTax(uint256)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize()",
            "rescueTokens(address,uint256)",
            "withdraw()",
            "multicall(bytes[])",
            "transferAndCall(address,uint256,bytes)",
            "supportsInterface(bytes4)"
        ];
        address[2] memory callers = [address(this), alice];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodePacked(
                bytes4(keccak256(bytes(signatures[i]))), abi.encode(alice, uint256(1), uint256(2), uint256(3))
            );
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), alice), 0);
    }

    function testFuzz_unknownSelectorIsRefused(bytes4 selector, bytes calldata args, address caller) public {
        while (_isErc20Selector(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        token.transfer(alice, 1e18);
        uint256 callerBalance = token.balanceOf(caller);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));

        assertFalse(ok, "unknown selector accepted");
        assertEq(token.balanceOf(caller), callerBalance);
        assertEq(token.balanceOf(alice), caller == alice ? callerBalance : 1e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- storage discipline

    function test_constructorWritesOnlyTheDeployerBalance() public {
        vm.record();
        vm.prank(alice);
        LaunchToken fresh = new LaunchToken();
        (, bytes32[] memory writes) = vm.accesses(address(fresh));

        assertEq(writes.length, 1, "constructor wrote more than one slot");
        assertEq(writes[0], _balanceSlot(alice));
        assertEq(uint256(vm.load(address(fresh), writes[0])), SUPPLY);
    }

    /// @dev No owner, flag, counter or fee variable: the low slots hold nothing, before or after use.
    function test_thereIsNoScalarState() public {
        token.transfer(alice, 5e18);
        token.approve(bob, MAX);
        vm.prank(bob);
        token.transferFrom(address(this), carol, 1e18);
        for (uint256 slot; slot < 32; ++slot) {
            assertEq(vm.load(address(token), bytes32(slot)), bytes32(0), "non-mapping state present");
        }
    }

    function test_transferWritesOnlyTheTwoBalances() public {
        vm.record();
        token.transfer(alice, 5);
        (, bytes32[] memory writes) = vm.accesses(address(token));

        assertEq(writes.length, 2);
        assertTrue(_contains(writes, _balanceSlot(address(this))));
        assertTrue(_contains(writes, _balanceSlot(alice)));
    }

    function test_approveWritesOnlyTheAllowance() public {
        vm.record();
        token.approve(alice, 5);
        (, bytes32[] memory writes) = vm.accesses(address(token));

        assertEq(writes.length, 1);
        assertEq(writes[0], _allowanceSlot(address(this), alice));
        assertEq(uint256(vm.load(address(token), writes[0])), 5);
    }

    function test_transferFromWritesAllowanceAndTwoBalances() public {
        token.approve(alice, 10);
        vm.record();
        vm.prank(alice);
        token.transferFrom(address(this), bob, 4);
        (, bytes32[] memory writes) = vm.accesses(address(token));

        assertEq(writes.length, 3);
        assertTrue(_contains(writes, _allowanceSlot(address(this), alice)));
        assertTrue(_contains(writes, _balanceSlot(address(this))));
        assertTrue(_contains(writes, _balanceSlot(bob)));
        // The spender is only a signer here: nothing of theirs is written.
        assertFalse(_contains(writes, _balanceSlot(alice)));
    }

    function test_transferFromWithUnlimitedAllowanceDoesNotWriteIt() public {
        token.approve(alice, MAX);
        vm.record();
        vm.prank(alice);
        token.transferFrom(address(this), bob, 4);
        (, bytes32[] memory writes) = vm.accesses(address(token));

        assertEq(writes.length, 2);
        assertFalse(_contains(writes, _allowanceSlot(address(this), alice)));
    }

    // ---------------------------------------------------------------- events

    function test_successfulCallsEmitExactlyOneCorrectEvent() public {
        vm.recordLogs();
        token.transfer(alice, 11);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].data, abi.encode(uint256(11)));

        token.approve(bob, 22);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], APPROVAL_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(logs[0].data, abi.encode(uint256(22)));

        vm.prank(bob);
        token.transferFrom(address(this), carol, 7);
        logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != TRANSFER_TOPIC) continue;
            ++transfers;
            // The event names the owner of the tokens, never the spender who signed.
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(this)))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(carol))));
            assertEq(logs[i].data, abi.encode(uint256(7)));
        }
        assertEq(transfers, 1, "transferFrom must report one transfer, with no second leg");
    }

    function test_refusedCallsEmitNothing() public {
        token.approve(alice, 5);
        vm.recordLogs();

        _refused(address(this), abi.encodeCall(IErc20Surface.transfer, (address(0), 1)), _invalidReceiver());
        _refused(bob, abi.encodeCall(IErc20Surface.transfer, (alice, 1)), _insufficientBalance(bob, 0, 1));
        _refused(
            address(this),
            abi.encodeCall(IErc20Surface.approve, (address(0), 1)),
            abi.encodeWithSelector(LaunchToken.InvalidSpender.selector, address(0))
        );
        _refused(
            alice,
            abi.encodeCall(IErc20Surface.transferFrom, (address(this), bob, 6)),
            _insufficientAllowance(alice, 5, 6)
        );

        assertEq(vm.getRecordedLogs().length, 0, "a refused call emitted an event");
    }

    // ---------------------------------------------------------------- zero and boundary values

    /// @dev ERC-20: transfers of 0 are normal transfers and must fire the event, even from nothing.
    function test_zeroValueTransferFromAnEmptyAccountSucceeds() public {
        vm.recordLogs();
        vm.prank(bob);
        assertTrue(token.transfer(alice, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(logs[0].data, abi.encode(uint256(0)));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_zeroValueTransferToTheZeroAddressIsStillRefused() public {
        _refused(address(this), abi.encodeCall(IErc20Surface.transfer, (address(0), 0)), _invalidReceiver());
        token.approve(alice, 1);
        _refused(alice, abi.encodeCall(IErc20Surface.transferFrom, (address(this), address(0), 0)), _invalidReceiver());
    }

    function test_oneUnitMoreThanTheBalanceIsRefusedAndTheBalanceItselfMoves() public {
        token.transfer(alice, 1);
        _refused(alice, abi.encodeCall(IErc20Surface.transfer, (bob, 2)), _insufficientBalance(alice, 1, 2));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
        // The same call twice: the second finds nothing left.
        _refused(alice, abi.encodeCall(IErc20Surface.transfer, (bob, 1)), _insufficientBalance(alice, 0, 1));
    }

    function test_amountsThatWouldWrapAreRefused() public {
        _refused(
            address(this),
            abi.encodeCall(IErc20Surface.transfer, (alice, MAX)),
            _insufficientBalance(address(this), SUPPLY, MAX)
        );
        _refused(
            address(this),
            abi.encodeCall(IErc20Surface.transfer, (alice, SUPPLY + 1)),
            _insufficientBalance(address(this), SUPPLY, SUPPLY + 1)
        );
        // An unlimited allowance does not unlock more than the balance either.
        token.approve(alice, MAX);
        _refused(
            alice,
            abi.encodeCall(IErc20Surface.transferFrom, (address(this), alice, MAX)),
            _insufficientBalance(address(this), SUPPLY, MAX)
        );
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- allowance edges

    function test_allowanceSpentExactlyThenExhausted() public {
        token.approve(alice, 60);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 60);
        assertEq(token.allowance(address(this), alice), 0);
        _refused(
            alice,
            abi.encodeCall(IErc20Surface.transferFrom, (address(this), bob, 1)),
            _insufficientAllowance(alice, 0, 1)
        );
        assertEq(token.balanceOf(bob), 60);
    }

    /// @dev Only the exact maximum is unlimited. One below it is an ordinary allowance and is spent.
    function test_oneBelowMaxIsAFiniteAllowance() public {
        token.approve(alice, MAX - 1);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 10);
        assertEq(token.allowance(address(this), alice), MAX - 11);
    }

    function test_unlimitedAllowanceSurvivesRepeatedUseAndIsBoundedByBalance() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(bob, MAX);
        for (uint256 i; i < 4; ++i) {
            vm.prank(bob);
            token.transferFrom(alice, carol, 25);
            assertEq(token.allowance(alice, bob), MAX);
        }
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(carol), 100);
        _refused(bob, abi.encodeCall(IErc20Surface.transferFrom, (alice, carol, 1)), _insufficientBalance(alice, 0, 1));
    }

    function test_revokedAllowanceStopsTheSpender() public {
        token.approve(alice, 100);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 40);
        token.approve(alice, 0);
        _refused(
            alice,
            abi.encodeCall(IErc20Surface.transferFrom, (address(this), alice, 1)),
            _insufficientAllowance(alice, 0, 1)
        );
        assertEq(token.balanceOf(alice), 40);
    }

    function test_allowanceIsDirectionalAndNotTransferable() public {
        token.transfer(alice, 100);
        token.approve(alice, 50);
        // Approving alice gives this contract nothing over alice's tokens.
        _refused(
            address(this),
            abi.encodeCall(IErc20Surface.transferFrom, (alice, address(this), 1)),
            _insufficientAllowance(address(this), 0, 1)
        );
        // alice cannot hand her allowance to bob by approving him herself.
        vm.prank(alice);
        token.approve(bob, 50);
        _refused(
            bob, abi.encodeCall(IErc20Surface.transferFrom, (address(this), bob, 1)), _insufficientAllowance(bob, 0, 1)
        );
        assertEq(token.allowance(address(this), alice), 50);
    }

    function test_approvalFromAnEmptyAccountGoesLiveOnceFunded() public {
        vm.prank(alice);
        token.approve(bob, 30);
        _refused(bob, abi.encodeCall(IErc20Surface.transferFrom, (alice, bob, 30)), _insufficientBalance(alice, 0, 30));
        // The refused spend rolled its allowance decrement back.
        assertEq(token.allowance(alice, bob), 30);

        token.transfer(alice, 30);
        vm.prank(bob);
        token.transferFrom(alice, bob, 30);
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_selfApprovalLetsTheOwnerUseTransferFrom() public {
        token.approve(address(this), 9);
        assertTrue(token.transferFrom(address(this), alice, 9));
        assertEq(token.balanceOf(alice), 9);
        assertEq(token.allowance(address(this), address(this)), 0);
    }

    // ---------------------------------------------------------------- aliasing

    function test_transferFromOwnerBackToOwnerSpendsAllowanceButMovesNothing() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(bob, 70);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, 70));
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_selfTransferOfTheWholeBalanceNeitherDoublesNorDestroysIt() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        _refused(
            address(this),
            abi.encodeCall(IErc20Surface.transfer, (address(this), SUPPLY + 1)),
            _insufficientBalance(address(this), SUPPLY, SUPPLY + 1)
        );
    }

    function test_spenderPullsToItself() public {
        token.approve(alice, 15);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 15);
        assertEq(token.balanceOf(alice), 15);
        assertEq(token.balanceOf(address(this)), SUPPLY - 15);
    }

    /// @dev Documented in the README: the token contract is an ordinary receiver and has no way out.
    function test_tokensSentToTheTokenContractStayCountedAndCannotBePulled() public {
        token.transfer(address(token), 4e18);
        assertEq(token.balanceOf(address(token)), 4e18);
        assertEq(token.totalSupply(), SUPPLY);
        _refused(
            alice,
            abi.encodeCall(IErc20Surface.transferFrom, (address(token), alice, 1)),
            _insufficientAllowance(alice, 0, 1)
        );
        _refused(
            address(this),
            abi.encodeCall(IErc20Surface.transferFrom, (address(token), address(this), 4e18)),
            _insufficientAllowance(address(this), 0, 4e18)
        );
        assertEq(token.balanceOf(address(token)), 4e18);
    }

    // ---------------------------------------------------------------- error precedence

    function test_allowanceIsCheckedBeforeReceiverAndBalance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 5);
        // Short on allowance, on balance, and aimed at the zero address: the allowance error wins.
        _refused(
            bob, abi.encodeCall(IErc20Surface.transferFrom, (alice, address(0), 11)), _insufficientAllowance(bob, 5, 11)
        );
        // Enough allowance, zero receiver, short on balance: the receiver error wins.
        vm.prank(alice);
        token.approve(bob, 11);
        _refused(bob, abi.encodeCall(IErc20Surface.transferFrom, (alice, address(0), 11)), _invalidReceiver());
        // Enough allowance, valid receiver: only now the balance error.
        _refused(
            bob, abi.encodeCall(IErc20Surface.transferFrom, (alice, carol, 11)), _insufficientBalance(alice, 10, 11)
        );
        assertEq(token.allowance(alice, bob), 11);
        assertEq(token.balanceOf(alice), 10);
    }

    // ---------------------------------------------------------------- the zero address as `from`

    /// @dev Nobody holds an allowance from the zero address and it holds no tokens, so no value can be
    /// moved "from" it. The zero-value case is the reported finding and is not asserted here.
    function testFuzz_noValueCanBeMovedFromTheZeroAddress(address caller, address to, uint256 amount) public {
        amount = bound(amount, 1, MAX);
        _refused(
            caller,
            abi.encodeCall(IErc20Surface.transferFrom, (address(0), to, amount)),
            _insufficientAllowance(caller, 0, amount)
        );
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------- properties

    /// @dev Any sender, any receiver (the same account included), any amount up to twice the supply.
    function testFuzz_transferIsExactOrRefusedWithoutTrace(address from, address to, uint256 held, uint256 amount)
        public
    {
        from = address(uint160(bound(uint256(uint160(from)), 1, type(uint160).max)));
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, 2 * SUPPLY);
        token.transfer(from, held);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 deployerBefore = token.balanceOf(address(this));

        if (to == address(0)) {
            _refused(from, abi.encodeCall(IErc20Surface.transfer, (to, amount)), _invalidReceiver());
        } else if (amount > fromBefore) {
            _refused(
                from,
                abi.encodeCall(IErc20Surface.transfer, (to, amount)),
                _insufficientBalance(from, fromBefore, amount)
            );
        } else {
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
            if (from == to) {
                assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
            } else {
                assertEq(token.balanceOf(from), fromBefore - amount, "sender debited a different amount");
                assertEq(token.balanceOf(to), toBefore + amount, "receiver credited a different amount");
            }
            if (from != address(this) && to != address(this)) {
                assertEq(token.balanceOf(address(this)), deployerBefore, "a bystander's balance moved");
            }
            assertEq(token.totalSupply(), SUPPLY);
            return;
        }
        assertEq(token.balanceOf(from), fromBefore);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.balanceOf(address(this)), deployerBefore);
    }

    /// @dev alice owns `held`, bob is approved for `approved` (or unlimited), and bob asks for `amount`
    /// towards a receiver chosen to alias the owner, the spender, the token, nobody, or the zero address.
    function testFuzz_transferFromIsExactOrRefusedWithoutTrace(
        uint256 held,
        uint256 approved,
        uint256 amount,
        uint256 shape
    ) public {
        held = bound(held, 0, SUPPLY);
        bool unlimited = shape % 4 == 0;
        approved = unlimited ? MAX : bound(approved, 0, 2 * SUPPLY);
        // A third of the runs ask for more than the supply; the rest stay near the interesting bounds.
        amount = shape % 3 == 0 ? bound(amount, 0, 2 * SUPPLY) : bound(amount, 0, held + 1);
        address[5] memory receivers = [carol, alice, bob, address(token), address(0)];
        address to = receivers[(shape / 12) % 5];

        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, approved);

        uint256 toBefore = token.balanceOf(to);
        bytes memory call = abi.encodeCall(IErc20Surface.transferFrom, (alice, to, amount));

        if (!unlimited && amount > approved) {
            _refused(bob, call, _insufficientAllowance(bob, approved, amount));
        } else if (to == address(0)) {
            _refused(bob, call, _invalidReceiver());
        } else if (amount > held) {
            _refused(bob, call, _insufficientBalance(alice, held, amount));
        } else {
            vm.prank(bob);
            assertTrue(token.transferFrom(alice, to, amount));
            assertEq(token.allowance(alice, bob), unlimited ? MAX : approved - amount, "allowance spent inexactly");
            if (to == alice) {
                assertEq(token.balanceOf(alice), held);
            } else {
                assertEq(token.balanceOf(alice), held - amount, "owner debited a different amount");
                assertEq(token.balanceOf(to), toBefore + amount, "receiver credited a different amount");
            }
            if (to != bob) assertEq(token.balanceOf(bob), 0, "the spender was credited");
            assertEq(token.balanceOf(address(this)), SUPPLY - held);
            return;
        }
        assertEq(token.allowance(alice, bob), approved, "a refused spend changed the allowance");
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_sendingThereAndBackRestoresBothBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(alice, held);

        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
    }

    /// @dev Two tokens, one paid in two parts and one in a single transfer, end in the same state:
    /// no per-transfer fee, rounding or minimum hides in the arithmetic.
    function testFuzz_splitTransfersEqualOneTransfer(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        LaunchToken single = new LaunchToken();

        token.transfer(alice, first);
        token.transfer(alice, second);
        single.transfer(alice, first + second);

        assertEq(token.balanceOf(alice), single.balanceOf(alice));
        assertEq(token.balanceOf(address(this)), single.balanceOf(address(this)));
        assertEq(token.balanceOf(alice), first + second);
    }

    function testFuzz_approveSetsOverwritesAndTouchesNothingElse(address spender, uint256 first, uint256 second)
        public
    {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        address other = spender == bob ? carol : bob;
        token.approve(other, 77);

        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(address(this), spender), first);
        // The same approval again changes nothing; a different one replaces rather than adds.
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(address(this), spender), first);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);

        assertEq(token.allowance(address(this), other), 77, "another spender's allowance changed");
        if (spender != address(this)) {
            assertEq(token.allowance(spender, address(this)), 0, "approval leaked in the reverse direction");
        }
        assertEq(token.balanceOf(address(this)), SUPPLY, "approve moved tokens");
        assertEq(token.balanceOf(spender), spender == address(this) ? SUPPLY : 0);
    }

    /// @dev Many spenders drawing on one owner: together they take exactly what was approved to each,
    /// and the owner never loses more than the sum of what the spenders took.
    function testFuzz_severalSpendersNeverTakeMoreThanApproved(uint256[4] memory approved, uint256[4] memory asked)
        public
    {
        uint256 taken;
        for (uint256 i; i < 4; ++i) {
            address spender = address(uint160(0x5000 + i));
            approved[i] = bound(approved[i], 0, SUPPLY / 4);
            asked[i] = bound(asked[i], 0, SUPPLY / 2);
            token.approve(spender, approved[i]);

            vm.prank(spender);
            (bool ok,) =
                address(token).call(abi.encodeCall(IErc20Surface.transferFrom, (address(this), spender, asked[i])));

            assertEq(ok, asked[i] <= approved[i], "spend outcome disagrees with the allowance");
            if (ok) taken += asked[i];
            assertEq(token.balanceOf(spender), ok ? asked[i] : 0);
            assertEq(token.allowance(address(this), spender), ok ? approved[i] - asked[i] : approved[i]);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY - taken);
    }
}
