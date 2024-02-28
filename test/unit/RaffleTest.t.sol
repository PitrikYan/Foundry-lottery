//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract RaffleTest is StdCheats, Test {
    event EnteredRaffle(address indexed player, uint256 number, string name, uint256 indexed numberIndexed);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();

        (entranceFee, interval, vrfCoordinator, gasLane, subscriptionId, callbackGasLimit, link,) =
            helperConfig.activeNetworkConfig();

        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleInitializeInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    modifier playerEnteredAndTimePassed() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    // pro pripad ze testujeme na real chainu a ne na anvilu
    modifier skipFork() {
        if (block.chainid != 31337) {
            // jestlize to neni anvil
            return;
        }
        _;
    }

    ////////////////////////////
    /// enterRaffle testing  ///
    ////////////////////////////

    function testRaffleRevertsWhenYouDontPayEnough() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NotEnoughEthSent.selector);
        raffle.enterRaffle();
    }

    function testPlayerRecordingWhenEnterRaffle() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    // event EnteredRaffle(address indexed player, uint256 number, string name, uint256 indexed numberIndexed);
    function testEventEmittingWhenEnterRaffle() public {
        vm.prank(PLAYER);
        // first 3 bools is for any indexed values in the event no matter of the order and the last bool is for non indexed values (every of them)
        // last address parameter is expected emitter
        vm.expectEmit(true, true, false, true, address(raffle));
        emit EnteredRaffle(PLAYER, 88, "standa", 99);

        vm.recordLogs();
        raffle.enterRaffle{value: entranceFee}();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        /// @dev Checking Test Event (emitted event is having index 2 thats why we use entries[2])
        (bytes32 number, string memory someString) = abi.decode(entries[0].data, (bytes32, string));
        bytes32 indexedNumber = entries[0].topics[2];
        address someAddress = address(uint160(uint256(entries[0].topics[1])));

        console.log("String: ", someString);
        console.log("Number: ", uint256(number));
        console.log("Number indexed: ", uint256(indexedNumber));
        console.log("Address: ", someAddress);
        //console.log("Other String: ", someOtherString);
        assertEq(PLAYER, someAddress);
    }

    function testCantEnterWhenCalculating() public playerEnteredAndTimePassed {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    ////////////////////
    /// checkupkeep ////
    ///////////////////

    function testFalseIfItsNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        assert(upkeepNeeded == false);
        //assert(!upkeepNeeded);
    }

    function testFalseIfItsNotOpen() public playerEnteredAndTimePassed {
        raffle.performUpkeep("");

        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        assert(upkeepNeeded == false);
    }

    function testFalseIfNotEnoughTimePassed() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + 25);
        vm.roll(block.number + 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(upkeepNeeded == false);
    }

    function testTrueIfItsOk() public playerEnteredAndTimePassed {
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(upkeepNeeded == true);
    }

    ////////////////////////////
    /// performUpKeep  ///
    ////////////////////////////

    function testCanRunIfCheckUpIsTrue() public playerEnteredAndTimePassed {
        raffle.performUpkeep("");
    }

    function testCantRunIfCheckUpIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState raffleState = raffle.getRaffleState();

        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currentBalance, numPlayers, raffleState)
        );

        raffle.performUpkeep("");
    }

    function testStateUpdatingAndEmittingRequestId() public playerEnteredAndTimePassed {
        vm.recordLogs(); // umozni logovat eventy
        raffle.performUpkeep(""); // requestId emitted (index 1 protoze uz ve fci chainlinku je taky event ktery bude na indexu 0)
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // all logs are recorder as bytes32
        bytes32 requestId = entries[1].topics[1]; // topics[0] by mel byt cely event..
        // entries[1] protoze jeden event uz je emitovan v "i_vrfCoordinator.requestRandomWords" (takze to je number 2)

        Raffle.RaffleState raffleState = raffle.getRaffleState();

        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1);
    }

    ////////////////////////////
    /// fulfillRandomWords  ///
    ////////////////////////////

    function testCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId)
        public
        playerEnteredAndTimePassed
        skipFork
    {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function testCanPickWinnerAndSendMoney() public playerEnteredAndTimePassed skipFork {
        // need another players
        for (uint256 i = 1; i < 10; i++) {
            hoax(address(uint160(i)), STARTING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }
        // get request id
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimestamp = raffle.getLastTimeStamp();
        uint256 prize = entranceFee * 10;

        // pretend to be chainlink node on local chain (we cant call it on testnet)
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getRecentWinner().balance == prize + (STARTING_USER_BALANCE - entranceFee));
        assert(address(raffle).balance == 0);
        assert(previousTimestamp < raffle.getLastTimeStamp());
        assert(raffle.getLengthOfPlayers() == 0);
    }
}
