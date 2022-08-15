// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./Libs/SnapshopLib.sol";
import "../../core/component/DaoAuthorizable.sol";
import "./Interface/IAnyERC20Voting.sol";
import "../../utils/UncheckedMath.sol";
import "../../utils/TimeHelpers.sol";

contract AnyERC20Voting is IAnyERC20Voting, Initializable, DaoAuthorizable, TimeHelpers {
    /// @notice The ID of the permission required to call the `setConfiguration` function.
    bytes32 public constant SET_CONFIGURATION_PERMISSION_ID =
        keccak256("SET_CONFIGURATION_PERMISSION");

    /// @notice The base value being defined to correspond to 100% to calculate and compare percentages despite the lack of floating point arithmetic.
    uint64 public constant PCT_BASE = 10**18; // 0% = 0; 1% = 10^16; 100% = 10^18

    /// @notice A mapping between vote IDs and vote information.
    mapping(uint256 => Vote) internal votes;

    uint64 public supportRequiredPct;
    uint64 public participationRequiredPct;
    uint64 public minDuration;
    uint256 public votesLength;

    IERC20 private votingToken;

    /// @notice Thrown if the maximal possible support is exceeded.
    /// @param limit The maximal value.
    /// @param actual The actual value.
    error VoteSupportExceeded(uint64 limit, uint64 actual);

    /// @notice Thrown if the maximal possible participation is exceeded.
    /// @param limit The maximal value.
    /// @param actual The actual value.
    error VoteParticipationExceeded(uint64 limit, uint64 actual);

    /// @notice Thrown if the selected vote times are not allowed.
    /// @param current The maximal value.
    /// @param start The start date of the vote as a unix timestamp.
    /// @param end The end date of the vote as a unix timestamp.
    /// @param minDuration The minimal duration of the vote in seconds.
    error VoteTimesInvalid(uint64 current, uint64 start, uint64 end, uint64 minDuration);

    /// @notice Thrown if the selected vote duration is zero
    error VoteDurationZero();

    /// @notice Thrown if a voter is not allowed to cast a vote.
    /// @param voteId The ID of the vote.
    /// @param sender The address of the voter.
    error VoteCastingForbidden(uint256 voteId, address sender);

    /// @notice Thrown if the vote execution is forbidden
    error VoteExecutionForbidden(uint256 voteId);

    /// @notice Thrown if the voting power is zero
    error NoVotingPower();

    //////////////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// create proposal with snapshot /////////////////////////////////

    function createProposal(
        bytes calldata _proposalMetadata,
        IDAO.Action[] calldata _actions,
        bytes memory header,
        uint64 _startDate,
        uint64 _endDate,
        bytes[] memory blockProof
    ) external returns (uint256 voteId) {
        uint256 votingPower = votingToken.totalSupply(); // this is wrong, get if from the slot
        if (votingPower == 0) revert NoVotingPower();

        voteId = votesLength++;
        (uint256 blockNumber, bytes32 storageRoot) = _takeSnapshot(voteId, header, blockProof);

        (_startDate, _endDate) = _calculateStartEndDate(_startDate, _endDate);

        // Create the vote
        Vote storage vote_ = votes[voteId];
        vote_.startDate = _startDate;
        vote_.endDate = _endDate;
        vote_.supportRequiredPct = supportRequiredPct;
        vote_.participationRequiredPct = participationRequiredPct;
        vote_.votingPower = votingPower;
        vote_.snapshotBlock = blockNumber;
        vote_.storageRoot = storageRoot;

        unchecked {
            for (uint256 i = 0; i < _actions.length; i++) {
                vote_.actions.push(_actions[i]);
            }
        }

        emit VoteCreated(voteId, _msgSender(), _proposalMetadata);
    }

    function vote(
        uint256 _voteId,
        VoteOption _choice,
        bool _executesIfDecided,
        bytes[] memory balanceProof
    ) external {
        if (_choice != VoteOption.None && !_canVote(_voteId, _msgSender()))
            revert VoteCastingForbidden(_voteId, _msgSender());
        _vote(_voteId, _choice, _msgSender(), _executesIfDecided, balanceProof);
    }

    function _vote(
        uint256 _voteId,
        VoteOption _choice,
        address _voter,
        bool _executesIfDecided,
        bytes[] memory balanceProof
    ) internal {
        Vote storage vote_ = votes[_voteId];

        uint256 balancesRoot = 1;
        uint256 balancesKey = uint160(address(msg.sender));
        bytes32 slot = keccak256(abi.encodePacked(balancesKey, balancesRoot));
        uint256 balance = uint256(SnapshopLib.storageValue(vote_.storageRoot, slot, balanceProof));

        uint256 voterStake = balance; // votingToken.getPastVotes(_voter, vote_.snapshotBlock);
        VoteOption state = vote_.voters[_voter];

        // If voter had previously voted, decrease count
        if (state == VoteOption.Yes) {
            vote_.yes = vote_.yes - voterStake;
        } else if (state == VoteOption.No) {
            vote_.no = vote_.no - voterStake;
        } else if (state == VoteOption.Abstain) {
            vote_.abstain = vote_.abstain - voterStake;
        }

        // write the updated/new vote for the voter.
        if (_choice == VoteOption.Yes) {
            vote_.yes = vote_.yes + voterStake;
        } else if (_choice == VoteOption.No) {
            vote_.no = vote_.no + voterStake;
        } else if (_choice == VoteOption.Abstain) {
            vote_.abstain = vote_.abstain + voterStake;
        }

        vote_.voters[_voter] = _choice;

        emit VoteCast(_voteId, _voter, uint8(_choice), voterStake);

        if (_executesIfDecided && _canExecute(_voteId)) {
            _execute(_voteId);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// helper internal function ///////////////////////////////////

    function _takeSnapshot(
        uint256 _voteId,
        bytes memory header,
        bytes[] memory proof
    ) internal returns (uint256, bytes32) {
        (uint256 blockNumber, bytes32 stateRoot) = SnapshopLib.blockStateRoot(header);
        bytes32 storageRoot = SnapshopLib.accountStorageRoot(
            stateRoot,
            address(votingToken),
            proof
        );

        return (blockNumber, storageRoot);
    }

    function _calculateStartEndDate(uint64 _startDate, uint64 _endDate)
        internal
        returns (uint64, uint64)
    {
        // Calculate the start and end time of the vote
        uint64 currentTimestamp = getTimestamp64();

        if (_startDate == 0) _startDate = currentTimestamp;
        if (_endDate == 0) _endDate = _startDate + minDuration;

        if (_endDate - _startDate < minDuration || _startDate < currentTimestamp)
            revert VoteTimesInvalid({
                current: currentTimestamp,
                start: _startDate,
                end: _endDate,
                minDuration: minDuration
            });

        return (_startDate, _endDate);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////// re-use code from majority voting //////////////////////////////////////

    /// @notice Initializes the component.
    /// @dev This method is required to support [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822).
    /// @param _dao The IDAO interface of the associated DAO.
    /// @param _trustedForwarder The address of the trusted forwarder required for meta transactions.
    /// @param _participationRequiredPct The minimal required participation in percent.
    /// @param _supportRequiredPct The minimal required support in percent.
    /// @param _minDuration The minimal duration of a vote.
    /// @param _token any ERC20 token .
    function initialize(
        IDAO _dao,
        address _trustedForwarder,
        uint64 _participationRequiredPct,
        uint64 _supportRequiredPct,
        uint64 _minDuration,
        IERC20 _token
    ) public initializer {
        __DaoAuthorizable_init(_dao);
        _validateAndSetSettings(_participationRequiredPct, _supportRequiredPct, _minDuration);

        votingToken = _token;

        emit ConfigUpdated(_participationRequiredPct, _supportRequiredPct, _minDuration);
    }

    /// @notice getter function for the voting token.
    /// @dev public function also useful for registering interfaceId and for distinguishing from majority voting interface.
    /// @return ERC20VotesUpgradeable the token used for voting.
    function getVotingToken() public view returns (IERC20) {
        return votingToken;
    }

    function _canVote(uint256 _voteId, address _voter) internal view returns (bool) {
        Vote storage vote_ = votes[_voteId];
        return _isVoteOpen(vote_);
    }

    function setConfiguration(
        uint64 _participationRequiredPct,
        uint64 _supportRequiredPct,
        uint64 _minDuration
    ) external auth(SET_CONFIGURATION_PERMISSION_ID) {
        _validateAndSetSettings(_participationRequiredPct, _supportRequiredPct, _minDuration);

        emit ConfigUpdated(_participationRequiredPct, _supportRequiredPct, _minDuration);
    }

    function execute(uint256 _voteId) public {
        if (!_canExecute(_voteId)) revert VoteExecutionForbidden(_voteId);
        _execute(_voteId);
    }

    function getVoteOption(uint256 _voteId, address _voter) public view returns (VoteOption) {
        return votes[_voteId].voters[_voter];
    }

    function canVote(uint256 _voteId, address _voter) public view returns (bool) {
        return _canVote(_voteId, _voter);
    }

    function canExecute(uint256 _voteId) public view returns (bool) {
        return _canExecute(_voteId);
    }

    function getVote(uint256 _voteId)
        public
        view
        returns (
            bool open,
            bool executed,
            uint64 startDate,
            uint64 endDate,
            uint256 snapshotBlock,
            uint64 supportRequired,
            uint64 participationRequired,
            uint256 votingPower,
            uint256 yes,
            uint256 no,
            uint256 abstain,
            IDAO.Action[] memory actions
        )
    {
        Vote storage vote_ = votes[_voteId];

        open = _isVoteOpen(vote_);
        executed = vote_.executed;
        startDate = vote_.startDate;
        endDate = vote_.endDate;
        snapshotBlock = vote_.snapshotBlock;
        supportRequired = vote_.supportRequiredPct;
        participationRequired = vote_.participationRequiredPct;
        votingPower = vote_.votingPower;
        yes = vote_.yes;
        no = vote_.no;
        abstain = vote_.abstain;
        actions = vote_.actions;
    }

    function _execute(uint256 _voteId) internal virtual {
        bytes[] memory execResults = dao.execute(_voteId, votes[_voteId].actions);

        votes[_voteId].executed = true;

        emit VoteExecuted(_voteId, execResults);
    }

    function _canExecute(uint256 _voteId) internal view virtual returns (bool) {
        Vote storage vote_ = votes[_voteId];

        if (vote_.executed) {
            return false;
        }

        // Voting is already decided
        if (_isValuePct(vote_.yes, vote_.votingPower, vote_.supportRequiredPct)) {
            return true;
        }

        // Vote ended?
        if (_isVoteOpen(vote_)) {
            return false;
        }

        uint256 totalVotes = vote_.yes + vote_.no;

        // Have enough people's stakes participated ? then proceed.
        if (
            !_isValuePct(
                totalVotes + vote_.abstain,
                vote_.votingPower,
                vote_.participationRequiredPct
            )
        ) {
            return false;
        }

        // Has enough support?
        if (!_isValuePct(vote_.yes, totalVotes, vote_.supportRequiredPct)) {
            return false;
        }

        return true;
    }

    /// @notice Internal function to check if a vote is still open.
    /// @param vote_ the vote struct.
    /// @return True if the given vote is open, false otherwise.
    function _isVoteOpen(Vote storage vote_) internal view virtual returns (bool) {
        return
            getTimestamp64() < vote_.endDate &&
            getTimestamp64() >= vote_.startDate &&
            !vote_.executed;
    }

    /// @notice Calculates whether `_value` is more than a percentage `_pct` of `_total`.
    /// @param _value the current value.
    /// @param _total the total value.
    /// @param _pct the required support percentage.
    /// @return returns if the _value is _pct or more percentage of _total.
    function _isValuePct(
        uint256 _value,
        uint256 _total,
        uint256 _pct
    ) internal pure returns (bool) {
        if (_total == 0) {
            return false;
        }

        uint256 computedPct = (_value * PCT_BASE) / _total;
        return computedPct > _pct;
    }

    function _validateAndSetSettings(
        uint64 _participationRequiredPct,
        uint64 _supportRequiredPct,
        uint64 _minDuration
    ) internal virtual {
        if (_supportRequiredPct > PCT_BASE) {
            revert VoteSupportExceeded({limit: PCT_BASE, actual: _supportRequiredPct});
        }

        if (_participationRequiredPct > PCT_BASE) {
            revert VoteParticipationExceeded({limit: PCT_BASE, actual: _participationRequiredPct});
        }

        if (_minDuration == 0) {
            revert VoteDurationZero();
        }

        participationRequiredPct = _participationRequiredPct;
        supportRequiredPct = _supportRequiredPct;
        minDuration = _minDuration;
    }
}
