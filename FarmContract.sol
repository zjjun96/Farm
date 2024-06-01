// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Farm is VRFConsumerBaseV2Plus {
    AggregatorV3Interface internal dataFeed;

    // Chainlink VRF配置
    uint256 s_subscriptionId;
    address vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 s_keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 callbackGasLimit = 40000;
    uint16 requestConfirmations = 3;
    uint32 numWords = 1;

    uint256 initial_price;  // 初始种子价格         Initial seed price
    uint256 initial_price_time; // 更新种子的时间

    // 田地信息
    struct Plot {
        uint256 status;      // 当前地的状态 0 表示空地 1 表示已种 
        uint256 lastWatered; // 浇水时间
        uint256 harvestTime; // 收获的时间
    }

    // 玩家信息
    struct Player {
        uint256 experience;    // 玩家经验值
        uint256 unlockedPlots; // 解锁地的数量
        uint256 outcomeAmount; // 收获的数量
        uint256 balance;       // 余额
        uint256 seeds;         // 种子数
        Plot[10] plots;        // 玩家最多十块地
    }

    mapping(address => Player) public players; 

    struct RequestInfo {        // 保存请求获取随机数的地址和对应的田地
        address player;
        uint256 plotId;
    }
 
    mapping(uint256 => RequestInfo) internal requests;    // 存储请求的所有requestId

    event RandomNumberRequested(uint256 requestId, address indexed player, uint256 plotId);
    event RandomNumberGenerated(uint256 requestId, uint256 randomNumber);
    event PriceUpdated(uint256 newPrice, uint256 updateTime);

    constructor(uint256 subscriptionId) VRFConsumerBaseV2Plus(vrfCoordinator) {
        s_subscriptionId = subscriptionId;
        updatePriceData();
    }

    function _initializePlayer(address _player) internal {  // 初始信息
        players[_player].unlockedPlots = 6;
        players[_player].balance = 100;
    }

    // Run function
    function run() public {
        require(players[msg.sender].unlockedPlots == 0, "User is unlocked");
        _initializePlayer(msg.sender);
    }
    
    function _req_plotId(uint256 _plotId) internal view {   // 统一验证
        require(_plotId > 0, "Plot ID must be greater than zero"); 
        require(_plotId <= players[msg.sender].unlockedPlots, "Plot not unlocked"); 
    }
    
    function read_plot(uint256 _plotId) public view returns (Plot memory) {     // 返回当前地址每块地的信息 
        _req_plotId(_plotId);
        return players[msg.sender].plots[_plotId];
    }
    
    function _upgrade() internal {      // 用户经验值增加与升级田地数量
        Player storage player = players[msg.sender];
        player.experience += 2;
        if (player.experience % 100 == 0 && player.unlockedPlots <= 10) {
                player.unlockedPlots += 1;
        }
    }
    
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) override internal virtual {  // Chainlink VRF回调函数
        uint256 randomResult = randomWords[0];

        if (randomResult % 2 == 0) {    // 更新玩家田地的奖励
            _upgrade();
        }

        emit RandomNumberGenerated(requestId, randomResult);
    }

    function sow(uint256 _plotId) public {       // 播种 + 随机奖励升级
        _req_plotId(_plotId);
        require(players[msg.sender].seeds >= 1, "Insufficient seed balance");
        Plot storage plot = players[msg.sender].plots[_plotId]; 
        require(plot.status == 0, "Plot is not empty"); 
        plot.status = 1; 
        plot.harvestTime = block.timestamp + 1 days; 
        _upgrade();
        players[msg.sender].seeds -= 1;
        // 请求随机数
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        requests[requestId] = RequestInfo({
            player: msg.sender,
            plotId: _plotId
        });

        emit RandomNumberRequested(requestId, msg.sender, _plotId);
    }
    
    function harvest(uint256 _plotId) public {      // 收获
        _req_plotId(_plotId);
        Plot storage plot = players[msg.sender].plots[_plotId];
        require(plot.harvestTime <= block.timestamp, "Plot is not ready to harvest");
        plot.status = 0;
        plot.harvestTime = 0;
        plot.lastWatered = 0;
        players[msg.sender].outcomeAmount += 1;
        _upgrade();
    }

    function water(uint256 _plotId) public {        // 浇水
        _req_plotId(_plotId);
        Plot storage _plot = players[msg.sender].plots[_plotId];
        require(_plot.status == 1, "Plot is not in the correct state for watering"); 
        require(_plot.harvestTime > block.timestamp, "No need to plant, you can harvest"); 
        require(_plot.lastWatered + 4 hours <= block.timestamp, "Water no more than Four times a day"); 
        _plot.lastWatered = block.timestamp;
        _plot.harvestTime -= 1 hours;
        _upgrade();
    }

    function buy_seed (uint256 _seedAmount) public {        // 买种子
        Player storage player = players[msg.sender];
        require(_seedAmount * 10 <= player.balance, "Insufficient balance");  
        player.seeds += _seedAmount;
        player.balance -= _seedAmount * 10;
    }
    
    function sell_outcome(uint256 _outcomeAmount) public {      // 卖出成果
        if (block.timestamp >= initial_price_time + 1 days) {
            updatePriceData();
        }
        Player storage player = players[msg.sender];
        require(_outcomeAmount <= player.outcomeAmount && _outcomeAmount > 0, "Insufficient quantity sold");
        player.outcomeAmount -= _outcomeAmount;
        player.balance += _outcomeAmount * (10 + initial_price % 3);    // 根据当前eth价格得出农作物的价格上下浮动，不低于成本价
    }
    
    function updatePriceData() internal {       // 获取链上价格更新每天卖出用
        dataFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        (,int answer,,,) = dataFeed.latestRoundData();
        initial_price = uint256(answer);
        initial_price_time = block.timestamp;
        emit PriceUpdated(initial_price, initial_price_time);
    }
}   