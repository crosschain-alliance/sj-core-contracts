pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CREATE3} from "@rari-capital/solmate/src/utils/CREATE3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISJRouter} from "./interfaces/ISJRouter.sol";
import {SJMessage} from "./interfaces/ISJMessage.sol";
import {IYaho} from "./interfaces/hashi/IYaho.sol";
import {Message} from "./interfaces/hashi/IMessage.sol";
import {IYaru} from "./interfaces/hashi/IYaru.sol";
import {IXERC20} from "./interfaces/xerc20/IXERC20.sol";
import {IXERC20Factory} from "./interfaces/xerc20/IXERC20Factory.sol";

contract SJRouter is ISJRouter, Ownable {
    using SafeERC20 for IERC20;

    address public immutable YAHO;
    address public immutable YARU;
    address public immutable XERC20_FACTORY;
    address public OPPOSITE_SJ_ROUTER;

    mapping(bytes32 => bool) private _processedMessages;
    mapping(bytes32 => address) private _advancedMessagesExecutors;

    constructor(address yaho, address yaru, address xERC20Factory) {
        YAHO = yaho;
        YARU = yaru;
        XERC20_FACTORY = xERC20Factory;
    }

    /// @inheritdoc ISJRouter
    function advanceMessage(SJMessage calldata message) external {
        bytes32 messageId = getMessageId(message);

        if (_advancedMessagesExecutors[messageId] != address(0)) revert MessageAlreadyAdvanced(message);
        if (_processedMessages[messageId]) revert MessageAlreadyProcessed(message);
        if (message.fastLaneFeeAmount == 0) revert InvalidFastLaneFeeAmount(message.fastLaneFeeAmount);

        address executor = msg.sender;
        _advancedMessagesExecutors[messageId] = executor;

        uint256 effectiveAmount = message.amount - message.fastLaneFeeAmount;
        address token = _maybeGetTokenAddress(message.tokenName, message.tokenSymbol, message.tokenCreator);
        IERC20(token).safeTransferFrom(executor, address(this), effectiveAmount);
        IERC20(token).safeTransfer(message.to, effectiveAmount);

        emit MessageAdvanced(message);
    }

    /// @inheritdoc ISJRouter
    function xTransfer(
        uint256 destinationChainId,
        address to,
        uint256 amount,
        uint256 fastLaneFeeAmount,
        address tokenCreator,
        string calldata tokenName,
        string calldata tokenSymbol
    ) external {
        address token = _maybeGetTokenAddress(tokenName, tokenSymbol, tokenCreator);
        IXERC20(token).burn(msg.sender, amount);

        bytes32 salt = keccak256(abi.encodePacked(blockhash(block.number - 1), gasleft()));
        SJMessage memory sjMessage = SJMessage(
            salt,
            block.chainid,
            destinationChainId,
            amount,
            fastLaneFeeAmount,
            address(this),
            to,
            tokenCreator,
            tokenName,
            tokenSymbol
        );

        bytes memory sjData = abi.encodeWithSignature(
            "onMessage((bytes32,uint256,uint256,uint256,uint256,address,address,address,string,string))",
            sjMessage
        );

        // TODO: get from governance or using another technique. At the moment we suppose that all routers have the same address
        address[] memory messageRelays = new address[](0);
        address[] memory adapters = new address[](0);

        Message[] memory messages = new Message[](1);
        messages[0] = Message(OPPOSITE_SJ_ROUTER, destinationChainId, sjData);

        IYaho(YAHO).dispatchMessagesToAdapters(messages, messageRelays, adapters);
        emit MessageDispatched(sjMessage);
    }

    /// @inheritdoc ISJRouter
    function getMessageId(SJMessage memory message) public pure returns (bytes32) {
        return keccak256(abi.encode(message));
    }

    /// @inheritdoc ISJRouter
    function onMessage(SJMessage calldata message) external {
        if (msg.sender != YARU) revert NotYaru(msg.sender, YARU);
        address router = IYaru(YARU).sender();
        if (router != OPPOSITE_SJ_ROUTER) revert NotOppositeSJRouter(router, OPPOSITE_SJ_ROUTER);

        // TODO: check used adapters IYaru(YARU).adapters()

        bytes32 messageId = getMessageId(message);
        if (_processedMessages[messageId]) revert MessageAlreadyProcessed(message);
        _processedMessages[messageId] = true;

        address token = _maybeGetTokenAddress(message.tokenName, message.tokenSymbol, message.tokenCreator);
        address advancedMessageExecutor = _advancedMessagesExecutors[messageId];
        address effectiveReceiver = advancedMessageExecutor != address(0) ? advancedMessageExecutor : message.to;
        IXERC20(token).mint(effectiveReceiver, message.amount);
        emit MessageProcessed(message);
    }

    /// @inheritdoc ISJRouter
    function setOppositeSjRouter(address sourceSjRouter_) external onlyOwner {
        OPPOSITE_SJ_ROUTER = sourceSjRouter_;
    }

    function _maybeGetTokenAddress(
        string calldata tokenName,
        string calldata tokenSymbol,
        address tokenCreator
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(tokenName, tokenSymbol, tokenCreator));
        address token = IXERC20Factory(XERC20_FACTORY).getDeployed(salt);
        if (token.code.length == 0) revert TokenNotCreated(token);
        return token;
    }
}
