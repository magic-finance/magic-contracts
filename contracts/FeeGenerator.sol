pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";


// Contract that sends tokens it gets to itself
// Making it generate fees with fee on transfer tokens
contract FeeGenerator {

    function transferToSelf(address tokenAddress, uint256 loopCount) public {
         for (uint256 counter = 0; counter < loopCount; ++counter) {
            IBEP20(tokenAddress).transfer(address(this), IBEP20(tokenAddress).balanceOf(address(this)));
        }
    }

}
