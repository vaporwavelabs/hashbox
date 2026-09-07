// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HashBox
/// @notice Timed prize-pool. Users lock native value into a numbered box during
///         enrollment. After enrollment the box locks. After lock a commit-reveal
///         draw picks one number. A matching ticket claims the whole pot.
///         A miss keeps the pot locked for the next campaign.
/// @dev Demo-grade randomness (commit-reveal + close-blockhash). Swap reveal
///      for VRF before any public mainnet pool. This mechanic is a raffle.
contract HashBox {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancy;

    uint32 public constant MIN_NUMBER_RANGE = 100;
    uint32 public constant MAX_NUMBER_RANGE = 10_000;
    uint32 public constant MIN_ENROLL_SECONDS = 30;
    uint32 public constant MAX_ENROLL_SECONDS = 7 days;
    uint16 public constant MIN_CYCLES = 1;
    uint16 public constant MAX_CYCLES = 30;
    uint256 public constant MIN_OPERATOR_BOND = 0.01 ether;
    uint256 public constant REVEAL_GRACE = 1 days;
    uint256 public constant CLAIM_WINDOW = 7 days;

    enum Status {
        None,
        Open,
        Locked,
        Closed,
        Revealed,
        Claimed,
        Rolled
    }

    struct Campaign {
        address operator;
        uint64 createdAt;
        uint64 enrollEnd;
        uint64 lockEnd;
        uint32 cycleSeconds;
        uint16 cycleCount;
        uint32 numberRange;
        uint32 ticketCount;
        uint32 winningNumber;
        Status status;
        uint256 minEntrance;
        uint256 pot;
        uint256 bond;
        bytes32 commitHash;
        bytes32 closeBlockHash;
        address winner;
    }

    uint256 public campaignCount;
    uint256 public lockedRollover;
    address public owner;

    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(uint32 => address)) public ticketOwner;
    mapping(uint256 => mapping(address => uint32)) public ticketOf;
    mapping(uint256 => mapping(address => uint256)) public stakeOf;
    mapping(uint256 => address[]) public enrolled;

    event CampaignOpened(
        uint256 indexed id,
        address indexed operator,
        uint32 cycleSeconds,
        uint16 cycleCount,
        uint64 enrollEnd,
        uint64 lockEnd,
        uint256 minEntrance,
        uint256 rolledIn
    );
    event Staked(uint256 indexed id, address indexed user, uint32 number, uint256 amount);
    event Locked(uint256 indexed id);
    event Closed(uint256 indexed id, bytes32 closeBlockHash);
    event Revealed(uint256 indexed id, uint32 winningNumber, address winner);
    event Claimed(uint256 indexed id, address indexed winner, uint256 amount);
    event Rolled(uint256 indexed id, uint256 amount);
    event BondSlashed(uint256 indexed id, uint256 amount);

    error NotOwner();
    error InvalidCycle();
    error InvalidCycles();
    error InvalidEnroll();
    error InvalidRange();
    error BondTooLow();
    error BadCommit();
    error NotOpen();
    error NotLocked();
    error NotClosed();
    error NotRevealed();
    error TooEarly();
    error TooLate();
    error AlreadyTicketed();
    error NumberTaken();
    error NumberOOB();
    error BelowMinimum();
    error BadReveal();
    error NotWinner();
    error NoWinner();
    error TransferFailed();
    error Reentrancy();
    error AlreadySettled();

    modifier nonReentrant() {
        if (_reentrancy == _ENTERED) revert Reentrancy();
        _reentrancy = _ENTERED;
        _;
        _reentrancy = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        _reentrancy = _NOT_ENTERED;
        owner = msg.sender;
    }

    function createCampaign(
        uint32 cycleSeconds,
        uint16 cycleCount,
        uint32 enrollSeconds,
        uint32 numberRange,
        uint256 minEntrance,
        bytes32 commitHash
    ) external payable nonReentrant returns (uint256 id) {
        if (!_validCycle(cycleSeconds)) revert InvalidCycle();
        if (cycleCount < MIN_CYCLES || cycleCount > MAX_CYCLES) revert InvalidCycles();
        if (enrollSeconds < MIN_ENROLL_SECONDS || enrollSeconds > MAX_ENROLL_SECONDS) revert InvalidEnroll();
        if (numberRange < MIN_NUMBER_RANGE || numberRange > MAX_NUMBER_RANGE) revert InvalidRange();
        if (msg.value < MIN_OPERATOR_BOND) revert BondTooLow();
        if (commitHash == bytes32(0)) revert BadCommit();

        uint256 rolledIn = lockedRollover;
        lockedRollover = 0;

        id = ++campaignCount;
        uint64 enrollEnd = uint64(block.timestamp + enrollSeconds);
        uint64 lockEnd = uint64(uint256(enrollEnd) + uint256(cycleSeconds) * uint256(cycleCount));

        Campaign storage c = campaigns[id];
        c.operator = msg.sender;
        c.createdAt = uint64(block.timestamp);
        c.enrollEnd = enrollEnd;
        c.lockEnd = lockEnd;
        c.cycleSeconds = cycleSeconds;
        c.cycleCount = cycleCount;
        c.numberRange = numberRange;
        c.status = Status.Open;
        c.minEntrance = minEntrance;
        c.pot = rolledIn;
        c.bond = msg.value;
        c.commitHash = commitHash;

        emit CampaignOpened(id, msg.sender, cycleSeconds, cycleCount, enrollEnd, lockEnd, minEntrance, rolledIn);
    }

    /// @notice Join an OPEN hashbox. One unique number per address.
    function stake(uint256 id, uint32 number) external payable nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status != Status.Open) revert NotOpen();
        if (block.timestamp >= c.enrollEnd) revert TooLate();
        if (msg.value < c.minEntrance) revert BelowMinimum();
        if (number >= c.numberRange) revert NumberOOB();
        if (ticketOf[id][msg.sender] != 0 || (ticketOwner[id][0] == msg.sender && c.ticketCount > 0 && ticketOf[id][msg.sender] == 0 && _hasTicketZero(id, msg.sender))) {
            // handled below via explicit has-ticket check
        }
        if (_hasTicket(id, msg.sender)) revert AlreadyTicketed();
        if (ticketOwner[id][number] != address(0)) revert NumberTaken();

        ticketOwner[id][number] = msg.sender;
        ticketOf[id][msg.sender] = number + 1; // +1 so 0 is valid number
        stakeOf[id][msg.sender] = msg.value;
        enrolled[id].push(msg.sender);
        c.ticketCount += 1;
        c.pot += msg.value;

        emit Staked(id, msg.sender, number, msg.value);
    }

    /// @notice OPEN → LOCKED after enrollment. Closed hashbox: already in progress.
    function lockPhase(uint256 id) external {
        Campaign storage c = campaigns[id];
        if (c.status != Status.Open) revert NotOpen();
        if (block.timestamp < c.enrollEnd) revert TooEarly();
        c.status = Status.Locked;
        emit Locked(id);
    }

    /// @notice Snap close-blockhash after the full lock (cycleSeconds * cycleCount).
    function close(uint256 id) external {
        Campaign storage c = campaigns[id];
        if (c.status == Status.Open) {
            if (block.timestamp < c.enrollEnd) revert TooEarly();
            c.status = Status.Locked;
            emit Locked(id);
        }
        if (c.status != Status.Locked) revert NotLocked();
        if (block.timestamp < c.lockEnd) revert TooEarly();
        c.status = Status.Closed;
        c.closeBlockHash = blockhash(block.number - 1);
        if (c.closeBlockHash == bytes32(0)) {
            c.closeBlockHash = keccak256(abi.encodePacked(block.number, block.prevrandao, id));
        }
        emit Closed(id, c.closeBlockHash);
    }

    function reveal(uint256 id, bytes32 secret, bytes32 salt) external {
        Campaign storage c = campaigns[id];
        if (c.status != Status.Closed) revert NotClosed();
        if (keccak256(abi.encodePacked(secret, salt, c.operator)) != c.commitHash) revert BadReveal();

        bytes32 seed = keccak256(abi.encodePacked(secret, salt, id, c.closeBlockHash));
        uint32 winning = uint32(uint256(seed) % c.numberRange);
        address winner = ticketOwner[id][winning];

        c.winningNumber = winning;
        c.winner = winner;
        c.status = Status.Revealed;
        emit Revealed(id, winning, winner);
    }

    function claim(uint256 id) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status != Status.Revealed) revert NotRevealed();
        if (c.winner == address(0)) revert NoWinner();
        if (msg.sender != c.winner) revert NotWinner();
        if (block.timestamp > uint256(c.lockEnd) + CLAIM_WINDOW) revert TooLate();

        uint256 payout = c.pot;
        uint256 bond = c.bond;
        c.pot = 0;
        c.bond = 0;
        c.status = Status.Claimed;

        _pay(c.winner, payout);
        _pay(c.operator, bond);
        emit Claimed(id, c.winner, payout);
    }

    /// @notice Miss, withheld reveal, or unclaimed pot — assets stay locked for the next box.
    function roll(uint256 id) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status == Status.Claimed || c.status == Status.Rolled || c.status == Status.None) revert AlreadySettled();

        if (c.status == Status.Revealed) {
            if (c.winner != address(0) && block.timestamp <= uint256(c.lockEnd) + CLAIM_WINDOW) revert TooEarly();
        } else if (c.status == Status.Closed) {
            if (block.timestamp < uint256(c.lockEnd) + REVEAL_GRACE) revert TooEarly();
            lockedRollover += c.bond;
            emit BondSlashed(id, c.bond);
            c.bond = 0;
        } else {
            revert TooEarly();
        }

        uint256 amount = c.pot;
        c.pot = 0;
        c.status = Status.Rolled;
        lockedRollover += amount;
        if (c.bond > 0) {
            uint256 bond = c.bond;
            c.bond = 0;
            _pay(c.operator, bond);
        }
        emit Rolled(id, amount);
    }

    function enrolledCount(uint256 id) external view returns (uint256) {
        return enrolled[id].length;
    }

    function enrolledAt(uint256 id, uint256 index) external view returns (address user, uint32 number, uint256 staked) {
        user = enrolled[id][index];
        uint32 stored = ticketOf[id][user];
        number = stored == 0 ? 0 : stored - 1;
        staked = stakeOf[id][user];
    }

    function isOpen(uint256 id) public view returns (bool) {
        Campaign storage c = campaigns[id];
        return c.status == Status.Open && block.timestamp < c.enrollEnd;
    }

    function isClosedBox(uint256 id) public view returns (bool) {
        Campaign storage c = campaigns[id];
        if (c.status == Status.None) return false;
        if (c.status == Status.Open && block.timestamp < c.enrollEnd) return false;
        return c.status != Status.Claimed;
    }

    function previewLock(uint32 cycleSeconds, uint16 cycleCount, uint32 enrollSeconds)
        external
        view
        returns (uint64 enrollEnd, uint64 lockEnd, uint256 lockDuration)
    {
        enrollEnd = uint64(block.timestamp + enrollSeconds);
        lockDuration = uint256(cycleSeconds) * uint256(cycleCount);
        lockEnd = uint64(uint256(enrollEnd) + lockDuration);
    }

    function _validCycle(uint32 s) internal pure returns (bool) {
        return s == 60 || s == 3600 || s == 86_400;
    }

    function _hasTicket(uint256 id, address user) internal view returns (bool) {
        return ticketOf[id][user] != 0;
    }

    function _hasTicketZero(uint256 id, address user) internal view returns (bool) {
        return ticketOwner[id][0] == user;
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
