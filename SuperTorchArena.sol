// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Super Torch Arena
/// @notice Daily paid-entry races for Super Torch.
///         Entry fees are paid in ETH. When a race ends, a trusted settler (the run
///         verification server) names the top 3 verified runners (one place per wallet).
///         The pool is split by percentages fixed at deployment: 1st/2nd/3rd place prizes
///         (claimable by the winners), a burn share sent to the burn worker wallet (which buys
///         the token back and sends it to the dead address), and the rest to the protocol.
///         Prizes for places nobody filled roll over into the next race.
///         If the settler never settles a race, every entrant can refund themselves.
contract SuperTorchArena is Ownable2Step, ReentrancyGuard, Pausable {
    // ---------------------------------------------------------------- constants
    uint256 public constant RACE_LENGTH = 1 days;
    uint256 public constant REFUND_DELAY = 3 days; // settle window after a race ends
    uint256 public constant SWEEP_DELAY = 30 days; // after the refund window opens

    // ---------------------------------------------------------------- config
    uint256 public immutable resetOffset; // seconds after 00:00 UTC when races roll over
    // Split in basis points (100 = 1%), fixed forever at deployment. The protocol gets what's left.
    uint16 public immutable firstBps;
    uint16 public immutable secondBps;
    uint16 public immutable thirdBps;
    uint16 public immutable burnBps;

    uint256 public entryFee; // in wei
    address public settler; // verification server's hot wallet
    address public treasury; // protocol share destination
    address public burnWallet; // burn worker wallet: buys the token back and sends it to 0x...dEaD

    // ---------------------------------------------------------------- state
    struct Race {
        uint256 pool; // ETH currently attributed to this race
        uint64 entries;
        bool settled; // settled, rolled over, or swept
        address winner; // 1st place
        uint256 score; // 1st place score
    }

    mapping(uint256 => Race) public races;
    mapping(uint256 => mapping(address => uint256)) public paid; // raceId => player => wei paid
    mapping(uint256 => bytes32) public seedCommit; // raceId => commitment to that race's run seeds

    mapping(address => uint256) public claimable; // winnings waiting to be claimed
    uint256 public protocolOwed;
    uint256 public burnOwed; // ETH waiting to be sent to the burn worker

    uint256 public totalSentToBurn; // all ETH ever sent to the burn worker (read by the website)
    uint256 public nextEntryId = 1;

    // ---------------------------------------------------------------- events
    event Entered(uint256 indexed raceId, address indexed player, uint256 indexed entryId, uint256 fee);
    event RaceSettled(
        uint256 indexed raceId,
        address[3] winners,
        uint256[3] scores,
        uint256[3] prizes,
        bytes32 runHash,
        uint256 pool,
        uint256 burnShare,
        uint256 protocolShare,
        uint256 rolledOver
    );
    event RaceRolledOver(uint256 indexed fromRace, uint256 indexed toRace, uint256 amount);
    event RaceSwept(uint256 indexed raceId, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event Refunded(uint256 indexed raceId, address indexed player, uint256 amount);
    event ProtocolWithdrawn(address indexed treasury, uint256 amount);
    event BurnFunded(address indexed burnWallet, uint256 amount);
    event SeedsCommitted(uint256 indexed raceId, bytes32 commitment);
    event EntryFeeUpdated(uint256 fee);
    event SettlerUpdated(address indexed settler);
    event TreasuryUpdated(address indexed treasury);
    event BurnWalletUpdated(address indexed burnWallet);

    // ---------------------------------------------------------------- errors
    error WrongFee();
    error NotSettler();
    error RaceNotOver();
    error SettlementWindowClosed();
    error AlreadySettled();
    error WinnerDidNotEnter();
    error DuplicateWinner();
    error RefundNotOpen();
    error SweepNotOpen();
    error NothingToDo();
    error AlreadyCommitted();
    error RaceAlreadyStarted();
    error ZeroAddress();
    error TransferFailed();
    error BadConfig();

    constructor(
        uint256 resetOffset_,
        uint256 entryFee_,
        address owner_,
        address settler_,
        address treasury_,
        address burnWallet_,
        uint16[3] memory placeBps_,
        uint16 burnBps_
    ) Ownable(owner_) {
        if (settler_ == address(0) || treasury_ == address(0) || burnWallet_ == address(0)) revert ZeroAddress();
        if (resetOffset_ >= RACE_LENGTH || entryFee_ == 0) revert BadConfig();
        if (placeBps_[0] == 0 || uint256(placeBps_[0]) + placeBps_[1] + placeBps_[2] + burnBps_ > 10_000) revert BadConfig();
        resetOffset = resetOffset_;
        firstBps = placeBps_[0];
        secondBps = placeBps_[1];
        thirdBps = placeBps_[2];
        burnBps = burnBps_;
        entryFee = entryFee_;
        settler = settler_;
        treasury = treasury_;
        burnWallet = burnWallet_;
    }

    // ================================================================ views

    /// @notice Prize for place `i` (0 = 1st), in basis points.
    function placeBps(uint256 i) public view returns (uint16) {
        return i == 0 ? firstBps : i == 1 ? secondBps : thirdBps;
    }

    function currentRace() public view returns (uint256) {
        return (block.timestamp - resetOffset) / RACE_LENGTH;
    }

    /// @notice Unix time when `raceId` ends (and the next race starts).
    function raceEnd(uint256 raceId) public view returns (uint256) {
        return (raceId + 1) * RACE_LENGTH + resetOffset;
    }

    // ================================================================ players

    /// @notice Pay the entry fee for one ranked run in today's race.
    /// @return entryId Give this to the verification server to receive the run's seed.
    function enter() external payable whenNotPaused returns (uint256 entryId, uint256 raceId) {
        if (msg.value != entryFee) revert WrongFee();
        raceId = currentRace();
        Race storage r = races[raceId];
        r.pool += msg.value;
        r.entries += 1;
        paid[raceId][msg.sender] += msg.value;
        entryId = nextEntryId++;
        emit Entered(raceId, msg.sender, entryId, msg.value);
    }

    /// @notice Winners pull their prize.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToDo();
        claimable[msg.sender] = 0;
        _send(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Safety valve: if a race was never settled within REFUND_DELAY,
    ///         every entrant can take back exactly what they paid.
    function refund(uint256 raceId) external nonReentrant {
        Race storage r = races[raceId];
        if (r.settled) revert AlreadySettled();
        if (block.timestamp <= raceEnd(raceId) + REFUND_DELAY) revert RefundNotOpen();
        uint256 amount = paid[raceId][msg.sender];
        if (amount == 0) revert NothingToDo();
        paid[raceId][msg.sender] = 0;
        r.pool -= amount;
        _send(msg.sender, amount);
        emit Refunded(raceId, msg.sender, amount);
    }

    // ================================================================ settler

    /// @notice Commit to the seeds that will be handed out for a race before it starts,
    ///         so players can later check the seeds weren't chosen after the fact.
    function commitSeeds(uint256 raceId, bytes32 commitment) external {
        if (msg.sender != settler) revert NotSettler();
        if (seedCommit[raceId] != bytes32(0)) revert AlreadyCommitted();
        if (raceId < currentRace() || (raceId == currentRace() && races[raceId].entries > 0)) {
            revert RaceAlreadyStarted();
        }
        seedCommit[raceId] = commitment;
        emit SeedsCommitted(raceId, commitment);
    }

    /// @notice Settle a finished race with the top 3 verified runners, best first.
    ///         Use address(0) for places nobody filled; their prizes roll into the current race.
    ///         `winners[0] == address(0)` means no verified run at all: the whole pool rolls over.
    ///         Each wallet can hold only one place.
    /// @param runHash Hash of the winning run's seed + input log, so anyone can replay it.
    function settle(uint256 raceId, address[3] calldata winners, uint256[3] calldata scores, bytes32 runHash) external {
        if (msg.sender != settler) revert NotSettler();
        uint256 end = raceEnd(raceId);
        if (block.timestamp < end) revert RaceNotOver();
        if (block.timestamp > end + REFUND_DELAY) revert SettlementWindowClosed();
        Race storage r = races[raceId];
        if (r.settled) revert AlreadySettled();
        r.settled = true;
        uint256 pool = r.pool;
        uint256 cur = currentRace();

        if (winners[0] == address(0)) {
            r.pool = 0;
            races[cur].pool += pool;
            emit RaceRolledOver(raceId, cur, pool);
            return;
        }

        uint256[3] memory prizes = [uint256(0), 0, 0];
        uint256 rolled = 0;
        for (uint256 i; i < 3; i++) {
            uint256 prize = (pool * placeBps(i)) / 10_000;
            address w = winners[i];
            if (w == address(0)) {
                rolled += prize;
                continue;
            }
            if (paid[raceId][w] == 0) revert WinnerDidNotEnter();
            for (uint256 j; j < i; j++) if (winners[j] == w) revert DuplicateWinner();
            if (i > 0 && winners[i - 1] == address(0)) revert BadConfig(); // places must be filled in order
            claimable[w] += prize;
            prizes[i] = prize;
        }
        uint256 burnShare = (pool * burnBps) / 10_000;
        uint256 protocolShare = pool - prizes[0] - prizes[1] - prizes[2] - rolled - burnShare;

        r.winner = winners[0];
        r.score = scores[0];
        r.pool = pool - rolled;
        if (rolled > 0) {
            races[cur].pool += rolled;
            emit RaceRolledOver(raceId, cur, rolled);
        }
        protocolOwed += protocolShare;
        burnOwed += burnShare;

        emit RaceSettled(raceId, winners, scores, prizes, runHash, pool, burnShare, protocolShare, rolled);
    }

    // ================================================================ anyone

    /// @notice Sends the protocol share to the treasury. Anyone can trigger it.
    function withdrawProtocol() external nonReentrant {
        uint256 amount = protocolOwed;
        if (amount == 0) revert NothingToDo();
        protocolOwed = 0;
        _send(treasury, amount);
        emit ProtocolWithdrawn(treasury, amount);
    }

    /// @notice Sends the burn share to the burn worker wallet. Anyone can trigger it.
    function withdrawBurn() external nonReentrant {
        uint256 amount = burnOwed;
        if (amount == 0) revert NothingToDo();
        burnOwed = 0;
        totalSentToBurn += amount;
        _send(burnWallet, amount);
        emit BurnFunded(burnWallet, amount);
    }

    /// @notice If a race was never settled and entrants had SWEEP_DELAY to refund,
    ///         whatever is left (e.g. rolled-over funds, unclaimed refunds) is burned,
    ///         never handed to the operator.
    function sweepExpired(uint256 raceId) external {
        Race storage r = races[raceId];
        if (r.settled) revert AlreadySettled();
        if (block.timestamp <= raceEnd(raceId) + REFUND_DELAY + SWEEP_DELAY) revert SweepNotOpen();
        uint256 amount = r.pool;
        if (amount == 0) revert NothingToDo();
        r.settled = true;
        r.pool = 0;
        burnOwed += amount;
        emit RaceSwept(raceId, amount);
    }

    // ================================================================ owner (use a multisig)

    function setEntryFee(uint256 fee) external onlyOwner {
        if (fee == 0) revert BadConfig();
        entryFee = fee;
        emit EntryFeeUpdated(fee);
    }

    function setSettler(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        settler = s;
        emit SettlerUpdated(s);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function setBurnWallet(address w) external onlyOwner {
        if (w == address(0)) revert ZeroAddress();
        burnWallet = w;
        emit BurnWalletUpdated(w);
    }

    /// @notice Pausing only stops new entries. Claims, refunds and settlement keep working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ================================================================ internals

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {
        revert();
    }
}
