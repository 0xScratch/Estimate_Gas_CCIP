// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/utils/structs/EnumerableMap.sol";

interface CometMainInterface {
    function supply(address asset, uint amount) external;
}

interface ISwapTestnetUSDC {
    function swap(address tokenIn, address tokenOut, uint256 amount) external;

    function getSupportedTokens()
        external
        view
        returns (address usdcToken, address compoundUsdcToken);
}

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */
contract CrossChainReceiver is CCIPReceiver, OwnerIsCreator {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using SafeERC20 for IERC20;

    // Example error code, could have many different error codes.
    enum ErrorCode {
        // RESOLVED is first so that the default value is resolved.
        RESOLVED,
        // Could have any number of error codes here.
        BASIC
    }

    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowed(address sender); // Used when the sender has not been allowlisted by the contract owner.
    error OnlySelf(); // Used when a function is called outside of the contract itself.
    error ErrorCase(); // Used when simulating a revert during message processing.
    error MessageNotFailed(bytes32 messageId);

    CometMainInterface internal immutable i_comet;
    ISwapTestnetUSDC internal immutable i_swapTestnetUsdc;

    // This is used to simulate a revert in the processMessage function.
    bool internal s_simRevert = false;

    // Contains failed messages and their state.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 chainSelecotor => bool isAllowlisted)
        public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders.
    mapping(address sender => bool isAllowlisted) public allowlistedSenders;

    // Mapping to keep track of the message contents of failed messages.
    mapping(bytes32 messageId => Client.Any2EVMMessage contents)
        public s_messageContents;

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);

    constructor(
        address ccipRouterAddress,
        address cometAddress,
        address swapTestnetUsdcAddress
    ) CCIPReceiver(ccipRouterAddress) {
        i_comet = CometMainInterface(cometAddress);
        i_swapTestnetUsdc = ISwapTestnetUSDC(swapTestnetUsdcAddress);
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowlisted and if the sender is allowlisted.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }

    // @dev Modifier to allow only the contract itself to execute a function.
    /// Throws an exception if called by any account other than the contract itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @dev Updates the allowlist status of a source chain
    /// @notice This function can only be called by the owner.
    /// @param _sourceChainSelector The selector of the source chain to be updated.
    /// @param _allowed The allowlist status to be set for the source chain.
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool _allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    /// @dev Updates the allowlist status of a sender for transactions.
    /// @notice This function can only be called by the owner.
    /// @param _sender The address of the sender to be updated.
    /// @param _allowed The allowlist status to be set for the sender.
    function allowlistSender(address _sender, bool _allowed) external onlyOwner {
        allowlistedSenders[_sender] = _allowed;
    }

    /// @notice The entrypoint for the CCIP router to call. This function should
    /// never revert, all errors should be handled internally in this contract.
    /// @param any2EvmMessage The message to process.
    /// @dev Extremely important to ensure only router calls this.
    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        override
        onlyRouter
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure the source chain and sender are allowlisted
    {
        /* solhint-disable no-empty-blocks */
        try this.processMessage(any2EvmMessage) {
            // Intentionally empty in this example; no action needed if processMessage succeeds
        } catch (bytes memory err) {
            // Could set different error codes based on the caught error. Each could be
            // handled differently.
            s_failedMessages.set(
                any2EvmMessage.messageId,
                uint256(ErrorCode.BASIC)
            );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            // Don't revert so CCIP doesn't revert. Emit event instead.
            // The message can be retried later without having to do manual execution of CCIP.
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    /// @notice Serves as the entry point for this contract to process incoming messages.
    /// @param any2EvmMessage Received CCIP message.
    /// @dev Transfers specified token amounts to the owner of this contract. This function
    /// must be external because of the  try/catch for error handling.
    /// It uses the `onlySelf`: can only be called from the contract.
    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        onlySelf
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure the source chain and sender are allowlisted
    {
        // Simulate a revert for testing purposes
        if (s_simRevert) revert ErrorCase();

        _ccipReceive(any2EvmMessage); // process the message - may revert as well
    }

    /// @notice Allows the owner to retry a failed message in order to unblock the associated tokens.
    /// @param messageId The unique identifier of the failed message.
    /// @param tokenReceiver The address to which the tokens will be sent.
    /// @dev This function is only callable by the contract owner. It changes the status of the message
    /// from 'failed' to 'resolved' to prevent reentry and multiple retries of the same message.
    function retryFailedMessage(
        bytes32 messageId,
        address tokenReceiver
    ) external onlyOwner {
        // Check if the message has failed; if not, revert the transaction.
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.BASIC))
            revert MessageNotFailed(messageId);

        // Set the error code to RESOLVED to disallow reentry and multiple retries of the same failed message.
        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        // Retrieve the content of the failed message.
        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        // This example expects one token to have been sent, but you can handle multiple tokens.
        // Transfer the associated tokens to the specified receiver as an escape hatch.
        IERC20(message.destTokenAmounts[0].token).safeTransfer(
            tokenReceiver,
            message.destTokenAmounts[0].amount
        );

        // Emit an event indicating that the message has been recovered.
        emit MessageRecovered(messageId);
    }

    /// @notice Allows the owner to toggle simulation of reversion for testing purposes.
    /// @param simRevert If `true`, simulates a revert condition; if `false`, disables the simulation.
    /// @dev This function is only callable by the contract owner.
    function setSimRevert(bool simRevert) external onlyOwner {
        s_simRevert = simRevert;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        address usdcToken = any2EvmMessage.destTokenAmounts[0].token;
        (, address compoundUsdcToken) = i_swapTestnetUsdc.getSupportedTokens();
        uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;

        IERC20(usdcToken).approve(address(i_swapTestnetUsdc), amount);

        // Swap actual testnet USDC for Compound V3's version of USDC test token.
        // This step is neccessary on testnets only!
        i_swapTestnetUsdc.swap(usdcToken, compoundUsdcToken, amount);

        IERC20(compoundUsdcToken).approve(address(i_comet), amount);

        i_comet.supply(compoundUsdcToken, amount);
    }

    /**
     * @notice Retrieves the IDs of failed messages from the `s_failedMessages` map.
     * @dev Iterates over the `s_failedMessages` map, collecting all keys.
     * @return ids An array of bytes32 containing the IDs of failed messages from the `s_failedMessages` map.
     */
    function getFailedMessagesIds()
        external
        view
        returns (bytes32[] memory ids)
    {
        uint256 length = s_failedMessages.length();
        bytes32[] memory allKeys = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            (bytes32 key, ) = s_failedMessages.at(i);
            allKeys[i] = key;
        }
        return allKeys;
    }
}