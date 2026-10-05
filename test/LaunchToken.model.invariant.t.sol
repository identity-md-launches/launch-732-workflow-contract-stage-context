// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Drives the token with valid AND invalid calls and predicts each outcome from a reference
/// ledger kept here. Unlike a handler that bounds every input into the happy path, about half of
/// these calls must be refused, and each refusal is checked for the exact error it carries.
///
/// The suite that uses this handler runs with fail-on-revert enabled, so an assertion that fails in
/// here fails the campaign. (Under the repository default, fail_on_revert = false, a failed handler
/// assertion is just one more ignored revert.)
contract LaunchTokenModelHandler is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant MAX = type(uint256).max;

    LaunchToken public immutable token;
    address public immutable factory;

    /// @dev Accounts that can sign: the factory, which starts with everything, and four users.
    address[] internal _signers;
    /// @dev Every address a call may name: the signers, the token itself, and the zero address.
    address[] internal _named;

    // ---- reference ledger
    mapping(address account => uint256) public modelBalance;
    mapping(address owner => mapping(address spender => uint256)) public modelAllowance;

    // ---- ghosts that do not depend on the ledger's bookkeeping
    /// @dev Everything `spender` has ever moved out of `owner` with transferFrom.
    mapping(address owner => mapping(address spender => uint256)) public pulled;
    /// @dev Everything `owner` has ever approved to `spender`, summed and saturating at the maximum.
    mapping(address owner => mapping(address spender => uint256)) public approvedTotal;
    /// @dev Everything ever sent to the token contract's own address.
    uint256 public sentToToken;
    /// @dev Times a transferFrom was accepted that took a pair past everything approved to it.
    uint256 public overPulls;
    /// @dev The (owner, spender) pair named by the latest approve or transferFrom.
    address public lastOwner;
    address public lastSpender;

    uint256 public accepted;
    uint256 public refused;
    uint256 public movedValue;

    constructor() {
        factory = makeAddr("factory");
        vm.prank(factory);
        token = new LaunchToken();

        _signers.push(factory);
        _signers.push(makeAddr("alice"));
        _signers.push(makeAddr("bob"));
        _signers.push(makeAddr("carol"));
        _signers.push(makeAddr("dave"));

        for (uint256 i; i < _signers.length; ++i) {
            _named.push(_signers[i]);
        }
        _named.push(address(token));
        _named.push(address(0));

        modelBalance[factory] = SUPPLY;

        // Start from a spread a launch could produce, so value circulates from the first call:
        // two funded users, one holding a single unit, and one who never received anything.
        _seed(_signers[1], 250_000_000e18);
        _seed(_signers[2], 150_000_000e18);
        _seed(_signers[3], 1);
    }

    function _seed(address to, uint256 amount) private {
        vm.prank(factory);
        token.transfer(to, amount);
        modelBalance[factory] -= amount;
        modelBalance[to] += amount;
    }

    function named(uint256 index) external view returns (address) {
        return _named[index];
    }

    function allNamed() external view returns (address[] memory) {
        return _named;
    }

    /// @dev The ledger's balance for every named address, in `allNamed` order.
    function ledgerBalances() external view returns (uint256[] memory balances) {
        uint256 count = _named.length;
        balances = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = modelBalance[_named[i]];
        }
    }

    /// @dev The ledger's allowances granted by one named owner to every named spender.
    function ledgerAllowanceRow(uint256 ownerIndex) external view returns (uint256[] memory row) {
        uint256 count = _named.length;
        address owner = _named[ownerIndex];
        row = new uint256[](count);
        for (uint256 j; j < count; ++j) {
            row[j] = modelAllowance[owner][_named[j]];
        }
    }

    function steps() external view returns (uint256) {
        return accepted + refused;
    }

    // ---------------------------------------------------------------- actions

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 mode, uint256 raw) external {
        address from = _signers[fromSeed % _signers.length];
        address to = _named[toSeed % _named.length];
        uint256 balance = modelBalance[from];
        uint256 amount = _amount(mode, raw, balance, balance);

        bytes memory expected;
        if (to == address(0)) {
            expected = abi.encodeWithSelector(LaunchToken.InvalidReceiver.selector, address(0));
        } else if (amount > balance) {
            expected = abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, from, balance, amount);
        }

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertEq(expected.length, 0, "transfer accepted where it must be refused");
            assertTrue(ok, "transfer returned false");
            _move(from, to, amount);
        } catch (bytes memory reason) {
            _checkRefusal(reason, expected, "transfer");
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 mode, uint256 raw) external {
        address owner = _signers[ownerSeed % _signers.length];
        address spender = _named[spenderSeed % _named.length];
        uint256 amount = _approval(mode, raw, modelBalance[owner]);

        bytes memory expected;
        if (spender == address(0)) {
            expected = abi.encodeWithSelector(LaunchToken.InvalidSpender.selector, address(0));
        }

        (lastOwner, lastSpender) = (owner, spender);
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            assertEq(expected.length, 0, "approve accepted where it must be refused");
            assertTrue(ok, "approve returned false");
            modelAllowance[owner][spender] = amount;
            uint256 total = approvedTotal[owner][spender];
            approvedTotal[owner][spender] = amount > MAX - total ? MAX : total + amount;
            ++accepted;
        } catch (bytes memory reason) {
            _checkRefusal(reason, expected, "approve");
        }
    }

    /// @dev `from` may be the token contract itself: nothing sent there can ever be pulled back out.
    /// The zero address is not used as `from`; that case is covered by a reported finding.
    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 mode, uint256 raw) external {
        address spender = _signers[spenderSeed % _signers.length];
        address from = _named[fromSeed % (_named.length - 1)];
        address to = _named[toSeed % _named.length];
        uint256 balance = modelBalance[from];
        uint256 allowed = modelAllowance[from][spender];
        uint256 amount = _amount(mode, raw, balance, allowed);

        bytes memory expected;
        if (allowed != MAX && amount > allowed) {
            expected = abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, spender, allowed, amount);
        } else if (to == address(0)) {
            expected = abi.encodeWithSelector(LaunchToken.InvalidReceiver.selector, address(0));
        } else if (amount > balance) {
            expected = abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, from, balance, amount);
        }

        (lastOwner, lastSpender) = (from, spender);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            assertEq(expected.length, 0, "transferFrom accepted where it must be refused");
            assertTrue(ok, "transferFrom returned false");
            if (allowed != MAX) modelAllowance[from][spender] = allowed - amount;
            pulled[from][spender] += amount;
            if (pulled[from][spender] > approvedTotal[from][spender]) ++overPulls;
            _move(from, to, amount);
        } catch (bytes memory reason) {
            _checkRefusal(reason, expected, "transferFrom");
        }
    }

    /// @dev Anything that is not one of the nine ERC-20 selectors, from any signer, with or without ETH.
    function unknownCall(uint256 callerSeed, bytes4 selector, bytes calldata args, uint256 value) external {
        while (_isErc20Selector(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        address caller = _signers[callerSeed % _signers.length];
        value = bound(value, 0, 1 ether);
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(abi.encodePacked(selector, args));
        assertFalse(ok, "token answered a selector that is not ERC-20");
        ++refused;
    }

    /// @dev A well-formed transfer, approve or transferFrom that carries ETH must be refused whole.
    function payableCall(uint256 callerSeed, uint256 functionSeed, uint256 toSeed, uint256 value) external {
        address caller = _signers[callerSeed % _signers.length];
        address to = _signers[toSeed % _signers.length];
        value = bound(value, 1, 1 ether);
        vm.deal(caller, value);

        bytes memory data;
        if (functionSeed % 3 == 0) data = abi.encodeCall(LaunchToken.transfer, (to, 0));
        else if (functionSeed % 3 == 1) data = abi.encodeCall(LaunchToken.approve, (to, modelAllowance[caller][to]));
        else data = abi.encodeCall(LaunchToken.transferFrom, (caller, to, 0));

        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(data);
        assertFalse(ok, "token accepted ETH");
        ++refused;
    }

    // ---------------------------------------------------------------- internals

    function _move(address from, address to, uint256 amount) internal {
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
        if (to == address(token) && from != address(token)) sentToToken += amount;
        movedValue += amount;
        ++accepted;
    }

    function _checkRefusal(bytes memory reason, bytes memory expected, string memory what) internal {
        assertGt(expected.length, 0, string.concat(what, " refused where it must be accepted"));
        assertEq(reason, expected, string.concat(what, " refused with the wrong error"));
        ++refused;
    }

    /// @dev Amounts aimed at the edges: nothing, one unit, exactly the balance or allowance, one more
    /// than either, the maximum, anything at all, and (a third of the time) an amount that fits both.
    function _amount(uint256 mode, uint256 raw, uint256 balance, uint256 allowed) internal pure returns (uint256) {
        mode %= 12;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return balance;
        if (mode == 3) return balance + 1;
        if (mode == 4) return allowed;
        if (mode == 5) return allowed == MAX ? MAX : allowed + 1;
        if (mode == 6) return MAX;
        if (mode == 7) return raw;
        return bound(raw, 0, balance < allowed ? balance : allowed);
    }

    function _approval(uint256 mode, uint256 raw, uint256 balance) internal pure returns (uint256) {
        mode %= 8;
        if (mode == 0) return 0;
        if (mode == 1) return MAX;
        if (mode == 2) return MAX - 1;
        if (mode == 3) return balance;
        if (mode == 4) return raw;
        return bound(raw, 0, SUPPLY);
    }

    function _isErc20Selector(bytes4 selector) internal view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.balanceOf.selector || selector == token.allowance.selector
            || selector == token.transfer.selector || selector == token.approve.selector
            || selector == token.transferFrom.selector;
    }
}

