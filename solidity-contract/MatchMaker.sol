//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error MatchMaker__HostCannotPlay();
error MatchMaker__NotPaidGamer();
error MatchMaker__NoCurrentRolledToken();

contract MatchMaker is VRFConsumerBaseV2, ReentrancyGuard, Ownable {
    //https://stackoverflow.com/questions/47393042/tournament-pairing-algorhitm

    using Counters for Counters.Counter;

    Counters.Counter public tournamentCounter;
    Counters.Counter public matchCounter;
    Counters.Counter public playerCounter;

    struct TournamentStruct {
        uint256 tournamentId;
        TournamentState tournamentState;
        uint32 currentGamerCount;
        uint32 maxGamerCount;
        address hostAddress;
        address winnerAddress;
        address feeTokenAddress;
        uint256 feeAmount;
        uint256 hostFeePercentage;
    }

    struct MatchStruct {
        MatchState matchState;
        uint256 matchId;
        uint256 tournamentId;
        address gamerA;
        address gamerB;
        address winnerAddress;
        uint256 hostFeePercentage;
        bytes32 winType;
    }

    struct VrfRequest {
        uint256 requestId;
        uint256 num_words;
    }

    enum MatchState {
        Started,
        Finished
    }

    enum TournamentState {
        GatheringPlayers,
        Started,
        Finished
    }

    address public rootOwner;
    uint64 private subId;
    bool public shouldUseVRF = true;
    VRFCoordinatorV2Interface public vrfCoordinatorV2;

    // MatchId (Many) -> Tournament (fewer) : one tournament has many matchId but every match only one tournament id
    mapping(uint256 => TournamentStruct) public matchToTournamentMap;
    mapping(uint256 => MatchStruct) public matchToMatchInfoMap;
    mapping(uint256 => TournamentStruct) public tournamentToTournamentInfoMap;
    mapping(uint256 => VrfRequest) private tournamentToRequest;
    mapping(uint256 => uint256) private requestToTournamentId;
    mapping(uint256 =>  mapping(uint256 => address)) public playerIdToPlayerAddress;
    mapping(uint256 => mapping(address => uint256)) public playerAddressToPlayerId;
    mapping(uint256 => mapping(uint256 => bool)) public tournamentToPlayerIdStatus;
    mapping(uint256 => mapping(uint256 => bool)) public tournamentToPlayerMatchStatus;
    mapping(uint256 => uint256[]) public tournamentToPlayers; // initial order by player arrival
    mapping(uint256 => uint256[]) public tournamentToPlayerMatches; // random sequence

    uint256[] public allTournaments;
    uint256[] public allMatches;
    uint256[] public lastRandomWords;

    bytes32 public gasLane;
    uint16 public MIN_CONFIRMATIONS;
    uint32 public GAS_LIMIT;

    //-------------------------------------------------------------------------
    // EVENTS
    //-------------------------------------------------------------------------
    event TournamentCreated(
        uint256 indexed tournamentId,
        address indexed tournamentHost,
        uint256 timestamp
    );

    event TournamentMatched(
        uint256 indexed tournamentId
    );

    //-------------------------------------------------------------------------
    // CONSTRUCTOR
    //-------------------------------------------------------------------------

    constructor(
        address _vrfCoordinatorV2,
        uint64 _subId,
        bytes32 _gaslane,
        uint16 _minConfirmations,
        uint32 gas_limit
    ) VRFConsumerBaseV2(_vrfCoordinatorV2) {
        rootOwner = owner();
        subId = _subId;
        gasLane = _gaslane;
        vrfCoordinatorV2 = VRFCoordinatorV2Interface(_vrfCoordinatorV2);
        MIN_CONFIRMATIONS = _minConfirmations;
        GAS_LIMIT = gas_limit;
        // addAirdropBundle(_mainAirdropToken, _airdropAmount);
    }

    // receive() external payable {
    //     emit Receive(msg.sender, msg.value);
    // }

    //-------------------------------------------------------------------------
    // EXTERNAL FUNCTIONS
    //-------------------------------------------------------------------------

    function createTournament(
        uint32 _maxGamerCount,
        address _feeToken,
        uint256 _feeAmount
    ) external nonReentrant {
        //get 500 random words from vrf
        require(_maxGamerCount > 0 && _feeAmount > 0 && _feeToken != address(0), "INVALID_TOURNAMENT_PARAMS");
        tournamentCounter.increment();
        uint256 tournamentId = tournamentCounter.current();
        tournamentToTournamentInfoMap[tournamentId] = TournamentStruct(
            tournamentId,
            TournamentState.GatheringPlayers,
            0,
            _maxGamerCount,
            msg.sender,
            address(0),
            _feeToken,
            _feeAmount,
            20
        );
        emit TournamentCreated(tournamentId, msg.sender, block.timestamp);
    }

    function createDemoTournament(string[] memory playerIDs) external nonReentrant {
        
        tournamentCounter.increment();
        uint256 tournamentId = tournamentCounter.current();
        tournamentToTournamentInfoMap[tournamentId] = TournamentStruct(
            tournamentId,
            TournamentState.GatheringPlayers,
            0,
            5,
            msg.sender,
            address(0),
            0x8eA3b0C9422291fe6D3854FB4F641af4972d926B,
            0,
            20
        );
        emit TournamentCreated(tournamentId, msg.sender, block.timestamp);   
        //startDemoTournament(tournamentId);
    }

    function startDemoTournament(uint256 _tournamentId) public {
        
        // match making
        requestRandomnessOracle(_tournamentId, tournamentToTournamentInfoMap[_tournamentId].currentGamerCount * 5);
    }

    function startTournament(uint256 _tournamentId) external payable nonReentrant {
        // check if host
        require(tournamentToTournamentInfoMap[_tournamentId].hostAddress == msg.sender, "ONLY_HOST");
        // check if players joined
        require(tournamentToTournamentInfoMap[_tournamentId].currentGamerCount >= 2, "PLAYERS_LESS_THAN_MIN");
        tournamentToTournamentInfoMap[_tournamentId].tournamentState = TournamentState.Started;
        
        // match making
        requestRandomnessOracle(_tournamentId, tournamentToTournamentInfoMap[_tournamentId].currentGamerCount * 5);
    }

    function joinTournament(uint256 _tournamentId) external payable nonReentrant {
        // check if tournament exists
        require(tournamentToTournamentInfoMap[_tournamentId].tournamentId != 0, "TOURNAMENT_NOT_EXIST");
        TournamentStruct storage currentTournament = tournamentToTournamentInfoMap[_tournamentId];
        // check if GatheringPlayers
        require(currentTournament.tournamentState == TournamentState.GatheringPlayers, "TOURNAMENT_CANNOT_JOINED");
        // host address cannot join
        require(currentTournament.hostAddress != msg.sender, "HOST_CANNOT_JOIN");
        // max participants check
        require(currentTournament.currentGamerCount < currentTournament.maxGamerCount, "MAX_PARTICIPANTS");
        // player is joining the game 1st time
        if (playerAddressToPlayerId[_tournamentId][msg.sender] == 0) {
            // check fee
            require(
                IERC20(currentTournament.feeTokenAddress).transferFrom(
                    msg.sender,
                    address(this),
                    currentTournament.feeAmount
                ) == true,
                "FEE_TOKEN_NOT_APPROVED"
            );
            playerCounter.increment();
            uint256 playerId = playerCounter.current();
            playerAddressToPlayerId[_tournamentId][msg.sender] = playerId;
            playerIdToPlayerAddress[_tournamentId][playerId] = msg.sender;
            tournamentToPlayers[_tournamentId].push(playerId);
            tournamentToPlayerIdStatus[_tournamentId][playerId] = true;
            currentTournament.currentGamerCount = currentTournament.currentGamerCount + 1;
        } else {
            uint256 _playerId = playerAddressToPlayerId[_tournamentId][msg.sender];
            // check if player is already in this tournament
            require(tournamentToPlayerIdStatus[_tournamentId][_playerId] == false, "PLAYER_CANNOT_REJOIN");
            // check fee
            require(
                IERC20(currentTournament.feeTokenAddress).transferFrom(
                    msg.sender,
                    address(this),
                    currentTournament.feeAmount
                ) == true,
                "FEE_TOKEN_NOT_APPROVED"
            );
            tournamentToPlayers[_tournamentId].push(_playerId);
            tournamentToPlayerIdStatus[_tournamentId][_playerId] = true;
            currentTournament.currentGamerCount = currentTournament.currentGamerCount + 1;
        }
    }

    function decideTournamentFinalWinner(uint256 _tournamentId, address _winnerAddress) external nonReentrant {
        // check if host    
        require(tournamentToTournamentInfoMap[_tournamentId].hostAddress == msg.sender, "ONLY_HOST");
        // check tournament started
        require(
            tournamentToTournamentInfoMap[_tournamentId].tournamentState == TournamentState.Started,
            "TOURNAMENT_CANNOT_END"
        );
        // only final winner is decided on smart contractOther Matches
        tournamentToTournamentInfoMap[_tournamentId].winnerAddress = _winnerAddress;
        tournamentToTournamentInfoMap[_tournamentId].tournamentState = TournamentState.Finished;
        //TODO: payout final winner and others
    }

    //-------------------------------------------------------------------------
    // INTERNAL FUNCTIONS
    //-------------------------------------------------------------------------

    function randomMatchMaking(
        uint256 rand1,
        uint256 rand2,
        uint256 rand3,
        uint256 price
    ) internal virtual returns (uint256, bytes32) {
        //use 500 random words % numberOfPeople
    }

    function requestRandomnessOracle(uint256 _tournamentId, uint32 num_Words) internal {
        if (shouldUseVRF) {
            uint256 requestId = vrfCoordinatorV2.requestRandomWords(
                gasLane,
                subId,
                MIN_CONFIRMATIONS,
                GAS_LIMIT,
                num_Words
            );
            tournamentToRequest[_tournamentId] = VrfRequest(requestId, num_Words);
            requestToTournamentId[requestId] = _tournamentId;
        }
    }

    /**
     * @dev Callback function used by VRF Coordinator
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 _tournamentId = requestToTournamentId[requestId];
        uint256 _totalPlayersInTournament = tournamentToPlayers[_tournamentId].length;
        for (uint256 i = 0; i < _totalPlayersInTournament; i++) {
            uint256 rand = uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp, randomWords[i])));
            unchecked {
                rand = (rand % _totalPlayersInTournament) + 1;
            }
        //    lastRandomWords.push(rand);
            if (rand <= _totalPlayersInTournament && tournamentToPlayerMatchStatus[_tournamentId][rand] == false) {
                tournamentToPlayerMatches[_tournamentId].push(rand);
                tournamentToPlayerMatchStatus[_tournamentId][rand] = true;
            } else {
                rand = rand + 1;
        //    lastRandomWords.push(rand);
                while (rand < _totalPlayersInTournament) {
                    if (
                        rand < _totalPlayersInTournament && tournamentToPlayerMatchStatus[_tournamentId][rand] == false
                    ) {
                        tournamentToPlayerMatches[_tournamentId].push(rand);
                        tournamentToPlayerMatchStatus[_tournamentId][rand] = true;
                        break;
                    }
                    rand = rand + 1;
                }
            }
        }
        emit TournamentMatched(_tournamentId);
    }

    function getTournamentMatches(uint256 _tournamentId) external view returns (uint256[] memory) {
       return tournamentToPlayerMatches[_tournamentId];
    }


    function toggleShouldUseVRF(bool _shouldUseVRF) external onlyOwner {
        shouldUseVRF = _shouldUseVRF;
    }
}
