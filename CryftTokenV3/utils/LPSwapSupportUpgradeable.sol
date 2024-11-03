// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract LPSwapSupportUpgradeable is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;

    event UpdateRouter(address indexed newAddress, address indexed oldAddress);
    event UpdatePair(address indexed newAddress, address indexed oldAddress);
    event UpdateLPReceiver(
        address indexed newAddress,
        address indexed oldAddress
    );
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event BuybackAndLiquifyEnabledUpdated(bool enabled);

    event BuybackAndLiquify(uint256 tokensBought, uint256 currencyIntoLiquidty);

    mapping(address => bool) private approvedAddresses;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    bool internal inSwap;
    bool public swapsEnabled;
    bool public buybackAndLiquifyEnabled;

    uint256 public minSpendAmount;
    uint256 public maxSpendAmount;

    uint256 public minTokenSpendAmount;
    uint256 public maxTokenSpendAmount;

    IUniswapV2Router02 public pancakeRouter;
    address public pancakePair;
    address public liquidityReceiver;
    address public deadAddress;

    uint256 public buybackAndLiquifyBalance;
    uint256 public gasRewardsBalance;

    // Workaround for buyback liquify transaction failures when using proxies.
    // Requires an address that is effectively dead to use as a custodian.
    // Should not be modifiable or an account owned by any user.
    address public buybackEscrowAddress;

    mapping(address => bool) public isLPPoolAddress;

    function __LPSwapSupport_init(
        address lpReceiver
    ) internal onlyInitializing {
        __Ownable_init();
        __LPSwapSupport_init_unchained(lpReceiver);
    }

    function __LPSwapSupport_init_unchained(
        address lpReceiver
    ) internal onlyInitializing {
        deadAddress = address(0x000000000000000000000000000000000000dEaD);
        buybackEscrowAddress = address(
            0x000000000000000000000000000000000000bEEF
        );

        liquidityReceiver = lpReceiver;
        buybackAndLiquifyEnabled = true;
        minSpendAmount = 2 ether;
        maxSpendAmount = 100 ether;
    }

    function _approve(
        address holder,
        address spender,
        uint256 tokenAmount
    ) internal virtual;

    function _balanceOf(address holder) internal view virtual returns (uint256);

    function updateRouter(address newAddress) public onlyOwner {
        require(
            newAddress != address(pancakeRouter),
            "The router is already set to this address"
        );
        emit UpdateRouter(newAddress, address(pancakeRouter));
        pancakeRouter = IUniswapV2Router02(newAddress);
    }

    function updateLiquidityReceiver(
        address receiverAddress
    ) external onlyOwner {
        require(
            receiverAddress != liquidityReceiver,
            "LP is already sent to that address"
        );
        emit UpdateLPReceiver(receiverAddress, liquidityReceiver);
        liquidityReceiver = receiverAddress;
    }

    function updateRouterAndPair(address newAddress) public virtual onlyOwner {
        if (newAddress != address(pancakeRouter)) {
            updateRouter(newAddress);
        }
        address _pancakeswapV2Pair = IUniswapV2Factory(pancakeRouter.factory())
            .createPair(address(this), pancakeRouter.WETH());
        if (_pancakeswapV2Pair != pancakePair) {
            updateLPPair(_pancakeswapV2Pair);
        }
    }

    function updateLPPair(address newAddress) public virtual onlyOwner {
        require(
            newAddress != pancakePair,
            "The LP Pair is already set to this address"
        );
        emit UpdatePair(newAddress, pancakePair);
        updateLPPoolList(newAddress, true);
        pancakePair = newAddress;
    }

    function updateLPPoolList(
        address newAddress,
        bool _isPoolAddress
    ) public virtual onlyOwner {
        isLPPoolAddress[newAddress] = _isPoolAddress;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapsEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setBuybackAndLiquifyEnabled(bool _enabled) public onlyOwner {
        buybackAndLiquifyEnabled = _enabled;
        emit BuybackAndLiquifyEnabledUpdated(_enabled);
    }

    // Purpose of token swap
    enum SwapPurpose {
        Buyback, // For Buybacks
        Liquify, // For Liquidity
        External // Neither Buyback nor Liquidity, ETH will be sent externally
    }

    // Updated swapTokensForCurrency function
    function swapTokensForCurrency(
        uint256 tokenAmount,
        SwapPurpose purpose
    ) internal returns (uint256) {
        return
            swapTokensForCurrencyAdv(
                address(this),
                tokenAmount,
                address(this),
                purpose
            );
    }

    // Updated swapTokensForCurrencyUnchecked function
    function swapTokensForCurrencyUnchecked(
        uint256 tokenAmount,
        SwapPurpose purpose
    ) private returns (uint256) {
        return
            _swapTokensForCurrencyAdv(
                address(this),
                tokenAmount,
                address(this),
                purpose
            );
    }

    // Updated swapTokensForCurrencyAdv function
    function swapTokensForCurrencyAdv(
        address tokenAddress,
        uint256 tokenAmount,
        address destination,
        SwapPurpose purpose
    ) internal returns (uint256) {
        if (tokenAmount < minTokenSpendAmount) {
            return 0;
        }
        if (maxTokenSpendAmount != 0 && tokenAmount > maxTokenSpendAmount) {
            tokenAmount = maxTokenSpendAmount;
        }
        return
            _swapTokensForCurrencyAdv(
                tokenAddress,
                tokenAmount,
                destination,
                purpose
            );
    }

    // Updated _swapTokensForCurrencyAdv function
    function _swapTokensForCurrencyAdv(
        address tokenAddress,
        uint256 tokenAmount,
        address destination,
        SwapPurpose purpose
    ) private returns (uint256) {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = tokenAddress;
        path[1] = pancakeRouter.WETH();
        uint256 tokenCurrentBalance;
        if (tokenAddress != address(this)) {
            bool approved = IBEP20(tokenAddress).approve(
                address(pancakeRouter),
                tokenAmount
            );
            if (!approved) {
                return 0;
            }
            tokenCurrentBalance = IBEP20(tokenAddress).balanceOf(address(this));
        } else {
            _approve(address(this), address(pancakeRouter), tokenAmount);
            tokenCurrentBalance = _balanceOf(address(this));
        }
        if (tokenCurrentBalance < tokenAmount) {
            return 0;
        }

        uint256 initialBalance = address(this).balance;

        // make the swap
        pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            destination,
            block.timestamp
        );

        uint256 newBalance = address(this).balance;
        uint256 ethReceived = newBalance.sub(initialBalance);

        // Check the purpose of token swap
        if (purpose == SwapPurpose.Buyback) {
            buybackAndLiquifyBalance = buybackAndLiquifyBalance.add(
                ethReceived
            );
        } else if (purpose == SwapPurpose.Liquify) {
            gasRewardsBalance = gasRewardsBalance.add(ethReceived);
        }
        // If purpose is External, do nothing

        return tokenAmount;
    }

    function addLiquidity(uint256 tokenAmount, uint256 cAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(pancakeRouter), tokenAmount);

        // add the liquidity
        pancakeRouter.addLiquidityETH{value: cAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityReceiver,
            block.timestamp
        );
    }

    function swapCurrencyForTokens(uint256 amount) internal {
        swapCurrencyForTokensAdv(address(this), amount, address(this));
    }

    function swapCurrencyForTokensAdv(
        address tokenAddress,
        uint256 amount,
        address destination
    ) internal {
        if (amount > maxSpendAmount) {
            amount = maxSpendAmount;
        }
        if (amount < minSpendAmount) {
            return;
        }

        _swapCurrencyForTokensAdv(tokenAddress, amount, destination);
    }

    function swapCurrencyForTokensUnchecked(
        address tokenAddress,
        uint256 amount,
        address destination
    ) internal {
        _swapCurrencyForTokensAdv(tokenAddress, amount, destination);
    }

    function _swapCurrencyForTokensAdv(
        address tokenAddress,
        uint256 amount,
        address destination
    ) private {
        address[] memory path = new address[](2);
        path[0] = pancakeRouter.WETH();
        path[1] = tokenAddress;
        if (amount > address(this).balance) {
            amount = address(this).balance;
        }

        // make the swap
        pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: amount
        }(0, path, destination, block.timestamp);
    }

    function buybackAndLiquify(
        uint256 amount
    ) internal returns (uint256 remainder) {
        // Check if the contract has enough ETH to buyback and liquify
        require(
            buybackAndLiquifyBalance >= amount,
            "Insufficient funds for buyback and liquify"
        );

        uint256 half = amount.div(2);
        uint256 initialTokenBalance = _balanceOf(address(this));

        // Buyback tokens
        swapCurrencyForTokensUnchecked(
            address(this),
            half,
            buybackEscrowAddress
        );

        // Subtract the spent amount from buybackAndLiquifyBalance
        buybackAndLiquifyBalance = buybackAndLiquifyBalance.sub(half);

        // Add liquidity to pair
        uint256 _buybackTokensPending = _balanceOf(buybackEscrowAddress);
        _approve(buybackEscrowAddress, address(this), _buybackTokensPending);
        IBEP20(address(this)).transferFrom(
            buybackEscrowAddress,
            address(this),
            _buybackTokensPending
        );
        addLiquidity(_buybackTokensPending, amount.sub(half));

        // Subtract the spent amount from buybackAndLiquifyBalance
        buybackAndLiquifyBalance = buybackAndLiquifyBalance.sub(
            amount.sub(half)
        );

        emit BuybackAndLiquify(_buybackTokensPending, half);
        uint256 finalTokenBalance = _balanceOf(address(this));

        remainder = finalTokenBalance > initialTokenBalance
            ? finalTokenBalance.sub(initialTokenBalance)
            : 0;
    }

    function forceBuybackAndLiquify() external virtual onlyOwner {
        require(
            buybackAndLiquifyBalance > 0,
            "Contract has no funds to use for buyback"
        );
        buybackAndLiquify(buybackAndLiquifyBalance);
    }

    function updateTokenSwapRange(
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyOwner {
        require(
            minAmount < maxAmount || maxAmount == 0,
            "Minimum must be less than maximum unless max is 0 (Unlimited)"
        );
        require(minAmount != 0, "Minimum cannot be set to 0");
        minTokenSpendAmount = minAmount;
        maxTokenSpendAmount = maxAmount;
    }

    function updateCurrencySwapRange(
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyOwner {
        require(
            minAmount <= maxAmount || maxAmount == 0,
            "Minimum must be less than maximum unless max is 0 (Unlimited)"
        );
        require(minAmount != 0, "Minimum cannot be set to 0");
        minSpendAmount = minAmount;
        maxSpendAmount = maxAmount;
    }

    function depositBuyBack(uint256 amount) external {
        require(
            approvedAddresses[msg.sender],
            "Not an approved address for deposit"
        );
        buybackAndLiquifyBalance = buybackAndLiquifyBalance.add(amount);
    }

    function depositGasReward(uint256 amount) external {
        require(
            approvedAddresses[msg.sender],
            "Not an approved address for deposit"
        );
        gasRewardsBalance = gasRewardsBalance.add(amount);
    }

    function setApprovedAddress(
        address addr,
        bool isApproved
    ) external onlyOwner {
        approvedAddresses[addr] = isApproved;
    }

    // Enum for Withdraw Purpose
    enum WithdrawPurpose {
        FromContract, // Withdraw from the contract's balance
        FromGasRewards, // Withdraw from the gas rewards balance
        FromBuybackAndLiquify // Withdraw from the buyback and liquify balance
    }

    // Function to Withdraw ETH
    function withdrawETH(
        uint256 amount,
        WithdrawPurpose purpose
    ) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient Balance");

        if (purpose == WithdrawPurpose.FromContract) {
            // Transfer ETH from the contract's balance
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Transfer failed.");
        } else if (purpose == WithdrawPurpose.FromGasRewards) {
            // Check the gas rewards balance
            require(
                amount <= gasRewardsBalance,
                "Insufficient gas rewards balance"
            );
            // Subtract the amount from the gas rewards balance
            gasRewardsBalance = gasRewardsBalance.sub(amount);
            // Transfer ETH from the contract's balance
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Transfer failed.");
        } else if (purpose == WithdrawPurpose.FromBuybackAndLiquify) {
            // Check the buyback and liquify balance
            require(
                amount <= buybackAndLiquifyBalance,
                "Insufficient buyback and liquify balance"
            );
            // Subtract the amount from the buyback and liquify balance
            buybackAndLiquifyBalance = buybackAndLiquifyBalance.sub(amount);
            // Transfer ETH from the contract's balance
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Transfer failed.");
        }
    }
}