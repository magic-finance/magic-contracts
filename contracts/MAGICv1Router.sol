pragma solidity 0.6.12;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@nomiclabs/buidler/console.sol";

import "./interfaces/IWETH9.sol";
import "./interfaces/IFeeApprover.sol";
// import "./uniswapv2/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './libraries/Math.sol';

import "./libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./IMagicVault.sol";

import "./MERLIN.sol";
import "./MerlinFactory.sol";


contract MAGICv1Router is Ownable {

    using SafeMath for uint256;
    mapping(address => uint256) public hardMAGIC;

    address public _magicToken;
    address public _magicWETHPair;
    IFeeApprover public _feeApprover;
    IMagicVault public _magicVault;
    IWETH public _WETH;
    address public _uniV2Factory;
    MerlinFactory public MerlinFactoryInstance;
    MERLIN public MerlinInstance;

    constructor(address magicToken, address WETH, address uniV2Factory, address magicWethPair, address feeApprover, address magicVault) public {
        _magicToken = magicToken;
        _WETH = IWETH(WETH);
        _uniV2Factory = uniV2Factory;
        _feeApprover = IFeeApprover(feeApprover);
        _magicWETHPair = magicWethPair;
        _magicVault = IMagicVault(magicVault);
        refreshApproval();
    }

    function refreshApproval() public {
        IUniswapV2Pair(_magicWETHPair).approve(address(_magicVault), uint(-1));
    }

    event FeeApproverChanged(address indexed newAddress, address indexed oldAddress);

    fallback() external payable {
        if(msg.sender != address(_WETH)){
             addLiquidityETHOnly(msg.sender, false);
        }
    }


    function addLiquidityETHOnly(address payable to, bool autoStake) public payable {
        require(to != address(0), "Invalid address");
        hardMAGIC[msg.sender] = hardMAGIC[msg.sender].add(msg.value);

        uint256 buyAmount = msg.value.div(2);
        require(buyAmount > 0, "Insufficient ETH amount");

        _WETH.deposit{value : msg.value}();

        (uint256 reserveWeth, uint256 reserveMagic) = getPairReserves();
        uint256 outMagic = UniswapV2Library.getAmountOut(buyAmount, reserveWeth, reserveMagic);

        _WETH.transfer(_magicWETHPair, buyAmount);

        (address token0, address token1) = UniswapV2Library.sortTokens(address(_WETH), _magicToken);
        IUniswapV2Pair(_magicWETHPair).swap(_magicToken == token0 ? outMagic : 0, _magicToken == token1 ? outMagic : 0, address(this), "");

        _addLiquidity(outMagic, buyAmount, to, autoStake);

        _feeApprover.sync();
    }

    function _addLiquidity(uint256 magicAmount, uint256 wethAmount, address payable to, bool autoStake) internal {
        require(address(MerlinFactoryInstance) != address(0));

        (uint256 wethReserve, uint256 magicReserve) = getPairReserves();

        uint256 optimalMagicAmount = UniswapV2Library.quote(wethAmount, wethReserve, magicReserve);

        uint256 optimalWETHAmount;
        if (optimalMagicAmount > magicAmount) {
            optimalWETHAmount = UniswapV2Library.quote(magicAmount, magicReserve, wethReserve);
            optimalMagicAmount = magicAmount;
        }
        else
            optimalWETHAmount = wethAmount;

        assert(_WETH.transfer(_magicWETHPair, optimalWETHAmount));
        assert(IERC20(_magicToken).transfer(_magicWETHPair, optimalMagicAmount));

        if (autoStake) {
            IUniswapV2Pair(_magicWETHPair).mint(address(this));
            _magicVault.depositFor(to, 0, IUniswapV2Pair(_magicWETHPair).balanceOf(address(this)));
        }
        else
            IUniswapV2Pair(_magicWETHPair).mint(to);


        //refund dust
        if (magicAmount > optimalMagicAmount)
            IERC20(_magicToken).transfer(to, magicAmount.sub(optimalMagicAmount));

        if (wethAmount > optimalWETHAmount) {
            uint256 withdrawAmount = wethAmount.sub(optimalWETHAmount);
            _WETH.withdraw(withdrawAmount);
            to.transfer(withdrawAmount);
        }

        // Send the funder a MERLIN
        MerlinFactoryInstance.mint(MerlinInstance, to);
    }

    function changeFeeApprover(address feeApprover) external onlyOwner {
        address oldAddress = address(_feeApprover);
        _feeApprover = IFeeApprover(feeApprover);

        emit FeeApproverChanged(feeApprover, oldAddress);
    }


    function getLPTokenPerEthUnit(uint ethAmt) public view  returns (uint liquidity){
        (uint256 reserveWeth, uint256 reserveMagic) = getPairReserves();
        uint256 outMagic = UniswapV2Library.getAmountOut(ethAmt.div(2), reserveWeth, reserveMagic);
        uint _totalSupply =  IUniswapV2Pair(_magicWETHPair).totalSupply();

        (address token0, ) = UniswapV2Library.sortTokens(address(_WETH), _magicToken);
        (uint256 amount0, uint256 amount1) = token0 == _magicToken ? (outMagic, ethAmt.div(2)) : (ethAmt.div(2), outMagic);
        (uint256 _reserve0, uint256 _reserve1) = token0 == _magicToken ? (reserveMagic, reserveWeth) : (reserveWeth, reserveMagic);
        liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);


    }

    function getPairReserves() internal view returns (uint256 wethReserves, uint256 magicReserves) {
        (address token0,) = UniswapV2Library.sortTokens(address(_WETH), _magicToken);
        (uint256 reserve0, uint reserve1,) = IUniswapV2Pair(_magicWETHPair).getReserves();
        (wethReserves, magicReserves) = token0 == _magicToken ? (reserve1, reserve0) : (reserve0, reserve1);
    }

    function setMerlinFactory(MerlinFactory _mf) public onlyOwner returns(bool) {
        MerlinFactoryInstance = _mf;
        MerlinInstance = MerlinFactoryInstance.deployMerlin("Merlin", "MERLIN", "merlin.eth");
        return true;
    }

    function getMerlin() public view returns (MERLIN) {
        return MerlinInstance;
    }

}
