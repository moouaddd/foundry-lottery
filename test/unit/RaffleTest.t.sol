// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfiig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    event EnterRafflePlayer(address indexed player);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 enterFee;
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
        (
            enterFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,

        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleIniciatizesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertWhenPlayerDontPayEth() public {
        vm.prank(PLAYER);

        vm.expectRevert(Raffle.Raffle_NotEnoughETH.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordedPlayer() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: enterFee}();
        address playerSelected = raffle.getPlayer(0);
        assert(playerSelected == PLAYER);
    }

    function testRaffleEmitPlayer() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnterRafflePlayer(PLAYER);
        raffle.enterRaffle{value: enterFee}();
    }

    function testRaffleCantEnterWhenIsCalculating()
        public
        enterRaffleTimePassed
    {
        raffle.performUpKeep("");

        vm.expectRevert(Raffle.Raffle_NotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: enterFee}();
    }

    /////////////////////////
    // checkUpkeep         //
    /////////////////////////

    function testcheckUpKeepReturnsFalseIfItHasNoBalance() public {
        //Arrange
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        //Act
        (bool upKeepNeeded, ) = raffle.checkUpKeep("");

        //Assert
        assert(!upKeepNeeded);
    }

    function testcheckUpKeepReturnsFalseIfRaffleIsNotOpen()
        public
        enterRaffleTimePassed
    {
        raffle.performUpKeep("");

        //Act
        (bool upKeepNeeded, ) = raffle.checkUpKeep("");

        //Assert
        assert(!upKeepNeeded);
    }

    function testcheckUpKeepReturnsFalseIfEnoughTimeHantPassed() public {
        //Arrange
        vm.warp(block.timestamp + interval - 1);
        vm.roll(block.number + 1);

        //Act
        (bool upKeepNeeded, ) = raffle.checkUpKeep("");

        //Assert
        assert(!upKeepNeeded);
    }

    function testcheckUpKeepReturnsTrueWhenParametersAreGood()
        public
        enterRaffleTimePassed
    {
        //Act
        (bool upKeepNeeded, ) = raffle.checkUpKeep("");

        //Assert
        assert(upKeepNeeded);
    }

    /////////////////////////
    // performUpkeep       //
    /////////////////////////

    function testperformUpKeepRevertIfcheckUpKeepIsTrue()
        public
        enterRaffleTimePassed
    {
        //Act / Assert
        raffle.performUpKeep("");
    }

    function testperformUpKeepRevertIfcheckUpKeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        uint256 raffleState = 0;

        //Act /assert
        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle_UpKeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                raffleState
            )
        );
        raffle.performUpKeep("");
    }

    modifier enterRaffleTimePassed() {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: enterFee}();
        _;
    }

    function testperformUpKeepUpdatesRaffleStateAndEmitsRewuestId()
        public
        enterRaffleTimePassed
    {
        vm.recordLogs();
        raffle.performUpKeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // Assert
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        // requestId = raffle.getLastRequestId();
        assert(uint256(requestId) > 0);
        assert(uint(raffleState) == 1); // 0 = open, 1 = calculating
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpKeep(
        uint256 randomRequestId
    ) public enterRaffleTimePassed skipFork {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            0,
            address(raffle)
        );
    }

    function testFulFillRandomWordsPicksAWinnerResetsSendsMoney()
        public
        enterRaffleTimePassed
        skipFork
    {
        uint256 additionalsEntrance = 3;
        uint256 startingIndex = 1;

        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalsEntrance;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: enterFee}();
        }

        uint256 prize = enterFee * (additionalsEntrance + 1);

        vm.recordLogs();
        raffle.performUpKeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        //Acting like a chainlink node getting a random number and picking a winner
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        //assert
        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRaffleWinner() != address(0));
        assert(raffle.getPlayerLength() == 0);
        assert(previousTimeStamp < raffle.getLastTimeStamp());
        assert(
            raffle.getRaffleWinner().balance ==
                STARTING_USER_BALANCE + prize - enterFee
        );
    }
}