/// @notice Stateful invariants for LaunchToken over random sequences of accepted and refused calls.
/// @dev The token holds every balance of the launch, so what it records must always equal what the
/// calls it accepted add up to: nothing created, nothing destroyed, nothing moved without the
/// owner's signature or an allowance the owner gave.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenModelInvariantTest is Test {
    uint256 internal constant SUPPLY = 1e27;

    LaunchTokenModelHandler internal handler;
    LaunchToken internal token;
    bytes32 internal codeHashAtDeployment;

    function setUp() public {
        handler = new LaunchTokenModelHandler();
        token = handler.token();
        codeHashAtDeployment = address(token).codehash;

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = LaunchTokenModelHandler.transfer.selector;
        selectors[1] = LaunchTokenModelHandler.approve.selector;
        selectors[2] = LaunchTokenModelHandler.transferFrom.selector;
        selectors[3] = LaunchTokenModelHandler.unknownCall.selector;
        selectors[4] = LaunchTokenModelHandler.payableCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Conservation: the supply is the constant, the named accounts hold all of it between them,
    /// and none of it is ever credited to the zero address.
    function invariant_supplyIsFixedAndFullyHeldByKnownAccounts() public view {
        assertEq(token.totalSupply(), SUPPLY, "total supply changed");
        address[] memory accounts = handler.allNamed();
        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            uint256 balance = token.balanceOf(accounts[i]);
            assertLe(balance, SUPPLY, "one account holds more than the supply");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0, "tokens were burned to the zero address");
    }

    /// @dev Every balance equals what the accepted calls add up to: no fee, no rounding, no side credit.
    function invariant_balancesMatchTheLedger() public view {
        address[] memory accounts = handler.allNamed();
        uint256[] memory expected = handler.ledgerBalances();
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(token.balanceOf(accounts[i]), expected[i], "balance differs from the ledger");
        }
    }

    /// @dev Every allowance equals the last approval minus what was spent from it, and the pairs
    /// nobody can approve (zero spender, zero owner, the token as owner) stay at zero. After each call
    /// this checks the pair that call named plus one owner's whole row, rotating through the owners;
    /// `afterInvariant` checks every pair at the end of each run.
    function invariant_allowancesMatchTheLedger() public view {
        address owner = handler.lastOwner();
        address spender = handler.lastSpender();
        assertEq(
            token.allowance(owner, spender),
            handler.modelAllowance(owner, spender),
            "allowance differs from the ledger for the pair just used"
        );
        address[] memory accounts = handler.allNamed();
        _checkAllowanceRow(accounts, handler.steps() % accounts.length);
    }

    /// @dev Authorisation, stated without the ledger: a spender has never moved more out of an owner
    /// than that owner approved to that spender in total.
    function invariant_spendersNeverPullMoreThanTheyWereApproved() public view {
        assertEq(handler.overPulls(), 0, "a spender pulled more than it was ever approved");
    }

    /// @dev The token contract is a one-way receiver, holds no ETH, and its code never changes.
    function invariant_tokenContractOnlyAccumulatesAndStaysInert() public view {
        assertEq(token.balanceOf(address(token)), handler.sentToToken(), "tokens left the token contract");
        assertEq(address(token).balance, 0, "token holds ETH");
        assertEq(address(token).codehash, codeHashAtDeployment, "token code changed");
    }

    /// @dev End of each run: every allowance pair is compared with the ledger, and a full-length run in
    /// which nothing was accepted, or nothing was refused, is rejected as having checked only half of
    /// the token's behaviour.
    function afterInvariant() public view {
        _checkEveryAllowance();
        if (handler.steps() < 50) return;
        assertGt(handler.accepted(), 0, "no call was ever accepted");
        assertGt(handler.refused(), 0, "no call was ever refused");
    }

    function _checkEveryAllowance() internal view {
        address[] memory accounts = handler.allNamed();
        for (uint256 i; i < accounts.length; ++i) {
            _checkAllowanceRow(accounts, i);
        }
    }

    function _checkAllowanceRow(address[] memory accounts, uint256 ownerIndex) internal view {
        address owner = accounts[ownerIndex];
        uint256[] memory expected = handler.ledgerAllowanceRow(ownerIndex);
        for (uint256 j; j < accounts.length; ++j) {
            uint256 allowed = token.allowance(owner, accounts[j]);
            assertEq(allowed, expected[j], "allowance differs from the ledger");
            if (owner == address(0) || owner == address(token) || accounts[j] == address(0)) {
                assertEq(allowed, 0, "an allowance exists that nobody could have approved");
            }
        }
    }

    // ---------------------------------------------------------------- the harness itself

    /// @dev A fixed sequence through the handler, so the ledger and ghosts are known to move with the
    /// token rather than only being trusted inside the random campaign.
    function test_handlerTracksAKnownSequence() public {
        address factory = handler.factory();
        address alice = handler.named(1);
        address bob = handler.named(2);
        address dave = handler.named(4);
        uint256 aliceStart = token.balanceOf(alice);
        uint256 factoryStart = token.balanceOf(factory);
        assertEq(aliceStart, 250_000_000e18);
        assertEq(token.balanceOf(dave), 0);

        // factory -> alice, whole balance (mode 2).
        handler.transfer(0, 1, 2, 0);
        uint256 aliceNow = aliceStart + factoryStart;
        assertEq(token.balanceOf(alice), aliceNow);
        assertEq(handler.modelBalance(alice), aliceNow);
        assertEq(token.balanceOf(factory), 0);
        assertEq(handler.movedValue(), factoryStart);

        // factory -> alice, one unit (mode 1): refused, the factory is empty.
        handler.transfer(0, 1, 1, 0);
        assertEq(handler.refused(), 1);

        // alice approves bob for her balance (mode 3); bob pulls all of it into the token (mode 4).
        handler.approve(1, 2, 3, 0);
        assertEq(token.allowance(alice, bob), aliceNow);
        handler.transferFrom(2, 1, 5, 4, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), aliceNow);
        assertEq(handler.sentToToken(), aliceNow);
        assertEq(handler.pulled(alice, bob), aliceNow);
        assertEq(handler.approvedTotal(alice, bob), aliceNow);
        assertEq(token.allowance(alice, bob), 0);

        // bob tries to pull one unit back out of the token contract (mode 1): refused.
        handler.transferFrom(2, 5, 2, 1, 0);
        assertEq(handler.refused(), 2);
        assertEq(handler.accepted(), 3);
        assertEq(token.balanceOf(address(token)), aliceNow);

        // Towards the zero address (index 6), with ETH attached, and through a mint selector: refused.
        handler.transfer(2, 6, 1, 0);
        handler.approve(1, 6, 1, 0);
        handler.payableCall(1, 0, 2, 1);
        handler.unknownCall(1, bytes4(keccak256("mint(address,uint256)")), abi.encode(alice, 1), 0);
        assertEq(handler.refused(), 6);
        assertEq(handler.accepted(), 3);

        invariant_supplyIsFixedAndFullyHeldByKnownAccounts();
        invariant_balancesMatchTheLedger();
        invariant_allowancesMatchTheLedger();
        invariant_spendersNeverPullMoreThanTheyWereApproved();
        invariant_tokenContractOnlyAccumulatesAndStaysInert();
        _checkEveryAllowance();
    }
}
