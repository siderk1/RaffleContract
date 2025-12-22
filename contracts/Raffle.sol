// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import "./VRFConsumerBaseV2PlusUpgradeable.sol";

contract Raffle is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    VRFConsumerBaseV2PlusUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    enum GameState {
        Open,
        RandomRequested,
        WinnerSelected,
        Settled
    }

    struct UserWinningRange {
        address user;
        uint256 min;
        uint256 max;
    }

    uint256 public constant MAX_PARTICIPANTS = 50;
    uint256 public constant MIN_DEPOSIT_USD = 10e18;

    uint256 public gameId;
    GameState public gameState;
    uint256 public gameStart;
    uint256 public gameDuration;

    mapping(address => address) public tokenToPriceFeed;

    mapping(uint256 => uint256) public poolUSD;
    mapping(uint256 => UserWinningRange[]) public winningRanges;
    mapping(uint256 => address) public winner;

    mapping(uint256 => address[]) public participants;
    mapping(uint256 => mapping(address => bool)) private hasParticipated;

    // token accounting
    mapping(uint256 => address[]) public gameTokens;
    mapping(uint256 => mapping(address => uint256)) public gameTokenAmounts;

    // fees (bps)
    uint256 public platformFee;
    uint256 public founderFee;
    address public platform;
    address public founder;

    // payout
    ISwapRouter public swapRouter;
    address public payoutToken;
    uint24 public poolFee;

    // VRF
    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    mapping(uint256 => uint256) public requestIdToGameId;
    mapping(uint256 => uint256) public randomResult;

    // pull balances
    mapping(uint256 => mapping(address => uint256)) public claimable;
    mapping(uint256 => bool) public settled;

    event Deposit(address indexed user, address token, uint256 usdValue);
    event WinnerSelected(uint256 indexed gameId, address winner);
    event Settled(uint256 indexed gameId, uint256 totalOut);
    event Claimed(uint256 indexed gameId, address indexed user, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _swapRouter,
        address _payoutToken,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        address _vrfCoordinator
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __VRFConsumerBaseV2PlusUpgradeable_init(_vrfCoordinator);

        swapRouter = ISwapRouter(_swapRouter);
        payoutToken = _payoutToken;

        subscriptionId = _subscriptionId;
        keyHash = _keyHash;

        callbackGasLimit = 300_000;
        requestConfirmations = 3;

        gameDuration = 24 hours;
        poolFee = 3000;

        gameId = 1;
        gameState = GameState.Open;
        gameStart = block.timestamp;
    }

    function setAllowedToken(address token, address feed) external onlyOwner {
        tokenToPriceFeed[token] = feed;
    }

    function setFees(
        uint256 _platformFee,
        uint256 _founderFee,
        address _platform,
        address _founder
    ) external onlyOwner {
        require(_platformFee + _founderFee <= 2_000, "Fee cap exceeded");
        platformFee = _platformFee;
        founderFee = _founderFee;
        platform = _platform;
        founder = _founder;
    }

    function startNewGame() external onlyOwner {
        require(gameState == GameState.Settled, "Game not settled");
        gameId++;
        gameState = GameState.Open;
        gameStart = block.timestamp;
    }

    function deposit(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        require(gameState == GameState.Open, "Game closed");
        require(tokenToPriceFeed[token] != address(0), "Token not allowed");
        require(participants[gameId].length < MAX_PARTICIPANTS, "Max reached");

        try
            IERC20Permit(token).permit(
                msg.sender,
                address(this),
                amount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        if (gameTokenAmounts[gameId][token] == 0) {
            gameTokens[gameId].push(token);
        }

        gameTokenAmounts[gameId][token] += amount;

        uint256 usd = _getTokenValueInUSD(token, amount);
        require(usd >= MIN_DEPOSIT_USD, "Deposit too small");

        uint256 current = poolUSD[gameId];
        winningRanges[gameId].push(
            UserWinningRange(msg.sender, current, current + usd)
        );
        poolUSD[gameId] += usd;

        if (!hasParticipated[gameId][msg.sender]) {
            participants[gameId].push(msg.sender);
            hasParticipated[gameId][msg.sender] = true;
        }

        emit Deposit(msg.sender, token, usd);
    }

    function requestRandomWinner() public {
        require(gameState == GameState.Open, "Wrong state");
        require(block.timestamp >= gameStart + gameDuration, "Too early");
        require(poolUSD[gameId] > 0, "Empty pool");

        gameState = GameState.RandomRequested;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        requestIdToGameId[requestId] = gameId;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata words
    ) internal override {
        require(gameState == GameState.RandomRequested, "Bad state");
        randomResult[requestIdToGameId[requestId]] = words[0];
    }

    function finalizeWinner() external onlyOwner {
        require(gameState == GameState.RandomRequested, "Wrong state");

        uint256 gid = gameId;
        uint256 rnd = randomResult[gid];
        require(rnd != 0, "Random not ready");

        uint256 point = rnd % poolUSD[gid];
        UserWinningRange[] memory ranges = winningRanges[gid];

        for (uint256 i; i < ranges.length; i++) {
            if (point >= ranges[i].min && point < ranges[i].max) {
                winner[gid] = ranges[i].user;
                gameState = GameState.WinnerSelected;
                emit WinnerSelected(gid, winner[gid]);
                return;
            }
        }
        revert("No winner");
    }

    function settle(uint256 gid) external nonReentrant {
        require(gameState == GameState.WinnerSelected, "Not ready");
        require(!settled[gid], "Already settled");

        uint256 totalOut;

        for (uint256 i; i < gameTokens[gid].length; i++) {
            address token = gameTokens[gid][i];
            uint256 amount = gameTokenAmounts[gid][token];

            IERC20(token).approve(address(swapRouter), amount);

            ISwapRouter.ExactInputSingleParams memory p = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: payoutToken,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount,
                    amountOutMinimum: (amount * 95) / 100,
                    sqrtPriceLimitX96: 0
                });

            totalOut += swapRouter.exactInputSingle(p);
        }

        uint256 platformAmt = (totalOut * platformFee) / 10_000;
        uint256 founderAmt = (totalOut * founderFee) / 10_000;
        uint256 winnerAmt = totalOut - platformAmt - founderAmt;

        if (platformAmt > 0) claimable[gid][platform] += platformAmt;
        if (founderAmt > 0) claimable[gid][founder] += founderAmt;
        claimable[gid][winner[gid]] += winnerAmt;

        settled[gid] = true;
        gameState = GameState.Settled;

        emit Settled(gid, totalOut);
    }

    function claim(uint256 gid) external nonReentrant {
        uint256 amount = claimable[gid][msg.sender];
        require(amount > 0, "Nothing to claim");
        claimable[gid][msg.sender] = 0;
        IERC20(payoutToken).safeTransfer(msg.sender, amount);
        emit Claimed(gid, msg.sender, amount);
    }

    function checkUpkeep(
        bytes calldata
    ) external view override returns (bool, bytes memory) {
        bool canTrigger = gameState == GameState.Open &&
            block.timestamp >= gameStart + gameDuration &&
            poolUSD[gameId] > 0;
        return (canTrigger, "");
    }

    function performUpkeep(bytes calldata) external override {
        requestRandomWinner();
    }

    function _getTokenValueInUSD(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(
            tokenToPriceFeed[token]
        );
        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
        require(price > 0 && block.timestamp - updatedAt < 1 hours, "Stale");

        uint256 norm = uint256(price) * (10 ** (18 - feed.decimals()));
        return (amount * norm) / 1e18;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
