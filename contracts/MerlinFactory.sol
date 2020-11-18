pragma solidity ^0.6.0;

import "./MERLIN.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MerlinFactory is Ownable() {

    address[] public contracts;
    address public lastContractAddress;
    address public bondedContract;

    mapping(address => bool) public ownedContracts;

    event deployedMerlin (
        address indexed addr,
        string indexed name,
        string indexed symbol,
        string tokenURI
    );

    function bondContract(address _a) public onlyOwner returns(bool) {
        bondedContract = _a;
        return true;
    }

    function getContractCount() public view returns(uint contractCount) {
      return contracts.length;
    }

    function deployMerlin(string memory name, string memory symbol, string memory tokenURI) public returns(MERLIN newContract) {
      require(msg.sender == owner() || msg.sender == bondedContract, "Only the owner or bonded contract can deploy new MERLINs");

      MERLIN c = new MERLIN(name, symbol, tokenURI);
      address cAddr = address(c);
      contracts.push(cAddr);
      lastContractAddress = cAddr;

      ownedContracts[cAddr] = true;

      emit deployedMerlin(cAddr, name, symbol, tokenURI);

      return c;
    }
    function mint(MERLIN _merlin, address recipient) public {
      require(msg.sender == bondedContract, "Only the bonded contract can mint MERLINs");
      _merlin.mint(recipient);
    }
}
