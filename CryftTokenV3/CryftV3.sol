/*CRYFT_/\/\/\/\/\__/\/\/\/\/\____/\/\____/\/\__/\/\/\/\/\/\__/\/\/\/\/\/\__
___ _/\/\__________/\/\____/\/\__/\/\____/\/\__/\/\______________/\/\_______
__ _/\/\__________/\/\/\/\/\______/\/\/\/\____/\/\/\/\/\________/\/\________
___/\/\__________/\/\__/\/\________/\/\______/\/\______________/\/\_AUDITED_
____/\/\/\/\/\__/\/\____/\/\______/\/\______/\/\______________/\/\__InterFi_
_____Deployed by: CryftCreator______________Version 3.1_7/27/23___________*/

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

import "./utils/LPSwapSupportUpgradeable.sol";
import "./utils/AntiLPSniperUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract CryftV3 is
    IERC20MetadataUpgradeable,
    LPSwapSupportUpgradeable,
    AntiLPSniperUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeMathUpgradeable for uint256;

    event Burn(address indexed burnAddress, uint256 tokensBurnt);
    event GasRewardDistributed(address recipient, uint256 amount);

    struct TokenTracker {
        uint256 liquidity;
        uint256 vault;
        uint256 gasstation;
        uint256 buyback;
    }

    struct Fees {
        uint256 reflection;
        uint256 liquidity;
        uint256 gasstation;
        uint256 vault;
        uint256 burn;
        uint256 buyback;
        uint256 divisor;
    }

    Fees public buyFees;
    Fees public sellFees;
    Fees public transferFees;

    TokenTracker public tokenTracker;

    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) public _isExcludedFromFee;
    mapping(address => bool) public _isExcludedFromReward;
    mapping(address => bool) public _isExcludedFromTxLimit;

    uint256 private _rCurrentExcluded;
    uint256 private _tCurrentExcluded;

    uint256 private MAX;
    uint256 private _tTotal;
    uint256 private _rTotal;
    uint256 private _tFeeTotal;

    string public override name;
    string public override symbol;
    uint256 private _decimals;
    uint256 public _maxTxAmount;

    address public gasstationWallet;
    address public vaultWallet;

    address public gasStation;

    uint256 public totalGasDistributed;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _routerAddress,
        address _tokenOwner,
        address _gasstation,
        address _vault
    ) public virtual initializer {
        __Cryft_init(_routerAddress, _tokenOwner, _gasstation, _vault);
        transferOwnership(_tokenOwner);
    }

    function __Cryft_init(
        address _routerAddress,
        address _tokenOwner,
        address _gasstation,
        address _vault
    ) internal onlyInitializing {
        __LPSwapSupport_init(_tokenOwner);
        __Cryft_init_(_routerAddress, _tokenOwner, _gasstation, _vault);
    }

    function __Cryft_init_(
        address _routerAddress,
        address _tokenOwner,
        address _gasstation,
        address _vault
    ) internal onlyInitializing {
        __GasRewards_init();
        __Cryft_init_unchained(
            _routerAddress,
            _tokenOwner,
            _gasstation,
            _vault
        );
    }

    function __GasRewards_init() internal onlyInitializing {
        __ReentrancyGuard_init();
        gasStation = address(0x0000000000000000000000000000000000000000);
    }

    function __Cryft_init_unchained(
        address _routerAddress,
        address _tokenOwner,
        address _gasstation,
        address _vault
    ) internal onlyInitializing {
        MAX = ~uint256(0);
        name = "Cryft";
        symbol = "CRYFT";
        _decimals = 18;

        updateRouterAndPair(_routerAddress);

        antiSniperEnabled = true;

        _tTotal = 2800 * 10 ** 6 * 10 ** _decimals;
        _rTotal = (MAX - (MAX % _tTotal));

        _maxTxAmount = 3 * 10 ** 6 * 10 ** _decimals; // 3 mil

        gasstationWallet = _gasstation;
        vaultWallet = _vault;

        minTokenSpendAmount = 500 * 10 ** 3 * 10 ** _decimals; // 500k

        _rOwned[_tokenOwner] = _rTotal;
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[_tokenOwner] = true;
        _isExcludedFromFee[_msgSender()] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[gasstationWallet] = true;
        _isExcludedFromFee[vaultWallet] = true;
        _isExcludedFromFee[buybackEscrowAddress] = true;
        _isExcludedFromTxLimit[buybackEscrowAddress] = true;

        buyFees = Fees({
            reflection: 5,
            liquidity: 5,
            gasstation: 5,
            vault: 3,
            burn: 2,
            buyback: 10,
            divisor: 1000
        });

        sellFees = Fees({
            reflection: 5,
            liquidity: 5,
            gasstation: 5,
            vault: 3,
            burn: 2,
            buyback: 10,
            divisor: 1000
        });

        transferFees = Fees({
            reflection: 0,
            liquidity: 0,
            gasstation: 0,
            vault: 0,
            burn: 0,
            buyback: 0,
            divisor: 0
        });

        emit Transfer(address(this), _tokenOwner, _tTotal);
        excludeFromReward(address(this), true);
        excludeFromReward(buybackEscrowAddress, true);
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function decimals() external view override returns (uint8) {
        return uint8(_decimals);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balanceOf(account);
    }

    function _balanceOf(
        address account
    ) internal view override returns (uint256) {
        if (_isExcludedFromReward[account]) {
            return _tOwned[account];
        }
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(
        address holder,
        address spender
    ) public view override returns (uint256) {
        return _allowances[holder][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                "BEP20: transfer amount exceeds allowance"
            )
        );
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(
                subtractedValue,
                "BEP20: decreased allowance below zero"
            )
        );
        return true;
    }

    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    function getOwner() external view returns (address) {
        return owner();
    }

    function tokenFromReflection(
        uint256 rAmount
    ) public view returns (uint256) {
        require(
            rAmount <= _rTotal,
            "Amount must be less than total reflections"
        );
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    receive() external payable {}

    function _reflectFee(uint256 tFee, uint256 rFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;

        uint256 rCurrentExcluded = _rCurrentExcluded;
        uint256 tCurrentExcluded = _tCurrentExcluded;

        if (rCurrentExcluded > rSupply || tCurrentExcluded > tSupply)
            return (rSupply, tSupply);

        if (rSupply.sub(rCurrentExcluded) < rSupply.div(tSupply)) {
            return (_rTotal, _tTotal);
        }
        return (rSupply.sub(rCurrentExcluded), tSupply.sub(tCurrentExcluded));
    }

    function excludeFromFee(address account, bool exclude) public onlyOwner {
        _isExcludedFromFee[account] = exclude;
    }

    function excludeFromMaxTxLimit(
        address account,
        bool exclude
    ) public onlyOwner {
        _isExcludedFromTxLimit[account] = exclude;
    }

    function excludeFromReward(
        address account,
        bool shouldExclude
    ) public onlyOwner {
        require(
            _isExcludedFromReward[account] != shouldExclude,
            "Account is already set to this value"
        );
        if (shouldExclude) {
            _excludeFromReward(account);
        } else {
            _includeInReward(account);
        }
    }

    function _excludeFromReward(address account) private {
        uint256 rOwned = _rOwned[account];

        if (rOwned > 0) {
            uint256 tOwned = tokenFromReflection(rOwned);
            _tOwned[account] = tOwned;

            _tCurrentExcluded = _tCurrentExcluded.add(tOwned);
            _rCurrentExcluded = _rCurrentExcluded.add(rOwned);
        }
        _isExcludedFromReward[account] = true;
    }

    function _includeInReward(address account) private {
        uint256 rOwned = _rOwned[account];
        uint256 tOwned = _tOwned[account];

        if (tOwned > 0) {
            _tCurrentExcluded = _tCurrentExcluded.sub(tOwned);
            _rCurrentExcluded = _rCurrentExcluded.sub(rOwned);

            _rOwned[account] = tOwned.mul(_getRate());
            _tOwned[account] = 0;
        }
        _isExcludedFromReward[account] = false;
    }

    function _takeLiquidity(uint256 tLiquidity, uint256 rLiquidity) internal {
        if (tLiquidity > 0) {
            _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
            tokenTracker.liquidity = tokenTracker.liquidity.add(tLiquidity);
            if (_isExcludedFromReward[address(this)]) {
                _receiverIsExcluded(address(this), tLiquidity, rLiquidity);
            }
        }
    }

    function _takebuyback(uint256 tbuyback, uint256 rbuyback) internal {
        if (tbuyback > 0) {
            _rOwned[address(this)] = _rOwned[address(this)].add(rbuyback);
            tokenTracker.buyback = tokenTracker.buyback.add(tbuyback);
            if (_isExcludedFromReward[address(this)]) {
                _receiverIsExcluded(address(this), tbuyback, rbuyback);
            }
        }
    }

    function freeStuckTokens(address tokenAddress) external onlyOwner {
        require(
            tokenAddress != address(this),
            "Cannot withdraw this token, only external tokens"
        );
        IBEP20(tokenAddress).transfer(
            _msgSender(),
            IBEP20(tokenAddress).balanceOf(address(this))
        );
    }

    function _takeWalletFees(
        uint256 tgasstation,
        uint256 rgasstation,
        uint256 tvault,
        uint256 rvault
    ) private {
        if (tgasstation > 0) {
            tokenTracker.gasstation = tokenTracker.gasstation.add(tgasstation);
        }
        if (tvault > 0) {
            tokenTracker.vault = tokenTracker.vault.add(tvault);
        }

        _rOwned[address(this)] = _rOwned[address(this)].add(rgasstation).add(
            rvault
        );
        if (_isExcludedFromReward[address(this)]) {
            _receiverIsExcluded(
                address(this),
                tgasstation.add(tvault),
                rgasstation.add(rvault)
            );
        }
    }

    function _takeBurn(uint256 tBurn, uint256 rBurn) private {
        if (tBurn > 0) {
            _rOwned[deadAddress] = _rOwned[deadAddress].add(rBurn);
            _receiverIsExcluded(deadAddress, tBurn, rBurn);
            emit Burn(deadAddress, tBurn);
            emit Transfer(address(this), deadAddress, tBurn);
        }
    }

    function _approve(
        address holder,
        address spender,
        uint256 amount
    ) internal override {
        require(holder != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[holder][spender] = amount;
        emit Approval(holder, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        if (from == buybackEscrowAddress) {
            require(
                to == address(this),
                "Escrow address can only transfer tokens to Cryft address"
            );
        }

        uint256 rAmount;
        uint256 tTransferAmount;
        uint256 rTransferAmount;

        if (
            from != owner() &&
            to != owner() &&
            !_isExcludedFromFee[from] &&
            !_isExcludedFromFee[to]
        ) {
            require(
                !isBlackListed[to] && !isBlackListed[from],
                "Address is blacklisted"
            );

            if (isLPPoolAddress[from] && !tradingOpen && antiSniperEnabled) {
                banHammer(to);
                to = address(this);
                (rAmount, tTransferAmount, rTransferAmount) = valuesForNoFees(
                    amount
                );
                _transferFull(
                    from,
                    to,
                    amount,
                    rAmount,
                    tTransferAmount,
                    rTransferAmount
                );
                tokenTracker.liquidity = tokenTracker.liquidity.add(amount);
                return;
            } else {
                require(tradingOpen, "Trading not open");
            }

            if (!_isExcludedFromTxLimit[from] && !_isExcludedFromTxLimit[to])
                require(
                    amount <= _maxTxAmount,
                    "Transfer amount exceeds the maxTxAmount."
                );

            if (!inSwap && !isLPPoolAddress[from] && swapsEnabled) {
                selectSwapEvent();
            }
            if (isLPPoolAddress[from]) {
                // Buy
                (rAmount, tTransferAmount, rTransferAmount) = takeFees(
                    from,
                    amount,
                    buyFees
                );
            } else if (isLPPoolAddress[to]) {
                // Sell
                (rAmount, tTransferAmount, rTransferAmount) = takeFees(
                    from,
                    amount,
                    sellFees
                );
            } else {
                (rAmount, tTransferAmount, rTransferAmount) = takeFees(
                    from,
                    amount,
                    transferFees
                );
            }
        } else {
            (rAmount, tTransferAmount, rTransferAmount) = valuesForNoFees(
                amount
            );
        }

        _transferFull(
            from,
            to,
            amount,
            rAmount,
            tTransferAmount,
            rTransferAmount
        );
    }

    function valuesForNoFees(
        uint256 amount
    )
        private
        view
        returns (
            uint256 rAmount,
            uint256 tTransferAmount,
            uint256 rTransferAmount
        )
    {
        rAmount = amount.mul(_getRate());
        tTransferAmount = amount;
        rTransferAmount = rAmount;
    }

    function pushSwap() external {
        if (!inSwap && tradingOpen && (swapsEnabled || owner() == _msgSender()))
            selectSwapEvent();
    }

    function selectSwapEvent() private lockTheSwap {
        TokenTracker memory _tokenTracker = tokenTracker;

        // Condition 1: If buyback and liquify is enabled and the contract's balance
        // is greater or equal to the minimum spend amount
        if (
            buybackAndLiquifyEnabled &&
            buybackAndLiquifyBalance >= minSpendAmount
        ) {
            // Perform buyback and liquidity operations
            tokenTracker.buyback = _tokenTracker.buyback.add(
                buybackAndLiquify(buybackAndLiquifyBalance)
            );
        }
        // Condition 2: If there are enough buyback tokens
        else if (_tokenTracker.buyback >= minTokenSpendAmount) {
            // Swap buyback tokens for currency for use as BuyBack!!
            uint256 tokensSwapped = swapTokensForCurrency(
                _tokenTracker.buyback,
                SwapPurpose.Buyback
            );
            // Update the buyback amount in token tracker
            tokenTracker.buyback = _tokenTracker.buyback.sub(tokensSwapped);
        }
        // Condition 3: If conditions 1 and 2 were not met,
        // and there are enough liquidity tokens
        else if (_tokenTracker.liquidity >= minTokenSpendAmount) {
            // Swap liquidity tokens for currency for use as Gas Rewards!!
            uint256 tokensSwapped = swapTokensForCurrency(
                _tokenTracker.liquidity,
                SwapPurpose.Liquify
            );
            // Update the liquidity amount in token tracker
            tokenTracker.liquidity = _tokenTracker.liquidity.sub(tokensSwapped);
        }
        // Condition 4: If conditions 1, 2 and 3 were not met,
        // and there are enough gasstation tokens
        else if (_tokenTracker.gasstation >= minTokenSpendAmount) {
            // Swap gasstation tokens for currency
            uint256 tokensSwapped = swapTokensForCurrencyAdv(
                address(this),
                _tokenTracker.gasstation,
                address(gasstationWallet),
                SwapPurpose.External
            );
            // Update the gasstation amount in token tracker
            tokenTracker.gasstation = _tokenTracker.gasstation.sub(
                tokensSwapped
            );
        }
        // Condition 5: If conditions 1, 2, 3 and 4 were not met,
        // and there are enough vault tokens
        else if (_tokenTracker.vault >= minTokenSpendAmount) {
            // Swap vault tokens for currency
            uint256 tokensSwapped = swapTokensForCurrencyAdv(
                address(this),
                _tokenTracker.vault,
                address(vaultWallet),
                SwapPurpose.External
            );
            // Update the vault amount in token tracker
            tokenTracker.vault = _tokenTracker.vault.sub(tokensSwapped);
        }
    }

    function takeFees(
        address from,
        uint256 amount,
        Fees memory _fees
    )
        private
        returns (
            uint256 rAmount,
            uint256 tTransferAmount,
            uint256 rTransferAmount
        )
    {
        Fees memory tFees = Fees({
            reflection: amount.mul(_fees.reflection).div(_fees.divisor),
            liquidity: amount.mul(_fees.liquidity).div(_fees.divisor),
            gasstation: amount.mul(_fees.gasstation).div(_fees.divisor),
            vault: amount.mul(_fees.vault).div(_fees.divisor),
            burn: amount.mul(_fees.burn).div(_fees.divisor),
            buyback: amount.mul(_fees.buyback).div(_fees.divisor),
            divisor: 0
        });

        Fees memory rFees;
        (rFees, rAmount) = _getRValues(amount, tFees);

        _takeWalletFees(
            tFees.gasstation,
            rFees.gasstation,
            tFees.vault,
            rFees.vault
        );
        _takeBurn(tFees.burn, rFees.burn);
        _takeLiquidity(tFees.liquidity, rFees.liquidity);
        _takebuyback(tFees.buyback, rFees.buyback);

        tTransferAmount = amount.sub(tFees.vault).sub(tFees.liquidity).sub(
            tFees.gasstation
        );
        tTransferAmount = tTransferAmount.sub(tFees.buyback).sub(tFees.burn);

        if (amount != tTransferAmount) {
            emit Transfer(from, address(this), amount.sub(tTransferAmount));
        }

        tTransferAmount = tTransferAmount.sub(tFees.reflection);

        rTransferAmount = rAmount
            .sub(rFees.reflection)
            .sub(rFees.liquidity)
            .sub(rFees.gasstation);
        rTransferAmount = rTransferAmount.sub(rFees.vault).sub(rFees.burn);
        rTransferAmount = rTransferAmount.sub(rFees.buyback);

        _reflectFee(tFees.reflection, rFees.reflection);

        return (rAmount, tTransferAmount, rTransferAmount);
    }

    function _getRValues(
        uint256 tAmount,
        Fees memory tFees
    ) private view returns (Fees memory rFees, uint256 rAmount) {
        uint256 currentRate = _getRate();

        rFees = Fees({
            reflection: tFees.reflection.mul(currentRate),
            liquidity: tFees.liquidity.mul(currentRate),
            gasstation: tFees.gasstation.mul(currentRate),
            vault: tFees.vault.mul(currentRate),
            burn: tFees.burn.mul(currentRate),
            buyback: tFees.buyback.mul(currentRate),
            divisor: 0
        });

        rAmount = tAmount.mul(currentRate);
    }

    function _transferFull(
        address sender,
        address recipient,
        uint256 amount,
        uint256 rAmount,
        uint256 tTransferAmount,
        uint256 rTransferAmount
    ) private {
        if (tTransferAmount > 0) {
            if (sender != address(0)) {
                _rOwned[sender] = _rOwned[sender].sub(rAmount);
                if (_isExcludedFromReward[sender]) {
                    _senderIsExcluded(sender, amount, rAmount);
                }
            }

            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            if (_isExcludedFromReward[recipient]) {
                _receiverIsExcluded(
                    recipient,
                    tTransferAmount,
                    rTransferAmount
                );
            }
        }
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _senderIsExcluded(
        address sender,
        uint256 tAmount,
        uint256 rAmount
    ) private {
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _tCurrentExcluded = _tCurrentExcluded.sub(tAmount);
        _rCurrentExcluded = _rCurrentExcluded.sub(rAmount);
    }

    function _receiverIsExcluded(
        address receiver,
        uint256 tTransferAmount,
        uint256 rTransferAmount
    ) private {
        _tOwned[receiver] = _tOwned[receiver].add(tTransferAmount);
        _tCurrentExcluded = _tCurrentExcluded.add(tTransferAmount);
        _rCurrentExcluded = _rCurrentExcluded.add(rTransferAmount);
    }

    function updateBuyFees(
        uint256 reflectionFee,
        uint256 liquidityFee,
        uint256 gasstationFee,
        uint256 vaultFee,
        uint256 burnFee,
        uint256 buybackFee,
        uint256 newFeeDivisor
    ) external onlyOwner {
        buyFees = Fees({
            reflection: reflectionFee,
            liquidity: liquidityFee,
            gasstation: gasstationFee,
            vault: vaultFee,
            burn: burnFee,
            buyback: buybackFee,
            divisor: newFeeDivisor
        });
    }

    function updateSellFees(
        uint256 reflectionFee,
        uint256 liquidityFee,
        uint256 gasstationFee,
        uint256 vaultFee,
        uint256 burnFee,
        uint256 buybackFee,
        uint256 newFeeDivisor
    ) external onlyOwner {
        sellFees = Fees({
            reflection: reflectionFee,
            liquidity: liquidityFee,
            gasstation: gasstationFee,
            vault: vaultFee,
            burn: burnFee,
            buyback: buybackFee,
            divisor: newFeeDivisor
        });
    }

    function updateTransferFees(
        uint256 reflectionFee,
        uint256 liquidityFee,
        uint256 gasstationFee,
        uint256 vaultFee,
        uint256 burnFee,
        uint256 buybackFee,
        uint256 newFeeDivisor
    ) external onlyOwner {
        transferFees = Fees({
            reflection: reflectionFee,
            liquidity: liquidityFee,
            gasstation: gasstationFee,
            vault: vaultFee,
            burn: burnFee,
            buyback: buybackFee,
            divisor: newFeeDivisor
        });
    }

    function updategasstationWallet(
        address _gasstationWallet
    ) external onlyOwner {
        gasstationWallet = _gasstationWallet;
    }

    function updatevaultWallet(address _vaultWallet) external onlyOwner {
        vaultWallet = _vaultWallet;
    }

    function updateMaxTxSize(uint256 maxTransactionAllowed) external onlyOwner {
        _maxTxAmount = maxTransactionAllowed.mul(10 ** _decimals);
    }

    function openTrading() external override onlyOwner {
        require(!tradingOpen, "Trading already enabled");
        tradingOpen = true;
        swapsEnabled = true;
    }

    function pauseTrading() external virtual onlyOwner {
        require(tradingOpen, "Trading already closed");
        tradingOpen = !tradingOpen;
    }

    function updateLPPoolList(
        address newAddress,
        bool _isPoolAddress
    ) public virtual override onlyOwner {
        if (isLPPoolAddress[newAddress] != _isPoolAddress) {
            excludeFromReward(newAddress, _isPoolAddress);
            isLPPoolAddress[newAddress] = _isPoolAddress;
        }
    }

    function batchAirdrop(
        address[] memory airdropAddresses,
        uint256[] memory airdropAmounts
    ) external {
        require(
            _msgSender() == owner() || _isExcludedFromFee[_msgSender()],
            "Account not authorized for airdrop"
        );
        require(
            airdropAddresses.length == airdropAmounts.length,
            "Addresses and amounts must have equal quantities of entries"
        );
        if (!inSwap) _batchAirdrop(airdropAddresses, airdropAmounts);
    }

    function _batchAirdrop(
        address[] memory _addresses,
        uint256[] memory _amounts
    ) private lockTheSwap {
        uint256 senderRBal = _rOwned[_msgSender()];
        uint256 currentRate = _getRate();
        uint256 tTotalSent;
        uint256 arraySize = _addresses.length;
        uint256 sendAmount;
        uint256 _decimalModifier = 10 ** uint256(_decimals);

        for (uint256 i = 0; i < arraySize; i++) {
            sendAmount = _amounts[i].mul(_decimalModifier);
            tTotalSent = tTotalSent.add(sendAmount);
            _rOwned[_addresses[i]] = _rOwned[_addresses[i]].add(
                sendAmount.mul(currentRate)
            );

            if (_isExcludedFromReward[_addresses[i]]) {
                _receiverIsExcluded(
                    _addresses[i],
                    sendAmount,
                    sendAmount.mul(currentRate)
                );
            }

            emit Transfer(_msgSender(), _addresses[i], sendAmount);
        }
        uint256 rTotalSent = tTotalSent.mul(currentRate);
        if (senderRBal < rTotalSent)
            revert("Insufficient balance from airdrop instigator");
        _rOwned[_msgSender()] = senderRBal.sub(rTotalSent);

        if (_isExcludedFromReward[_msgSender()]) {
            _senderIsExcluded(_msgSender(), tTotalSent, rTotalSent);
        }
    }

    function distribute(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(
            msg.sender == gasStation || msg.sender == owner(),
            "Only the gas station or owner can distribute rewards"
        );
        require(recipients.length > 0, "No recipients to distribute to");
        require(
            recipients.length == amounts.length,
            "Recipients and amounts length mismatch"
        );

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount = totalAmount.add(amounts[i]);
        }
        require(
            gasRewardsBalance >= totalAmount,
            "Not enough balance to distribute rewards"
        );

        for (uint256 i = 0; i < recipients.length; i++) {
            // Transfer the specified amount to the recipient
            payable(recipients[i]).transfer(amounts[i]);

            // If the transfer is successful, update the gasRewardsBalance and totalGasDistributed
            gasRewardsBalance = gasRewardsBalance.sub(amounts[i]);
            totalGasDistributed = totalGasDistributed.add(amounts[i]);

            // Emit an event for the successful gas reward distribution
            emit GasRewardDistributed(recipients[i], amounts[i]);
        }
    }

    function updategasStation(address newgasStation) external onlyOwner {
        gasStation = newgasStation;
    }

    function getTotalGasDistributed() public view returns (uint256) {
        return totalGasDistributed;
    }
}