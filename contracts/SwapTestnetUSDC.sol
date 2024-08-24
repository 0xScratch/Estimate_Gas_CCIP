// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@4.8.0/security/ReentrancyGuard.sol";

interface IFauceteer {
    function drip(address token) external;
}

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */
contract SwapTestnetUSDC is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private immutable i_usdcToken;
    address private immutable i_compoundUsdcToken;

    event Swap(address tokenIn, address tokenOut, uint256 amount, address trader);

    constructor(address usdcToken, address compoundUsdcToken, address fauceteer) {
        i_usdcToken = usdcToken;
        i_compoundUsdcToken = compoundUsdcToken;
        IFauceteer(fauceteer).drip(compoundUsdcToken);
    }

    function swap(address tokenIn, address tokenOut, uint256 amount) external nonReentrant {
        require(tokenIn == i_usdcToken || tokenIn == i_compoundUsdcToken);
        require(tokenOut == i_usdcToken || tokenOut == i_compoundUsdcToken);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenOut).transfer(msg.sender, amount);

        emit Swap(tokenIn, tokenOut, amount, msg.sender);
    }

    function getSupportedTokens() external view returns(address usdcToken, address compoundUsdcToken) {
        return(i_usdcToken, i_compoundUsdcToken);
    }
}