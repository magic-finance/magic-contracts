pragma solidity 0.6.12;



import "./IFeeApprover.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

/// Please do not use this contract until its done, and tested.
/// Undefined behaviour might happen.
/// This code is shared/provided WITHOUT any warranties of any kind.

/// This contract is supposed to streamline liquidity additions
// By allowing people to put in any amount of ETH or MAGIC and get LP tokens back
contract MAGICv1Router is OwnableUpgradeSafe {
    IFeeApprover public _feeApprover;
    mapping (address => bool) public magicChosen;

    /// Route 1 : Buy LP for ETH
    /// Route 2 : Buy LP for MAGIC

    // Function sell Magic for ETH

    // Function wrap ETH

    // Function get price of MAGIC after sell

    // Function get amount of MAGIC with a ETH buy

    // Function get MAGIC needed to pair per ETH

    // Function sync fee approver
    function sync() public {
        _feeApprover.updateTxState();
    }

    // sets fee approver in case fee approver gets chaned.
    function setFeeApprover(address feeApproverAddress) onlyOwner public{
        _feeApprover = IFeeApprover(feeApproverAddress);
    }

}
