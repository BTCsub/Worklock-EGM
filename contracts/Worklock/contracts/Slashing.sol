pragma solidity ^0.6.5;

import "../aragon/interfaces/IERC900History.sol";
import "./Issuer.sol";
import "./lib/Bits.sol";
import "./lib/Snapshot.sol";
import "../zeppelin/math/SafeMath.sol";

interface PolicyManagerInterface {
    function register(address _node, uint16 _period) external;
    function updateFee(address _node, uint16 _period) external;
    function escrow() external view returns (address);
    function setDefaultFeeDelta(address _node, uint16 _period) external;
}


/**
* @notice Adjudicator interface
*/
interface AdjudicatorInterface {
    function escrow() external view returns (address);
}


/**
* @notice WorkLock interface
*/
interface WorkLockInterface {
    function escrow() external view returns (address);
}



abstract contract Slashing is Issuer, IERC900History{
    
    using AdditionalMath for uint256;
    using AdditionalMath for uint16;
    using Bits for uint256;
    using SafeMath for uint256;
    using Snapshot for uint128[];

    event Deposited(address indexed staker, uint256 value, uint16 periods);
    event Locked(address indexed staker, uint256 value, uint16 firstPeriod, uint16 periods);
    event Divided(
        address indexed staker,
        uint256 oldValue,
        uint16 lastPeriod,
        uint256 newValue,
        uint16 periods
    );
    event Prolonged(address indexed staker, uint256 value, uint16 lastPeriod, uint16 periods);
    event Withdrawn(address indexed staker, uint256 value);
    event CommitmentMade(address indexed staker, uint16 indexed period, uint256 value);
    event Minted(address indexed staker, uint16 indexed period, uint256 value);
    event Slashed(address indexed staker, uint256 penalty, address indexed investigator, uint256 reward);
    event ReStakeSet(address indexed staker, bool reStake);
    event ReStakeLocked(address indexed staker, uint16 lockUntilPeriod);
    event WorkerBonded(address indexed staker, address indexed worker, uint16 indexed startPeriod);
    event WorkMeasurementSet(address indexed staker, bool measureWork);
    event WindDownSet(address indexed staker, bool windDown);
    event SnapshotSet(address indexed staker, bool snapshotsEnabled);
    
    // used only for upgrading
    uint16 internal constant RESERVED_PERIOD = 0;
    uint16 internal constant MAX_CHECKED_VALUES = 5;
    // to prevent high gas consumption in loops for slashing
    uint16 public constant MAX_SUB_STAKES = 30;
    uint16 internal constant MAX_UINT16 = 65535;

    // indices for flags
    uint8 internal constant RE_STAKE_DISABLED_INDEX = 0;
    uint8 internal constant WIND_DOWN_INDEX = 1;
    uint8 internal constant MEASURE_WORK_INDEX = 2;
    uint8 internal constant SNAPSHOTS_DISABLED_INDEX = 3;


    mapping (address => StakerInfo) public stakerInfo;
    address[] public stakers;
    mapping (address => address) public stakerFromWorker;

    mapping (uint16 => uint256) public lockedPerPeriod;
    uint128[] public balanceHistory;
    
    
    struct SubStakeInfo {
        uint16 firstPeriod;
        uint16 lastPeriod;
        uint16 periods;
        uint128 lockedValue;
    }

    struct Downtime {
        uint16 startPeriod;
        uint16 endPeriod;
    }
    
    struct StakerInfo {
        uint256 value;
        /*
        * Stores periods that are committed but not yet rewarded.
        * In order to optimize storage, only two values are used instead of an array.
        * commitToNextPeriod() method invokes mint() method so there can only be two committed
        * periods that are not yet rewarded: the current and the next periods.
        */
        uint16 currentCommittedPeriod;
        uint16 nextCommittedPeriod;
        uint16 lastCommittedPeriod;
        uint16 lockReStakeUntilPeriod;
        uint256 completedWork;
        uint16 workerStartPeriod; // period when worker was bonded
        address worker;
        uint256 flags; // uint256 to acquire whole slot and minimize operations on it

        uint256 reservedSlot1;
        uint256 reservedSlot2;
        uint256 reservedSlot3;
        uint256 reservedSlot4;
        uint256 reservedSlot5;

        Downtime[] pastDowntime;
        SubStakeInfo[] subStakes;
        uint128[] history;

    }
    
    PolicyManagerInterface public policyManager;
    AdjudicatorInterface public adjudicator;
    WorkLockInterface public workLock;
    
    
    // uint8 internal constant RE_STAKE_DISABLED_INDEX = 0;
    // uint8 internal constant WIND_DOWN_INDEX = 1;
    // uint8 internal constant MEASURE_WORK_INDEX = 2;
    // uint8 internal constant SNAPSHOTS_DISABLED_INDEX = 3;
    
    // uint16 public constant MAX_SUB_STAKES = 30;
    
    // mapping (address => StakerInfo) public stakerInfo;
    
    //line 227
    /**
    * @notice Get the start period. Use in the calculation of the last period of the sub stake
    * @param _info Staker structure
    * @param _currentPeriod Current period
    */
    function getStartPeriod(StakerInfo storage _info, uint16 _currentPeriod)
        internal view returns (uint16)
    {
        // if the next period (after current) is committed
        if (_info.flags.bitSet(WIND_DOWN_INDEX) && _info.nextCommittedPeriod > _currentPeriod) {
            return _currentPeriod + 1;
        }
        return _currentPeriod;
    }
    
    // line 612
    /**
    * @notice Adds a new snapshot to both the staker and global balance histories,
    * assuming the staker's balance was already changed
    * @param _info Reference to affected staker's struct
    * @param _addition Variance in balance. It can be positive or negative.
    */
    function addSnapshot(StakerInfo storage _info, int256 _addition) internal {
        if(!_info.flags.bitSet(SNAPSHOTS_DISABLED_INDEX)){
            _info.history.addSnapshot(_info.value);
            uint256 lastGlobalBalance = uint256(balanceHistory.lastValue());
            balanceHistory.addSnapshot(lastGlobalBalance.addSigned(_addition));
        }
    }
    
    
    //line 229
    /**
    * @notice Get the last period of the sub stake
    * @param _subStake Sub stake structure
    * @param _startPeriod Pre-calculated start period
    */
    function getLastPeriodOfSubStake(SubStakeInfo storage _subStake, uint16 _startPeriod)
        internal view returns (uint16)
    {
        if (_subStake.lastPeriod != 0) {
            return _subStake.lastPeriod;
        }
        uint32 lastPeriod = uint32(_startPeriod) + _subStake.periods;
        if (lastPeriod > uint32(MAX_UINT16)) {
            return MAX_UINT16;
        }
        return uint16(lastPeriod);
    }
    
    /**
    * @notice Get the last period of the sub stake
    * @param _staker Staker
    * @param _index Stake index
    */
    function getLastPeriodOfSubStake(address _staker, uint256 _index)
        external view returns (uint16)
    {
        StakerInfo storage info = stakerInfo[_staker];
        SubStakeInfo storage subStake = info.subStakes[_index];
        uint16 startPeriod = getStartPeriod(info, getCurrentPeriod());
        return getLastPeriodOfSubStake(subStake, startPeriod);
    }
    
    
    
    // line 808
    /**
    * @notice Save sub stake. First tries to override inactive sub stake
    * @dev Inactive sub stake means that last period of sub stake has been surpassed and already rewarded
    * @param _info Staker structure
    * @param _firstPeriod First period of the sub stake
    * @param _lastPeriod Last period of the sub stake
    * @param _periods Duration of the sub stake in periods
    * @param _lockedValue Amount of locked tokens
    */
    function saveSubStake(
        StakerInfo storage _info,
        uint16 _firstPeriod,
        uint16 _lastPeriod,
        uint16 _periods,
        uint256 _lockedValue
    )
        internal
    {
        for (uint256 i = 0; i < _info.subStakes.length; i++) {
            SubStakeInfo storage subStake = _info.subStakes[i];
            if (subStake.lastPeriod != 0 &&
                (_info.currentCommittedPeriod == 0 ||
                subStake.lastPeriod < _info.currentCommittedPeriod) &&
                (_info.nextCommittedPeriod == 0 ||
                subStake.lastPeriod < _info.nextCommittedPeriod))
            {
                subStake.firstPeriod = _firstPeriod;
                subStake.lastPeriod = _lastPeriod;
                subStake.periods = _periods;
                subStake.lockedValue = uint128(_lockedValue);
                return;
            }
        }
        require(_info.subStakes.length < MAX_SUB_STAKES);
        _info.subStakes.push(SubStakeInfo(_firstPeriod, _lastPeriod, _periods, uint128(_lockedValue)));
    }
    
    
    
    // line 1062
    //-------------------------Slashing------------------------- 
    
    /**
    * @notice Slash the staker's stake and reward the investigator
    * @param _staker Staker's address
    * @param _penalty Penalty
    * @param _investigator Investigator
    * @param _reward Reward for the investigator
    */
    function slashStaker(
        address _staker,
        uint256 _penalty,
        address _investigator,
        uint256 _reward
    )
        public isInitialized
    {
        require(msg.sender == address(adjudicator));
        require(_penalty > 0);
        StakerInfo storage info = stakerInfo[_staker];
        if (info.value <= _penalty) {
            _penalty = info.value;
        }
        info.value -= _penalty;
        if (_reward > _penalty) {
            _reward = _penalty;
        }

        uint16 currentPeriod = getCurrentPeriod();
        uint16 nextPeriod = currentPeriod + 1;
        uint16 startPeriod = getStartPeriod(info, currentPeriod);

        (uint256 currentLock, uint256 nextLock, uint256 currentAndNextLock, uint256 shortestSubStakeIndex) =
            getLockedTokensAndShortestSubStake(info, currentPeriod, nextPeriod, startPeriod);

        // Decrease the stake if amount of locked tokens in the current period more than staker has
        uint256 lockedTokens = currentLock + currentAndNextLock;
        if (info.value < lockedTokens) {
           decreaseSubStakes(info, lockedTokens - info.value, currentPeriod, startPeriod, shortestSubStakeIndex);
        }
        // Decrease the stake if amount of locked tokens in the next period more than staker has
        if (nextLock > 0) {
            lockedTokens = nextLock + currentAndNextLock -
                (currentAndNextLock > info.value ? currentAndNextLock - info.value : 0);
            if (info.value < lockedTokens) {
               decreaseSubStakes(info, lockedTokens - info.value, nextPeriod, startPeriod, MAX_SUB_STAKES);
            }
        }

        emit Slashed(_staker, _penalty, _investigator, _reward);
        if (_penalty > _reward) {
            unMint(_penalty - _reward);
        }
        // TODO change to withdrawal pattern (#1499)
        if (_reward > 0) {
            token.safeTransfer(_investigator, _reward);
        }

        addSnapshot(info, - int256(_penalty));

    }

    /**
    * @notice Get the value of locked tokens for a staker in the current and the next period
    * and find the shortest sub stake
    * @param _info Staker structure
    * @param _currentPeriod Current period
    * @param _nextPeriod Next period
    * @param _startPeriod Pre-calculated start period
    * @return currentLock Amount of tokens that locked in the current period and unlocked in the next period
    * @return nextLock Amount of tokens that locked in the next period and not locked in the current period
    * @return currentAndNextLock Amount of tokens that locked in the current period and in the next period
    * @return shortestSubStakeIndex Index of the shortest sub stake
    */
    function getLockedTokensAndShortestSubStake(
        StakerInfo storage _info,
        uint16 _currentPeriod,
        uint16 _nextPeriod,
        uint16 _startPeriod
    )
        internal view returns (
            uint256 currentLock,
            uint256 nextLock,
            uint256 currentAndNextLock,
            uint256 shortestSubStakeIndex
        )
    {
        uint16 minDuration = MAX_UINT16;
        uint16 minLastPeriod = MAX_UINT16;
        shortestSubStakeIndex = MAX_SUB_STAKES;
        currentLock = 0;
        nextLock = 0;
        currentAndNextLock = 0;

        for (uint256 i = 0; i < _info.subStakes.length; i++) {
            SubStakeInfo storage subStake = _info.subStakes[i];
            uint16 lastPeriod = getLastPeriodOfSubStake(subStake, _startPeriod);
            if (lastPeriod < subStake.firstPeriod) {
                continue;
            }
            if (subStake.firstPeriod <= _currentPeriod &&
                lastPeriod >= _nextPeriod) {
                currentAndNextLock += subStake.lockedValue;
            } else if (subStake.firstPeriod <= _currentPeriod &&
                lastPeriod >= _currentPeriod) {
                currentLock += subStake.lockedValue;
            } else if (subStake.firstPeriod <= _nextPeriod &&
                lastPeriod >= _nextPeriod) {
                nextLock += subStake.lockedValue;
            }
            uint16 duration = lastPeriod - subStake.firstPeriod;
            if (subStake.firstPeriod <= _currentPeriod &&
                lastPeriod >= _currentPeriod &&
                (lastPeriod < minLastPeriod ||
                lastPeriod == minLastPeriod && duration < minDuration))
            {
                shortestSubStakeIndex = i;
                minDuration = duration;
                minLastPeriod = lastPeriod;
            }
        }
    }

    /**
    * @notice Decrease short sub stakes
    * @param _info Staker structure
    * @param _penalty Penalty rate
    * @param _decreasePeriod The period when the decrease begins
    * @param _startPeriod Pre-calculated start period
    * @param _shortestSubStakeIndex Index of the shortest period
    */
    function decreaseSubStakes(
        StakerInfo storage _info,
        uint256 _penalty,
        uint16 _decreasePeriod,
        uint16 _startPeriod,
        uint256 _shortestSubStakeIndex
    )
        internal
    {
        SubStakeInfo storage shortestSubStake = _info.subStakes[0];
        uint16 minSubStakeLastPeriod = MAX_UINT16;
        uint16 minSubStakeDuration = MAX_UINT16;
        while(_penalty > 0) {
            if (_shortestSubStakeIndex < MAX_SUB_STAKES) {
                shortestSubStake = _info.subStakes[_shortestSubStakeIndex];
                minSubStakeLastPeriod = getLastPeriodOfSubStake(shortestSubStake, _startPeriod);
                minSubStakeDuration = minSubStakeLastPeriod - shortestSubStake.firstPeriod;
                _shortestSubStakeIndex = MAX_SUB_STAKES;
            } else {
                (shortestSubStake, minSubStakeDuration, minSubStakeLastPeriod) =
                    getShortestSubStake(_info, _decreasePeriod, _startPeriod);
            }
            if (minSubStakeDuration == MAX_UINT16) {
                break;
            }
            uint256 appliedPenalty = _penalty;
            if (_penalty < shortestSubStake.lockedValue) {
                shortestSubStake.lockedValue -= uint128(_penalty);
                saveOldSubStake(_info, shortestSubStake.firstPeriod, _penalty, _decreasePeriod);
                _penalty = 0;
            } else {
                shortestSubStake.lastPeriod = _decreasePeriod - 1;
                _penalty -= shortestSubStake.lockedValue;
                appliedPenalty = shortestSubStake.lockedValue;
            }
            if (_info.currentCommittedPeriod >= _decreasePeriod &&
                _info.currentCommittedPeriod <= minSubStakeLastPeriod)
            {
                lockedPerPeriod[_info.currentCommittedPeriod] -= appliedPenalty;
            }
            if (_info.nextCommittedPeriod >= _decreasePeriod &&
                _info.nextCommittedPeriod <= minSubStakeLastPeriod)
            {
                lockedPerPeriod[_info.nextCommittedPeriod] -= appliedPenalty;
            }
        }
    }

    /**
    * @notice Get the shortest sub stake
    * @param _info Staker structure
    * @param _currentPeriod Current period
    * @param _startPeriod Pre-calculated start period
    * @return shortestSubStake The shortest sub stake
    * @return minSubStakeDuration Duration of the shortest sub stake
    * @return minSubStakeLastPeriod Last period of the shortest sub stake
    */
    function getShortestSubStake(
        StakerInfo storage _info,
        uint16 _currentPeriod,
        uint16 _startPeriod
    )
        internal view returns (
            SubStakeInfo storage shortestSubStake,
            uint16 minSubStakeDuration,
            uint16 minSubStakeLastPeriod
        )
    {
        shortestSubStake = shortestSubStake;
        minSubStakeDuration = MAX_UINT16;
        minSubStakeLastPeriod = MAX_UINT16;
        for (uint256 i = 0; i < _info.subStakes.length; i++) {
            SubStakeInfo storage subStake = _info.subStakes[i];
            uint16 lastPeriod = getLastPeriodOfSubStake(subStake, _startPeriod);
            if (lastPeriod < subStake.firstPeriod) {
                continue;
            }
            uint16 duration = lastPeriod - subStake.firstPeriod;
            if (subStake.firstPeriod <= _currentPeriod &&
                lastPeriod >= _currentPeriod &&
                (lastPeriod < minSubStakeLastPeriod ||
                lastPeriod == minSubStakeLastPeriod && duration < minSubStakeDuration))
            {
                shortestSubStake = subStake;
                minSubStakeDuration = duration;
                minSubStakeLastPeriod = lastPeriod;
            }
        }
    }

    /**
    * @notice Save the old sub stake values to prevent decreasing reward for the previous period
    * @dev Saving happens only if the previous period is committed
    * @param _info Staker structure
    * @param _firstPeriod First period of the old sub stake
    * @param _lockedValue Locked value of the old sub stake
    * @param _currentPeriod Current period, when the old sub stake is already unlocked
    */
    function saveOldSubStake(
        StakerInfo storage _info,
        uint16 _firstPeriod,
        uint256 _lockedValue,
        uint16 _currentPeriod
    )
        internal
    {
        // Check that the old sub stake should be saved
        bool oldCurrentCommittedPeriod = _info.currentCommittedPeriod != 0 &&
            _info.currentCommittedPeriod < _currentPeriod;
        bool oldnextCommittedPeriod = _info.nextCommittedPeriod != 0 &&
            _info.nextCommittedPeriod < _currentPeriod;
        bool crosscurrentCommittedPeriod = oldCurrentCommittedPeriod && _info.currentCommittedPeriod >= _firstPeriod;
        bool crossnextCommittedPeriod = oldnextCommittedPeriod && _info.nextCommittedPeriod >= _firstPeriod;
        if (!crosscurrentCommittedPeriod && !crossnextCommittedPeriod) {
            return;
        }
        // Try to find already existent proper old sub stake
        uint16 previousPeriod = _currentPeriod - 1;
        for (uint256 i = 0; i < _info.subStakes.length; i++) {
            SubStakeInfo storage subStake = _info.subStakes[i];
            if (subStake.lastPeriod == previousPeriod &&
                ((crosscurrentCommittedPeriod ==
                (oldCurrentCommittedPeriod && _info.currentCommittedPeriod >= subStake.firstPeriod)) &&
                (crossnextCommittedPeriod ==
                (oldnextCommittedPeriod && _info.nextCommittedPeriod >= subStake.firstPeriod))))
            {
                subStake.lockedValue += uint128(_lockedValue);
                return;
            }
        }
        saveSubStake(_info, _firstPeriod, previousPeriod, 0, _lockedValue);
    }

    //-------------Additional getters for stakers info-------------
    /**
    * @notice Return the length of the array of stakers
    */
    function getStakersLength() external view returns (uint256) {
        return stakers.length;
    }

    /**
    * @notice Return the length of the array of sub stakes
    */
    function getSubStakesLength(address _staker) external view returns (uint256) {
        return stakerInfo[_staker].subStakes.length;
    }

    /**
    * @notice Return the information about sub stake
    */
    function getSubStakeInfo(address _staker, uint256 _index)
    // TODO change to structure when ABIEncoderV2 is released (#1501)
//        public view returns (SubStakeInfo)
        // TODO "virtual" only for tests, probably will be removed after #1512
        external view virtual returns (uint16 firstPeriod, uint16 lastPeriod, uint16 periods, uint128 lockedValue)
    {
        SubStakeInfo storage info = stakerInfo[_staker].subStakes[_index];
        firstPeriod = info.firstPeriod;
        lastPeriod = info.lastPeriod;
        periods = info.periods;
        lockedValue = info.lockedValue;
    }

    /**
    * @notice Return the length of the array of past downtime
    */
    function getPastDowntimeLength(address _staker) external view returns (uint256) {
        return stakerInfo[_staker].pastDowntime.length;
    }

    /**
    * @notice Return the information about past downtime
    */
    function  getPastDowntime(address _staker, uint256 _index)
    // TODO change to structure when ABIEncoderV2 is released (#1501)
//        public view returns (Downtime)
        external view returns (uint16 startPeriod, uint16 endPeriod)
    {
        Downtime storage downtime = stakerInfo[_staker].pastDowntime[_index];
        startPeriod = downtime.startPeriod;
        endPeriod = downtime.endPeriod;
    }

    //------------------ ERC900 connectors ----------------------

    function totalStakedForAt(address _owner, uint256 _blockNumber) public view override returns (uint256){
        return stakerInfo[_owner].history.getValueAt(_blockNumber);
    }

    function totalStakedAt(uint256 _blockNumber) public view override returns (uint256){
        return balanceHistory.getValueAt(_blockNumber);
    }

    function supportsHistory() external pure override returns (bool){
        return true;
    }

    //------------------------Upgradeable------------------------
    /**
    * @dev Get StakerInfo structure by delegatecall
    */
    function delegateGetStakerInfo(address _target, bytes32 _staker)
        internal returns (StakerInfo memory result)
    {
        bytes32 memoryAddress = delegateGetData(_target, this.stakerInfo.selector, 1, _staker, 0);
        assembly {
            result := memoryAddress
        }
    }

    /**
    * @dev Get SubStakeInfo structure by delegatecall
    */
    function delegateGetSubStakeInfo(address _target, bytes32 _staker, uint256 _index)
        internal returns (SubStakeInfo memory result)
    {
        bytes32 memoryAddress = delegateGetData(
            _target, this.getSubStakeInfo.selector, 2, _staker, bytes32(_index));
        assembly {
            result := memoryAddress
        }
    }

    /**
    * @dev Get Downtime structure by delegatecall
    */
    function delegateGetPastDowntime(address _target, bytes32 _staker, uint256 _index)
        internal returns (Downtime memory result)
    {
        bytes32 memoryAddress = delegateGetData(
            _target, this.getPastDowntime.selector, 2, _staker, bytes32(_index));
        assembly {
            result := memoryAddress
        }
    }

    /// @dev the `onlyWhileUpgrading` modifier works through a call to the parent `verifyState`
    function verifyState(address _testTarget) public override virtual {
        super.verifyState(_testTarget);
        require(address(delegateGet(_testTarget, this.policyManager.selector)) == address(policyManager));
        require(address(delegateGet(_testTarget, this.adjudicator.selector)) == address(adjudicator));
        require(address(delegateGet(_testTarget, this.workLock.selector)) == address(workLock));
        require(delegateGet(_testTarget, this.lockedPerPeriod.selector,
            bytes32(bytes2(RESERVED_PERIOD))) == lockedPerPeriod[RESERVED_PERIOD]);
        require(address(delegateGet(_testTarget, this.stakerFromWorker.selector, bytes32(0))) ==
            stakerFromWorker[address(0)]);

        require(delegateGet(_testTarget, this.getStakersLength.selector) == stakers.length);
        if (stakers.length == 0) {
            return;
        }
        address stakerAddress = stakers[0];
        require(address(uint160(delegateGet(_testTarget, this.stakers.selector, 0))) == stakerAddress);
        StakerInfo storage info = stakerInfo[stakerAddress];
        bytes32 staker = bytes32(uint256(stakerAddress));
        StakerInfo memory infoToCheck = delegateGetStakerInfo(_testTarget, staker);
        require(infoToCheck.value == info.value &&
            infoToCheck.currentCommittedPeriod == info.currentCommittedPeriod &&
            infoToCheck.nextCommittedPeriod == info.nextCommittedPeriod &&
            infoToCheck.flags == info.flags &&
            infoToCheck.lockReStakeUntilPeriod == info.lockReStakeUntilPeriod &&
            infoToCheck.lastCommittedPeriod == info.lastCommittedPeriod &&
            infoToCheck.completedWork == info.completedWork &&
            infoToCheck.worker == info.worker &&
            infoToCheck.workerStartPeriod == info.workerStartPeriod);

        require(delegateGet(_testTarget, this.getPastDowntimeLength.selector, staker) ==
            info.pastDowntime.length);
        for (uint256 i = 0; i < info.pastDowntime.length && i < MAX_CHECKED_VALUES; i++) {
            Downtime storage downtime = info.pastDowntime[i];
            Downtime memory downtimeToCheck = delegateGetPastDowntime(_testTarget, staker, i);
            require(downtimeToCheck.startPeriod == downtime.startPeriod &&
                downtimeToCheck.endPeriod == downtime.endPeriod);
        }

        require(delegateGet(_testTarget, this.getSubStakesLength.selector, staker) == info.subStakes.length);
        for (uint256 i = 0; i < info.subStakes.length && i < MAX_CHECKED_VALUES; i++) {
            SubStakeInfo storage subStakeInfo = info.subStakes[i];
            SubStakeInfo memory subStakeInfoToCheck = delegateGetSubStakeInfo(_testTarget, staker, i);
            require(subStakeInfoToCheck.firstPeriod == subStakeInfo.firstPeriod &&
                subStakeInfoToCheck.lastPeriod == subStakeInfo.lastPeriod &&
                subStakeInfoToCheck.periods == subStakeInfo.periods &&
                subStakeInfoToCheck.lockedValue == subStakeInfo.lockedValue);
        }

        // it's not perfect because checks not only slot value but also decoding
        // at least without additional functions
        require(delegateGet(_testTarget, this.totalStakedForAt.selector, staker, bytes32(block.number)) ==
            totalStakedForAt(stakerAddress, block.number));
        require(delegateGet(_testTarget, this.totalStakedAt.selector, bytes32(block.number)) ==
            totalStakedAt(block.number));

        if (info.worker != address(0)) {
            require(address(delegateGet(_testTarget, this.stakerFromWorker.selector, bytes32(uint256(info.worker)))) ==
                stakerFromWorker[info.worker]);
        }
    }

    /// @dev the `onlyWhileUpgrading` modifier works through a call to the parent `finishUpgrade`
    function finishUpgrade(address _target) public override virtual {
        super.finishUpgrade(_target);
        // Create fake period
        lockedPerPeriod[RESERVED_PERIOD] = 111;

        // Create fake worker
        stakerFromWorker[address(0)] = address(this);
    }
    
}