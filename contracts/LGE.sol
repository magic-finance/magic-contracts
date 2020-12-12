// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./IMAGICGlobals.sol";

import "./uniswapv2/interfaces/IWETH.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/Initializable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./uniswapv2/interfaces/IUniswapV2Pair.sol";
import "./uniswapv2/interfaces/IUniswapV2Factory.sol";
import "./IMagicVault.sol";

// import "hardhat/console.sol";

interface IERC95 {
    function wrapAtomic(address) external;

    function transfer(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function skim(address to) external;

    function unpauseTransfers() external;
}

interface IMAGICTransferHandler {
    function sync(address) external returns (bool, bool);

    function feePercentX100() external returns (uint8);
}

contract LGE is Initializable, OwnableUpgradeSafe {
    using SafeMath for uint256;

    uint256 private locked;
    // Reentrancy lock
    modifier lock() {
        require(locked == 0, "MAGIC LGE: LOCKED");
        locked = 1;
        _; // Can't re-eter until function is finished
        locked = 0;
    }

    /// Addresses of different tokens
    address public WETH;
    address public MAGIC;
    address public DAI;
    address public mDAIxmMAGICUniswapPair;
    address public mDAI; // TODO : Add setters
    address public mMAGIC;
    address payable public MAGIC_MULTISIG;

    // Uniswap factories for recognising LP tokens
    address public uniswapFactory;
    address public sushiswapFactory;

    ////////////////////////////////////////
    // Variables for calculating LP gotten per each user
    // Note all contributions get "flattened" to MAGIC
    // This means we just calculate how much MAGIC it would buy with the running average
    // And use that as the counter
    uint256 public totalLPCreated;
    uint256 private totalMAGICUnitsContributed;
    uint256 public LPPerMAGICUnitContributed; // stored as 1e18 more - this is done for change
    ////////////////////////////////////////

    event Contibution(uint256 MAGICvalue, address from);
    event MAGICBought(uint256 MAGICamt);

    mapping(address => PriceAverage) _averagePrices;
    struct PriceAverage {
        uint8 lastAddedHead;
        uint256[20] price;
        uint256 cumulativeLast20Blocks;
        bool arrayFull;
        uint256 lastBlockOfIncrement; // Just update once per block ( by buy token function )
    }
    mapping(address => bool) public claimed;
    mapping(address => bool) public doNotSellList;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public tokenReserves;

    IMAGICGlobals public magicGlobals;
    bool public LGEStarted;
    bool public LGEFinished;
    bool public LGEPaused;
    uint256 public contractStartTimestamp;
    uint256 public contractStartTimestampSaved;
    uint256 public LGEDurationDays;

    function initialize() public initializer {
        require(
            msg.sender == address(0x5A16552f59ea34E44ec81E58b3817833E9fD5436)
        );
        OwnableUpgradeSafe.__Ownable_init();

        contractStartTimestamp = uint256(-1); // wet set it here to max so checks fail
        LGEDurationDays = 7 days;

        DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        MAGIC = 0x62359Ed7505Efc61FF1D56fEF82158CcaffA23D7;
        WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        uniswapFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
        sushiswapFactory = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
        MAGIC_MULTISIG = 0x5A16552f59ea34E44ec81E58b3817833E9fD5436;
        magicGlobals = IMAGICGlobals(
            0x255CA4596A963883Afe0eF9c85EA071Cc050128B
        );

        doNotSellList[DAI] = true;
        doNotSellList[MAGIC] = true;
        doNotSellList[WETH] = true;
    }

    /// Starts LGE by admin call
    function startLGE() public onlyOwner {
        require(LGEStarted == false, "Already started");

        contractStartTimestamp = block.timestamp;
        LGEStarted = true;

        rescueRatioLock(MAGIC);
        rescueRatioLock(DAI);
    }

    //////////////////////////////////////////////
    //////////////////////////////////////////////
    //////////////////////////////////////////////
    /// CONTRIBUTIONS
    /// Contributions user functions

    // Handling weth deposits
    function addLiquidityETH() external payable lock {
        require(LGEStarted == true, "LGE : Didn't start");
        require(LGEFinished == false, "LGE : Liquidity generation finished");
        require(isLGEOver() == false, "LGE : Is over.");
        require(
            msg.value > 0,
            "LGE : You should deposit something most likely"
        );

        IWETH(WETH).deposit{value: msg.value}();
        // console.log("Value of ETH deposit is", msg.value / 1e18, "ETH");


            uint256 valueInMAGICUnits
         = getAveragePriceLast20BlocksIn1WETHPriceWorth(MAGIC)
            .mul(msg.value)
            .div(1e18);
        credit[msg.sender] = credit[msg.sender].add(valueInMAGICUnits);
        tokenReserves[WETH] = tokenReserves[WETH].add(msg.value);
        updateRunningAverages();
    }

    // Main function to contribute any token
    // Which will sell eveyr token we don't keep for WETH
    function contributeWithAllowance(
        address _token,
        uint256 _amountContribution
    ) public lock {
        require(LGEStarted == true, "LGE : Didn't start");
        require(LGEFinished == false, "LGE : Liquidity generation finished");
        require(isLGEOver() == false, "LGE : Is over.");
        require(
            _amountContribution > 0,
            "LGE : You should deposit something most likely"
        );

        // We get the token from person safely
        // We check against reserves
        // We update our reserves with amount that flew in
        address[] memory tokensToSell;

        address token0;
        // We check if we can call a method for token 0
        // Which uniswap pairs have and nothhing else does
        // If this is a trap token, which has this method, it wont be on the factory
        try IUniswapV2Pair(_token).token0()  {
            token0 = IUniswapV2Pair(_token).token0();
        } catch {}

        // We try to get it before if it was a normal token it would just not get written
        if (token0 != address(0)) {
            address token1 = IUniswapV2Pair(_token).token1();
            bool isUniLP = IUniswapV2Factory(uniswapFactory).getPair(
                token1,
                token0
            ) != address(0);
            bool isSushiLP = IUniswapV2Factory(sushiswapFactory).getPair(
                token0,
                token1
            ) != address(0);
            if (!isUniLP && !isSushiLP) {
                revert("LGE : LP Token type not accepted");
            } // reverts here
            // If its a LP we sell it
            safeTransferFrom(_token, msg.sender, _token, _amountContribution);
            uint256 balanceToken0Before = IERC20(token0).balanceOf(
                address(this)
            );
            uint256 balanceToken1Before = IERC20(token1).balanceOf(
                address(this)
            );
            IUniswapV2Pair(_token).burn(address(this));
            uint256 balanceToken0After = IERC20(token0).balanceOf(
                address(this)
            );
            uint256 balanceToken1After = IERC20(token1).balanceOf(
                address(this)
            );

            uint256 amountOutToken0 = token0 == WETH
                ? balanceToken0After.sub(balanceToken0Before)
                : sellTokenForWETH(
                    token0,
                    balanceToken0After.sub(balanceToken0Before),
                    false
                );

            uint256 amountOutToken1 = token1 == WETH
                ? balanceToken1After.sub(balanceToken1Before)
                : sellTokenForWETH(
                    token1,
                    balanceToken1After.sub(balanceToken1Before),
                    false
                );

            uint256 balanceWETHNew = IERC20(WETH).balanceOf(address(this));
            // console.log("Balance WETH", balanceWETHNew);

            uint256 reserveWETH = tokenReserves[WETH];
            // console.log("amountOutToken0",amountOutToken0);
            // console.log("amountOutToken1",amountOutToken1);
            // console.log("REserve", reserveWETH);

            require(balanceWETHNew > reserveWETH, "sir.");
            uint256 totalWETHAdded = amountOutToken0.add(amountOutToken1);
            require(
                tokenReserves[WETH].add(totalWETHAdded) <= balanceWETHNew,
                "Ekhm"
            ); // In case someone sends dirty dirty dust
            tokenReserves[WETH] = balanceWETHNew;


                uint256 valueInMAGICUnits
             = getAveragePriceLast20BlocksIn1WETHPriceWorth(MAGIC)
                .mul(totalWETHAdded)
                .div(1e18);

            // console.log("Crediting for MAGIC UNITS",valueInMAGICUnits);
            // console.log("Which is without deimals", valueInMAGICUnits/1e18);
            credit[msg.sender] = credit[msg.sender].add(valueInMAGICUnits);
            emit Contibution(valueInMAGICUnits, msg.sender);

            // We did everything
            updateRunningAverages();
            return;
        }

        // We loop over each token

        if (doNotSellList[_token] && token0 == address(0)) {
            // We dont sell this token aka its MAGIC or DAI
            // Not needed check but maybe?
            // We count it as higher even tho FoT
            if (_token == MAGIC) {
                safeTransferFrom(
                    MAGIC,
                    msg.sender,
                    address(this),
                    _amountContribution
                );
                uint256 MAGICReserves = IERC20(MAGIC).balanceOf(address(this));
                require(
                    MAGICReserves >= tokenReserves[MAGIC],
                    "Didn't get enough MAGIC"
                );
                credit[msg.sender] = credit[msg.sender].add(
                    _amountContribution
                ); // we can trust this cause
                // we know MAGIC
                tokenReserves[MAGIC] = MAGICReserves;
                emit Contibution(_amountContribution, msg.sender);
            } else if (_token == DAI) {
                safeTransferFrom(
                    DAI,
                    msg.sender,
                    address(this),
                    _amountContribution
                );
                uint256 DAIReserves = IERC20(DAI).balanceOf(address(this));
                require(
                    DAIReserves >= tokenReserves[DAI].add(_amountContribution),
                    "Didn't get enough DAI"
                );

                // console.log("Credit in DAI right now amount : ",  _amountContribution/1e18);
                uint256 valueInWETH = _amountContribution.mul(1e18).div(
                    getAveragePriceLast20BlocksIn1WETHPriceWorth(DAI)
                ); // 1weth buys this much DAI so we divide to get numer of weth

                // console.log("Thats in WETH", valueInWETH/1e18);


                    uint256 valueInMAGICUnits
                 = getAveragePriceLast20BlocksIn1WETHPriceWorth(MAGIC)
                    .mul(valueInWETH)
                    .div(1e18);

                // console.log("Value in MAGIC ",valueInMAGICUnits /1e18);
                credit[msg.sender] = credit[msg.sender].add(valueInMAGICUnits);
                // We can similiary trust this cause we know DAI
                tokenReserves[DAI] = DAIReserves;
                emit Contibution(valueInMAGICUnits, msg.sender);
            } else if (_token == WETH) {
                // This is when WETH is deposited
                // When its deposited from LP it will be alse so we wont ry to transfer from.
                safeTransferFrom(
                    WETH,
                    msg.sender,
                    address(this),
                    _amountContribution
                );
                uint256 reservesWETHNew = IERC20(WETH).balanceOf(address(this));
                require(
                    reservesWETHNew >=
                        tokenReserves[WETH].add(_amountContribution),
                    "Didn't get enough WETH"
                );
                tokenReserves[WETH] = reservesWETHNew;


                    uint256 valueInMAGICUnits
                 = getAveragePriceLast20BlocksIn1WETHPriceWorth(MAGIC)
                    .mul(_amountContribution)
                    .div(1e18);
                credit[msg.sender] = credit[msg.sender].add(valueInMAGICUnits);
                emit Contibution(valueInMAGICUnits, msg.sender);
            } else {
                revert("Unsupported Token Error, somehow on not to sell list");
            }

            // If its DAI we sell if for WETH if we have too much dai
        } else {
            // console.log("Found a shitcoin, selling it");
            uint256 amountOut = sellTokenForWETH(
                _token,
                _amountContribution,
                true
            );
            // console.log("Sold shitcoin for WETH units", amountOut);
            // console.log("Thats without decimals", amountOut/1e18);
            uint256 balanceWETHNew = IERC20(WETH).balanceOf(address(this));
            uint256 reserveWETH = tokenReserves[WETH];
            require(balanceWETHNew > reserveWETH, "sir.");
            // console.log("Amount out",amountOut);
            // console.log("Balance new ", balanceWETHNew);
            // console.log("Reserves", reserveWETH);
            require(reserveWETH.add(amountOut) <= balanceWETHNew, "Ekhm"); // In case someone sends dirty dirty dust
            tokenReserves[WETH] = balanceWETHNew;


                uint256 valueInMAGICUnits
             = getAveragePriceLast20BlocksIn1WETHPriceWorth(MAGIC)
                .mul(amountOut)
                .div(1e18);
            // console.log("Crediting for MAGIC UNITS",valueInMAGICUnits);
            // console.log("Which is without deimals", valueInMAGICUnits/1e18);
            credit[msg.sender] = credit[msg.sender].add(valueInMAGICUnits);
            emit Contibution(valueInMAGICUnits, msg.sender);
        }
        updateRunningAverages(); // After transactions are done
    }

    /// Claiming LP User functions
    function claimLP() public lock {
        safeTransfer(mDAIxmMAGICUniswapPair, msg.sender, _mlaimLP());
    }

    function claimAndStakeLP() public lock {
        address vault = magicGlobals.MAGICVaultAddress();
        IUniswapV2Pair(mDAIxmMAGICUniswapPair).approve(vault, uint256(-1));
        IMagicVault(vault).depositFor(msg.sender, 3, _mlaimLP());
    }

    function _mlaimLP() internal returns (uint256 claimable) {
        uint256 credit = credit[msg.sender]; // gas savings

        require(LGEFinished == true, "LGE : Liquidity generation not finished");
        require(claimed[msg.sender] == false, "LGE : Already claimed");
        require(credit > 0, "LGE : Nothing to be claimed");

        claimable = credit.mul(LPPerMAGICUnitContributed).div(1e18);
        // LPPerUnitContributed is stored at 1e18 multiplied

        claimed[msg.sender] = true;
    }

    //////////////////////////////////////////////
    //////////////////////////////////////////////
    //////////////////////////////////////////////
    /// VIEWS

    function getDAIxMAGICBuyAmountsToEquilibrum(uint256 contributionValueETH)
        public
        view
        returns (uint256 MAGICBuyinETH, uint256 DAIBuyInETH)
    {
        /// This ratio is flashloanable which would throw the peg off
        /// But this is not a priority here. As its not a profitable attack to the attacker.
        (
            uint256 MAGICValueETH,
            uint256 DAIValueETH
        ) = getDAIandMAGICReservesValueInETH();

        if (MAGICValueETH == DAIValueETH)
            return (contributionValueETH.div(2), contributionValueETH.div(2));

        if (MAGICValueETH > DAIValueETH) {
            // To equalibrium
            uint256 DAIBuyToEquilibrium = MAGICValueETH - DAIValueETH;

            if (DAIBuyToEquilibrium + 1 >= contributionValueETH) {
                // If its nto 2 wei we cant split
                return (0, contributionValueETH);
            }

            // We take the equalibrium and check how many percent of total contribution it is
            uint256 restETH = contributionValueETH - DAIBuyToEquilibrium;

            DAIBuyInETH = DAIBuyToEquilibrium.add(restETH).div(2);
            MAGICBuyinETH = restETH.div(2);
        } else {
            // DAIValueETH is bigger than MAGICValueETH

            uint256 MAGICBuyToEquilibrium = DAIValueETH - MAGICValueETH;

            if (MAGICBuyToEquilibrium + 1 >= contributionValueETH) {
                // If its nto 2 wei we cant split
                return (contributionValueETH, 0);
            }

            uint256 restETH = contributionValueETH - MAGICBuyToEquilibrium;
            MAGICBuyinETH = MAGICBuyToEquilibrium.add(restETH).div(2);
            DAIBuyInETH = restETH.div(2);
        }
    }

    function isLGEOver() public view returns (bool) {
        return block.timestamp > contractStartTimestamp.add(LGEDurationDays);
    }

    // returns WETH value of both reserves (dai and MAGIC for internal purposes)
    function getDAIandMAGICReservesValueInETH()
        internal
        view
        returns (uint256 MAGICValueETH, uint256 DAIValueETH)
    {
        (uint256 reserveMAGIC, uint256 reserveDAI) = (
            tokenReserves[MAGIC],
            tokenReserves[DAI]
        );
        MAGICValueETH = reserveMAGIC.div(1e8).mul(
            getWETHValueOf1e8TokenUnits(MAGIC)
        );
        DAIValueETH = reserveDAI.div(1e8).mul(getWETHValueOf1e8TokenUnits(DAI));
    }

    // returns WETH value of both reserves (dai and MAGIC + WETH)
    function getLGEContributionsValue()
        public
        view
        returns (
            uint256 MAGICValueETH,
            uint256 DAIValueETH,
            uint256 ETHValue
        )
    {
        (uint256 reserveMAGIC, uint256 reserveDAI) = (
            tokenReserves[MAGIC],
            tokenReserves[DAI]
        );
        MAGICValueETH = reserveMAGIC.div(1e8).mul(
            getWETHValueOf1e8TokenUnits(MAGIC)
        );
        DAIValueETH = reserveDAI.div(1e8).mul(getWETHValueOf1e8TokenUnits(DAI));
        ETHValue = IERC20(WETH).balanceOf(address(this));
    }

    function getWETHValueOf1e8TokenUnits(address _token)
        internal
        view
        returns (uint256)
    {
        address pairWithWETH = IUniswapV2Factory(uniswapFactory).getPair(
            _token,
            WETH
        );
        if (pairWithWETH == address(0)) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(pairWithWETH);
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();

        if (pair.token0() == WETH) {
            return getAmountOut(1e8, reserve1, reserve0);
        } else {
            return getAmountOut(1e8, reserve0, reserve1);
        }
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    //////////////////////////////////////////////
    //////////////////////////////////////////////
    //////////////////////////////////////////////
    /// Admin balancing functions
    function buyMAGICforWETH(uint256 amountWETH, uint256 minAmountMAGICOut)
        public
        onlyOwner
    {
        (
            uint256 MAGICValueETH,
            uint256 DAIValueETH
        ) = getDAIandMAGICReservesValueInETH();
        require(
            MAGICValueETH.add(amountWETH) <= DAIValueETH,
            "Buying too much MAGIC"
        );
        IUniswapV2Pair pair = IUniswapV2Pair(
            0x32Ce7e48debdccbFE0CD037Cc89526E4382cb81b
        ); // MAGIC/WETH pair
        safeTransfer(WETH, address(pair), amountWETH);
        // MAGIC is token0
        (uint256 reservesMAGIC, uint256 reservesWETH, ) = pair.getReserves();
        uint256 magicOUT = getAmountOut(
            amountWETH,
            reservesWETH,
            reservesMAGIC
        );
        pair.swap(magicOUT, 0, address(this), "");
        tokenReserves[MAGIC] = tokenReserves[MAGIC].add(magicOUT);
        tokenReserves[WETH] = IERC20(WETH).balanceOf(address(this));
        require(magicOUT >= minAmountMAGICOut, "Buy Slippage too high");
        emit MAGICBought(magicOUT);
    }

    function buyDAIforWETH(uint256 amountWETH, uint256 minAmountDAIOut)
        public
        onlyOwner
    {
        IUniswapV2Pair pair = IUniswapV2Pair(
            0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11
        ); // DAI/WETH pair
        safeTransfer(WETH, address(pair), amountWETH);
        // DAI is token0
        (uint256 reservesDAI, uint256 reservesWETH, ) = pair.getReserves();
        uint256 daiOUT = getAmountOut(amountWETH, reservesWETH, reservesDAI);
        pair.swap(daiOUT, 0, address(this), "");
        tokenReserves[DAI] = IERC20(DAI).balanceOf(address(this));
        tokenReserves[WETH] = IERC20(WETH).balanceOf(address(this));
        require(daiOUT >= minAmountDAIOut, "Buy Slippage too high");
    }

    function sellDAIforWETH(uint256 amountDAI, uint256 minAmountWETH)
        public
        onlyOwner
    {
        IUniswapV2Pair pair = IUniswapV2Pair(
            0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11
        ); // DAI/WETH pair
        safeTransfer(DAI, address(pair), amountDAI);
        // DAI is token0
        (uint256 reservesDAI, uint256 reservesWETH, ) = pair.getReserves();
        uint256 wethOUT = getAmountOut(amountDAI, reservesDAI, reservesWETH);
        pair.swap(0, wethOUT, address(this), "");
        tokenReserves[DAI] = IERC20(DAI).balanceOf(address(this));
        tokenReserves[WETH] = IERC20(WETH).balanceOf(address(this));
        require(wethOUT >= minAmountWETH, "Buy Slippage too high");
    }

    //////////////////////////////////////////////
    //////////////////////////////////////////////
    //////////////////////////////////////////////
    /// Anti flash loan manipulation running averages
    function updateRunningAverages() internal {
        if (_averagePrices[DAI].lastBlockOfIncrement != block.number) {
            _averagePrices[DAI].lastBlockOfIncrement = block.number;
            updateRunningAveragePrice(DAI, false);
        }
        if (_averagePrices[MAGIC].lastBlockOfIncrement != block.number) {
            _averagePrices[MAGIC].lastBlockOfIncrement = block.number;
            updateRunningAveragePrice(MAGIC, false);
        }
    }

    // This is out tokens per 1WETH (1e18 units)
    function getAveragePriceLast20BlocksIn1WETHPriceWorth(address token)
        public
        view
        returns (uint256)
    {
        return
            _averagePrices[token].cumulativeLast20Blocks.div(
                _averagePrices[token].arrayFull
                    ? 20
                    : _averagePrices[token].lastAddedHead
            );
        // We check if the "array is full" because 20 writes might not have happened yet
        // And therefor the average would be skewed by dividing it by 20
    }

    // NOTE outTokenFor1WETH < lastQuote.mul(150).div(100) check
    function updateRunningAveragePrice(address token, bool isRescue)
        internal
        returns (uint256)
    {
        PriceAverage storage currentAveragePrices = _averagePrices[token];
        address pairWithWETH = IUniswapV2Factory(uniswapFactory).getPair(
            token,
            WETH
        );
        uint256 wethReserves;
        uint256 tokenReserves;
        if (WETH == IUniswapV2Pair(pairWithWETH).token0()) {
            (wethReserves, tokenReserves, ) = IUniswapV2Pair(pairWithWETH)
                .getReserves();
        } else {
            (tokenReserves, wethReserves, ) = IUniswapV2Pair(pairWithWETH)
                .getReserves();
        }
        // Get amt you would get for 1eth
        uint256 outTokenFor1WETH = getAmountOut(
            1e18,
            wethReserves,
            tokenReserves
        );
        // console.log("Inside running average out token for 1 weth is", outTokenFor1WETH);

        uint8 i = currentAveragePrices.lastAddedHead;

        ////////////////////
        /// flash loan safety
        //we check the last first quote price against current
        uint256 oldestQuoteIndex;
        if (currentAveragePrices.arrayFull == true) {
            if (i != 19) {
                oldestQuoteIndex = i + 1;
            } // its 0 already else
        } else {
            if (i > 0) {
                oldestQuoteIndex = i - 1;
            } // its 0 already else
        }
        uint256 firstQuote = currentAveragePrices.price[oldestQuoteIndex];

        // Safety flash loan revert
        // If change is above 50%
        // This can be rescued by the bool "isRescue"
        if (isRescue == false) {
            require(
                outTokenFor1WETH < firstQuote.mul(15000).div(10000),
                "Change too big from first recorded price"
            );
        }
        ////////////////////

        currentAveragePrices.cumulativeLast20Blocks = currentAveragePrices
            .cumulativeLast20Blocks
            .sub(currentAveragePrices.price[i]);
        currentAveragePrices.price[i] = outTokenFor1WETH;
        currentAveragePrices.cumulativeLast20Blocks = currentAveragePrices
            .cumulativeLast20Blocks
            .add(outTokenFor1WETH);
        currentAveragePrices.lastAddedHead++;
        if (currentAveragePrices.lastAddedHead > 19) {
            currentAveragePrices.lastAddedHead = 0;
            currentAveragePrices.arrayFull = true;
        }
        return currentAveragePrices.cumulativeLast20Blocks;
    }

    // Because its possible that price of someting legitimately goes +50%
    // Then the updateRunningAveragePrice would be stuck until it goes down,
    // This allows the admin to "rescue" it by writing a new average
    // skiping the +50% check
    function rescueRatioLock(address token) public onlyOwner {
        updateRunningAveragePrice(token, true);
    }

    //////////////////////////////////////////////
    //////////////////////////////////////////////
    //////////////////////////////////////////////
    /// Ending the LGE
    function addLiquidityToPair() public onlyOwner {
        require(
            block.timestamp > contractStartTimestamp.add(LGEDurationDays),
            "LGE : Liquidity generation ongoing"
        );
        require(LGEFinished == false, "LGE : Liquidity generation finished");
        require(
            IERC20(WETH).balanceOf(address(this)) < 1 ether,
            "Too much WETH still left over in the contract"
        );
        require(MAGIC_MULTISIG != address(0), "MAGIC MUTISIG NOT SET");
        require(mMAGIC != address(0), "mMAGIC NOT SET");
        require(mDAI != address(0), "mDAI NOT SET");

        (
            uint256 MAGICValueETH,
            uint256 DAIValueETH
        ) = getDAIandMAGICReservesValueInETH();

        //If there is too much MAGIC we just take it from the top, no refunds in LGE3
        if (MAGICValueETH > DAIValueETH) {
            uint256 DELTA = MAGICValueETH - DAIValueETH;
            uint256 percentOfMAGICTooMuch = DELTA.mul(1e18).div(MAGICValueETH); // carry 1e18
            // Skim too much
            uint256 balanceMAGIC = IERC20(MAGIC).balanceOf(address(this));
            safeTransfer(
                MAGIC,
                MAGIC_MULTISIG,
                balanceMAGIC.mul(percentOfMAGICTooMuch).div(1e18)
            );
        }

        // Else DAI is bigger value, we just allow it to be 4% bigger max
        // We set max deviation from price of 4%
        require(
            MAGICValueETH.mul(104).div(100) > DAIValueETH,
            "Deviation from current price is too high"
        );

        // !!!!!!!!!!!
        //unlock wrapping
        IERC95(mMAGIC).unpauseTransfers();
        IERC95(mDAI).unpauseTransfers();
        //!!!!!!!!!

        // Optimistically get pair
        mDAIxmMAGICUniswapPair = IUniswapV2Factory(uniswapFactory).getPair(
            mMAGIC,
            mDAI
        );
        if (mDAIxmMAGICUniswapPair == address(0)) {
            // Pair doesn't exist yet
            // create pair returns address
            mDAIxmMAGICUniswapPair = IUniswapV2Factory(uniswapFactory)
                .createPair(mDAI, mMAGIC);
        }

        uint256 balanceMAGIC = IERC20(MAGIC).balanceOf(address(this));
        uint256 balanceDAI = IERC20(DAI).balanceOf(address(this));
        uint256 DEV_FEE = 1000;
        address MAGIC_MULTISIG = IMagicVault(magicGlobals.MAGICVaultAddress())
            .devaddr();
        uint256 devFeeMAGIC = balanceMAGIC.mul(DEV_FEE).div(10000);
        uint256 devFeeDAI = balanceDAI.mul(DEV_FEE).div(10000);

        // transfer dev fee
        safeTransfer(MAGIC, MAGIC_MULTISIG, devFeeMAGIC);
        safeTransfer(DAI, MAGIC_MULTISIG, devFeeDAI);

        // Wrap and send to uniswap pair
        safeTransfer(MAGIC, mMAGIC, balanceMAGIC.sub(devFeeMAGIC));
        safeTransfer(DAI, mDAI, balanceDAI.sub(devFeeDAI));
        IERC95(mMAGIC).wrapAtomic(mDAIxmMAGICUniswapPair);
        IERC95(mDAI).wrapAtomic(mDAIxmMAGICUniswapPair);

        require(
            IERC95(mDAI).balanceOf(mDAIxmMAGICUniswapPair) ==
                balanceDAI.sub(devFeeDAI),
            "Pair did not recieve enough DAI"
        );
        require(
            IERC95(mDAI).balanceOf(mDAIxmMAGICUniswapPair) > 1e24,
            "Pair did not recieve enough DAI"
        ); //1mln dai
        require(
            IERC95(mMAGIC).balanceOf(mDAIxmMAGICUniswapPair) ==
                balanceMAGIC.sub(devFeeMAGIC),
            "Pair did not recieve enough MAGIC"
        );
        require(
            IERC95(MAGIC).balanceOf(mDAIxmMAGICUniswapPair) > 300e18,
            "Pair did not recieve enough MAGIC"
        ); //300 magic

        // Mint tokens from uniswap pair
        IUniswapV2Pair pair = IUniswapV2Pair(mDAIxmMAGICUniswapPair); // mMAGIC/mDAI pair

        //we get lp tokens
        require(
            pair.totalSupply() == 0,
            "Somehow total supply is higher, sanity fail"
        );
        pair.mint(address(this));
        require(pair.totalSupply() > 0, "We didn't create tokens!");

        totalLPCreated = pair.balanceOf(address(this));
        LPPerMAGICUnitContributed = totalLPCreated.mul(1e18).div(
            totalMAGICUnitsContributed
        ); // Stored as 1e18 more for round erorrs and change
        require(
            LPPerMAGICUnitContributed > 0,
            "LP Per Unit Contribute Must be above Zero"
        );

        //Sync pair
        IMAGICTransferHandler(magicGlobals.TransferHandler()).sync(
            mDAIxmMAGICUniswapPair
        );

        LGEFinished = true;
    }

    //////////////////////////////////////////////
    //////////////////////////////////////////////
    //////////////////////////////////////////////
    /// Helper functions

    // If LGE doesn't trigger in 24h after its complete its possible to withdraw tokens
    // Because then we can assume something went wrong since LGE is a publically callable function
    // And otherwise everything is stuck.
    function safetyTokenWithdraw(address token) public onlyOwner {
        require(
            block.timestamp >
                contractStartTimestamp.add(LGEDurationDays).add(1 days)
        );
        IERC20(token).transfer(
            msg.sender,
            IERC20(token).balanceOf(address(this))
        );
    }

    function safetyETHWithdraw() public onlyOwner {
        require(
            block.timestamp >
                contractStartTimestamp.add(LGEDurationDays).add(1 days)
        );
        msg.sender.call.value(address(this).balance)("");
    }

    function setCDAI(address _mDAI) public onlyOwner {
        mDAI = _mDAI;
    }

    function setmMAGIC(address _mMAGIC) public onlyOwner {
        mMAGIC = _mMAGIC;
    }

    // Added safety function to extend LGE in case multisig #2 isn't avaiable from emergency life events
    // TODO x3 add your key here
    function extendLGE(uint256 numHours) public {
        require(
            msg.sender == 0x82810e81CAD10B8032D39758C8DBa3bA47Ad7092 ||
                msg.sender == 0xC91FE1ee441402D854B8F22F94Ddf66618169636 ||
                msg.sender == MAGIC_MULTISIG,
            "LGE: Requires admin"
        );
        require(numHours <= 24);
        LGEDurationDays = LGEDurationDays.add(numHours.mul(1 hours));
    }

    function pauseLGE() public {
        require(
            msg.sender == 0x82810e81CAD10B8032D39758C8DBa3bA47Ad7092 ||
                msg.sender == 0xC91FE1ee441402D854B8F22F94Ddf66618169636 ||
                msg.sender == MAGIC_MULTISIG,
            "LGE: Requires admin"
        );
        require(LGEPaused == false, "LGE : LGE Already paused");
        contractStartTimestampSaved = contractStartTimestamp;
        contractStartTimestamp = uint256(-1);
        LGEPaused = true;
    }

    function unpauseLGE() public {
        require(
            msg.sender == 0x82810e81CAD10B8032D39758C8DBa3bA47Ad7092 ||
                msg.sender == 0xC91FE1ee441402D854B8F22F94Ddf66618169636 ||
                msg.sender == MAGIC_MULTISIG,
            "LGE: Requires admin"
        );
        require(LGEPaused == true, "LGE : LGE isn't paused");
        uint256 pausedTime = block.timestamp.sub(contractStartTimestampSaved);
        contractStartTimestamp = contractStartTimestampSaved.add(pausedTime);
        LGEPaused = false;
    }

    // Note selling tokens doesn't need slippage protection usually
    // Because front run bots dont hold, usually
    // but maybe rekt
    function sellTokenForWETH(
        address _token,
        uint256 _amountTransfer,
        bool fromPerson
    ) internal returns (uint256 amountOut) {
        // we just sell on uni cause fuck you
        // console.log("Selling token", _token);
        require(_token != DAI, "No sell DAI");
        address pairWithWETH = IUniswapV2Factory(uniswapFactory).getPair(
            _token,
            WETH
        );
        require(pairWithWETH != address(0), "Unsupported shitcoin");
        // console.log("Got pair with shitcoin", pairWithWETH);
        // console.log("selling token for amount", _amountTransfer);

        IERC20 shitcoin = IERC20(_token);
        IUniswapV2Pair pair = IUniswapV2Pair(pairWithWETH);
        // check how much pair has
        uint256 balanceBefore = shitcoin.balanceOf(pairWithWETH); // can pumpthis, but fails later
        // Send all token to pair
        if (fromPerson) {
            safeTransferFrom(_token, msg.sender, pairWithWETH, _amountTransfer); // re
        } else {
            safeTransfer(_token, pairWithWETH, _amountTransfer);
        }
        // check how much it got
        uint256 balanceAfter = shitcoin.balanceOf(pairWithWETH);
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        // console.log("Reserve0",reserve0);
        // console.log("Reserve1",reserve1);

        uint256 DELTA = balanceAfter.sub(balanceBefore, "Fuqq");
        // console.log("Delta after send", DELTA);
        // Make a swaperoo
        if (pair.token0() == _token) {
            // weth is 1
            // in, reservein, reserveout
            amountOut = getAmountOut(DELTA, reserve0, reserve1);
            require(
                amountOut < reserve1.mul(30).div(100),
                "Too much slippage in selling"
            );
            pair.swap(0, amountOut, address(this), "");
        } else {
            // WETH is 0
            amountOut = getAmountOut(DELTA, reserve1, reserve0);
            pair.swap(amountOut, 0, address(this), "");
            require(
                amountOut < reserve0.mul(30).div(100),
                "Too much slippage in selling"
            );
        }
    }

    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LGE3: TRANSFER_FAILED"
        );
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LGE3: TRANSFER_FROM_FAILED"
        );
    }
}
