// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SuperTorchArena} from "../src/SuperTorchArena.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Super Torch", "SUPERTORCH") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// Stands in for KyberSwap's router in the server's end-to-end test: swaps ETH for tokens at `rate`.
contract MockKyberRouter {
    MockToken public t;
    uint256 public rate;

    constructor(MockToken t_, uint256 rate_) {
        t = t_;
        rate = rate_;
    }

    function swap(address recipient) external payable {
        t.mint(recipient, (msg.value * rate) / 1e18);
    }
}

contract RejectsEth {
    function enter(SuperTorchArena a) external payable {
        a.enter{value: msg.value}();
    }

    receive() external payable {
        revert();
    }
}

contract SuperTorchArenaTest is Test {
    SuperTorchArena arena;

    address owner = makeAddr("owner");
    address settler = makeAddr("settler");
    address treasury = makeAddr("treasury");
    address burnWallet = makeAddr("burnWallet");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant FEE = 0.004 ether;
    uint256 constant DAY = 1 days;

    event BurnFunded(address indexed burnWallet, uint256 amount);

    function setUp() public {
        vm.warp(1_790_000_000); // some time in 2026
        arena = new SuperTorchArena(0, FEE, owner, settler, treasury, burnWallet, [uint16(4000), 2000, 1000], 1500);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function _one(address a) internal pure returns (address[3] memory w) {
        w[0] = a;
    }

    function _sc(uint256 x) internal pure returns (uint256[3] memory v) {
        v[0] = x;
    }

    function _enter(address who) internal returns (uint256 entryId, uint256 raceId) {
        vm.prank(who);
        return arena.enter{value: FEE}();
    }

    function _endRace(uint256 raceId) internal {
        vm.warp(arena.raceEnd(raceId) + 1);
    }

    // ------------------------------------------------------------ entering

    function test_EnterRecordsEntry() public {
        (uint256 id1, uint256 race) = _enter(alice);
        (uint256 id2,) = _enter(bob);
        assertEq(id1, 1);
        assertEq(id2, 2);
        (uint256 pool, uint64 entries,,,) = arena.races(race);
        assertEq(pool, 2 * FEE);
        assertEq(entries, 2);
        assertEq(arena.paid(race, alice), FEE);
    }

    function test_EnterRequiresExactFee() public {
        vm.prank(alice);
        vm.expectRevert(SuperTorchArena.WrongFee.selector);
        arena.enter{value: FEE - 1}();
        vm.prank(alice);
        vm.expectRevert(SuperTorchArena.WrongFee.selector);
        arena.enter{value: FEE + 1}();
    }

    function test_PauseStopsEntriesOnly() public {
        (, uint256 race) = _enter(alice);
        vm.prank(owner);
        arena.pause();
        vm.prank(bob);
        vm.expectRevert();
        arena.enter{value: FEE}();
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(alice), _sc(100), bytes32(0)); // settlement still works
    }

    function test_RaceBoundaries() public {
        uint256 r = arena.currentRace();
        vm.warp(arena.raceEnd(r) - 1);
        assertEq(arena.currentRace(), r);
        vm.warp(arena.raceEnd(r));
        assertEq(arena.currentRace(), r + 1);
    }

    // ------------------------------------------------------------ settling and split

    function test_SettleSplitsPool() public {
        _enter(alice);
        _enter(bob);
        _enter(carol);
        (, uint256 race) = _enter(alice);
        uint256 pool = 4 * FEE;
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(bob), _sc(12345), keccak256("run"));

        // only 1st place filled: 40% to bob, 15% burn, 15% protocol, 2nd+3rd (30%) roll over
        assertEq(arena.claimable(bob), (pool * 4000) / 10000);
        assertEq(arena.burnOwed(), (pool * 1500) / 10000);
        assertEq(arena.protocolOwed(), (pool * 1500) / 10000);
        (uint256 nextPool,,,,) = arena.races(arena.currentRace());
        assertEq(nextPool, (pool * 3000) / 10000);

        uint256 before = bob.balance;
        vm.prank(bob);
        arena.claim();
        assertEq(bob.balance - before, (pool * 4000) / 10000);
        assertEq(arena.claimable(bob), 0);

        arena.withdrawProtocol();
        assertEq(treasury.balance, (pool * 1500) / 10000);
    }

    function test_OnlySettlerCanSettle() public {
        (, uint256 race) = _enter(alice);
        _endRace(race);
        vm.prank(alice);
        vm.expectRevert(SuperTorchArena.NotSettler.selector);
        arena.settle(race, _one(alice), _sc(1), bytes32(0));
    }

    function test_CannotSettleEarlyOrTwice() public {
        (, uint256 race) = _enter(alice);
        vm.prank(settler);
        vm.expectRevert(SuperTorchArena.RaceNotOver.selector);
        arena.settle(race, _one(alice), _sc(1), bytes32(0));
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(alice), _sc(1), bytes32(0));
        vm.prank(settler);
        vm.expectRevert(SuperTorchArena.AlreadySettled.selector);
        arena.settle(race, _one(alice), _sc(1), bytes32(0));
    }

    function test_WinnerMustHaveEntered() public {
        (, uint256 race) = _enter(alice);
        _endRace(race);
        vm.prank(settler);
        vm.expectRevert(SuperTorchArena.WinnerDidNotEnter.selector);
        arena.settle(race, _one(carol), _sc(1), bytes32(0));
    }

    function test_NoWinnerRollsPoolOver() public {
        (, uint256 race) = _enter(alice);
        _enter(bob);
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(address(0)), _sc(0), bytes32(0));
        uint256 next = arena.currentRace();
        (uint256 pool,,,,) = arena.races(next);
        assertEq(pool, 2 * FEE);

        // the rolled-over money goes to the next winner
        _enter(carol);
        _endRace(next);
        vm.prank(settler);
        arena.settle(next, _one(carol), _sc(1), bytes32(0));
        assertEq(arena.claimable(carol), (3 * FEE * 4000) / 10000);
    }

    // ------------------------------------------------------------ burn share

    function test_BurnShareGoesToBurnWallet() public {
        for (uint256 i; i < 8; i++) _enter(alice);
        uint256 race = arena.currentRace();
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(alice), _sc(1), bytes32(0));

        uint256 owed = arena.burnOwed(); // 15% of 0.032 ETH
        assertEq(owed, 0.0048 ether);
        vm.expectEmit(true, false, false, true);
        emit BurnFunded(burnWallet, owed);
        vm.prank(carol); // anyone can trigger it; the ETH always goes to the burn wallet
        arena.withdrawBurn();

        assertEq(burnWallet.balance, owed);
        assertEq(arena.burnOwed(), 0);
        assertEq(arena.totalSentToBurn(), owed);
        vm.expectRevert(SuperTorchArena.NothingToDo.selector);
        arena.withdrawBurn();
    }

    function test_BurnSharesAccumulateAcrossRaces() public {
        (, uint256 r1) = _enter(alice);
        _endRace(r1);
        vm.prank(settler);
        arena.settle(r1, _one(alice), _sc(1), bytes32(0));
        (, uint256 r2) = _enter(bob);
        _endRace(r2);
        vm.prank(settler);
        arena.settle(r2, _one(bob), _sc(1), bytes32(0));
        // race 2's pool also holds race 1's unfilled 2nd/3rd prizes (30% of FEE)
        uint256 pool2 = FEE + (FEE * 3000) / 10000;
        uint256 expected = (FEE * 1500) / 10000 + (pool2 * 1500) / 10000;
        assertEq(arena.burnOwed(), expected);
        arena.withdrawBurn();
        assertEq(arena.totalSentToBurn(), expected);
    }

    function test_OwnerCanChangeBurnWallet() public {
        address w2 = makeAddr("w2");
        vm.prank(alice);
        vm.expectRevert();
        arena.setBurnWallet(w2);
        vm.prank(owner);
        arena.setBurnWallet(w2);
        assertEq(arena.burnWallet(), w2);
        vm.prank(owner);
        vm.expectRevert(SuperTorchArena.ZeroAddress.selector);
        arena.setBurnWallet(address(0));
    }

    // ------------------------------------------------------------ safety valves

    function test_RefundIfNeverSettled() public {
        (, uint256 race) = _enter(alice);
        _enter(bob);
        vm.warp(arena.raceEnd(race) + 3 days);
        vm.prank(alice);
        vm.expectRevert(SuperTorchArena.RefundNotOpen.selector);
        arena.refund(race);

        vm.warp(arena.raceEnd(race) + 3 days + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        arena.refund(race);
        assertEq(alice.balance - before, FEE);

        vm.prank(alice);
        vm.expectRevert(SuperTorchArena.NothingToDo.selector);
        arena.refund(race);

        // settler can no longer settle once refunds are open
        vm.prank(settler);
        vm.expectRevert(SuperTorchArena.SettlementWindowClosed.selector);
        arena.settle(race, _one(bob), _sc(1), bytes32(0));
    }

    function test_NoRefundAfterSettle() public {
        (, uint256 race) = _enter(alice);
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(alice), _sc(1), bytes32(0));
        vm.warp(arena.raceEnd(race) + 10 days);
        vm.prank(alice);
        vm.expectRevert(SuperTorchArena.AlreadySettled.selector);
        arena.refund(race);
    }

    function test_SweepBurnsAbandonedFunds() public {
        (, uint256 race) = _enter(alice);
        _enter(bob);
        vm.warp(arena.raceEnd(race) + 3 days + 1);
        vm.prank(alice);
        arena.refund(race); // bob never refunds
        vm.expectRevert(SuperTorchArena.SweepNotOpen.selector);
        arena.sweepExpired(race);
        vm.warp(arena.raceEnd(race) + 33 days + 1);
        arena.sweepExpired(race);
        assertEq(arena.burnOwed(), FEE);
        (uint256 pool,, bool settled,,) = arena.races(race);
        assertEq(pool, 0);
        assertTrue(settled);
    }

    // ------------------------------------------------------------ admin and misc

    function test_OwnerOnlySetters() public {
        vm.startPrank(alice);
        vm.expectRevert();
        arena.setEntryFee(1);
        vm.expectRevert();
        arena.setSettler(alice);
        vm.expectRevert();
        arena.setTreasury(alice);
        vm.expectRevert();
        arena.setBurnWallet(alice);
        vm.stopPrank();

        vm.prank(owner);
        arena.setEntryFee(0.005 ether);
        assertEq(arena.entryFee(), 0.005 ether);
    }

    function test_SeedCommitOnlyBeforeRaceStarts() public {
        uint256 r = arena.currentRace();
        vm.prank(settler);
        arena.commitSeeds(r + 1, keccak256("seeds"));
        vm.prank(settler);
        vm.expectRevert(SuperTorchArena.AlreadyCommitted.selector);
        arena.commitSeeds(r + 1, keccak256("other"));
        _enter(alice);
        vm.prank(settler);
        vm.expectRevert(SuperTorchArena.RaceAlreadyStarted.selector);
        arena.commitSeeds(r, keccak256("late"));
    }

    function test_RejectsPlainEthTransfers() public {
        vm.prank(alice);
        (bool ok,) = address(arena).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_WinnerThatRejectsEthCannotBlockOthers() public {
        RejectsEth bad = new RejectsEth();
        vm.deal(address(this), 1 ether);
        bad.enter{value: FEE}(arena);
        (, uint256 race) = _enter(alice);
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(address(bad)), _sc(1), bytes32(0));
        // the bad winner can't claim, but protocol and burn payouts still work
        arena.withdrawProtocol();
        arena.withdrawBurn();
        assertEq(burnWallet.balance, (2 * FEE * 1500) / 10000);
    }

    // ------------------------------------------------------------ podium

    function test_PodiumSplit() public {
        for (uint256 i; i < 5; i++) _enter(alice);
        _enter(bob);
        _enter(carol);
        address dave = makeAddr("dave");
        vm.deal(dave, 1 ether);
        _enter(dave);
        _enter(dave);
        _enter(dave);
        uint256 race = arena.currentRace();
        uint256 pool = 10 * FEE;
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, [carol, alice, dave], [uint256(900), 800, 700], keccak256("run"));
        assertEq(arena.claimable(carol), (pool * 4000) / 10000);
        assertEq(arena.claimable(alice), (pool * 2000) / 10000);
        assertEq(arena.claimable(dave), (pool * 1000) / 10000);
        assertEq(arena.burnOwed(), (pool * 1500) / 10000);
        assertEq(arena.protocolOwed(), (pool * 1500) / 10000);
        // with 10 entries, 3rd place gets exactly their entry back
        assertEq(arena.claimable(dave), FEE);
        (,,, address w, uint256 sc) = arena.races(race);
        assertEq(w, carol);
        assertEq(sc, 900);
    }

    function test_TwoPlacesFilled() public {
        _enter(alice);
        (, uint256 race) = _enter(bob);
        uint256 pool = 2 * FEE;
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, [bob, alice, address(0)], [uint256(5), 4, 0], bytes32(0));
        assertEq(arena.claimable(bob), (pool * 4000) / 10000);
        assertEq(arena.claimable(alice), (pool * 2000) / 10000);
        (uint256 nextPool,,,,) = arena.races(arena.currentRace());
        assertEq(nextPool, (pool * 1000) / 10000, "3rd place prize rolls over");
    }

    function test_PodiumRules() public {
        _enter(alice);
        (, uint256 race) = _enter(bob);
        _endRace(race);
        vm.startPrank(settler);
        vm.expectRevert(SuperTorchArena.DuplicateWinner.selector);
        arena.settle(race, [alice, alice, address(0)], [uint256(5), 4, 0], bytes32(0));
        vm.expectRevert(SuperTorchArena.WinnerDidNotEnter.selector);
        arena.settle(race, [alice, carol, address(0)], [uint256(5), 4, 0], bytes32(0));
        vm.expectRevert(SuperTorchArena.BadConfig.selector);
        arena.settle(race, [alice, address(0), bob], [uint256(5), 0, 3], bytes32(0));
        vm.stopPrank();
    }

    function test_ConstructorRejectsBadSplits() public {
        vm.expectRevert(SuperTorchArena.BadConfig.selector);
        new SuperTorchArena(0, FEE, owner, settler, treasury, burnWallet, [uint16(6000), 3000, 1000], 1000); // 110%
        vm.expectRevert(SuperTorchArena.BadConfig.selector);
        new SuperTorchArena(0, FEE, owner, settler, treasury, burnWallet, [uint16(0), 3000, 1000], 1000); // no 1st prize
        SuperTorchArena custom = new SuperTorchArena(0, FEE, owner, settler, treasury, burnWallet, [uint16(5000), 1500, 500], 1500);
        assertEq(custom.placeBps(0), 5000);
        assertEq(custom.burnBps(), 1500);
    }

    /// The contract always holds at least what it owes.
    function testFuzz_Solvency(uint8 nEntries, uint8 winnerIdx) public {
        uint256 n = bound(nEntries, 1, 40);
        address[3] memory ps = [alice, bob, carol];
        for (uint256 i; i < n; i++) _enter(ps[i % 3]);
        uint256 race = arena.currentRace();
        address w = ps[bound(winnerIdx, 0, n < 3 ? n - 1 : 2)];
        _endRace(race);
        vm.prank(settler);
        arena.settle(race, _one(w), _sc(1), bytes32(0));
        (uint256 rolled,,,,) = arena.races(arena.currentRace());
        uint256 owed = arena.claimable(w) + arena.protocolOwed() + arena.burnOwed() + rolled;
        assertGe(address(arena).balance, owed);
        assertEq(owed, n * FEE);
    }
}
