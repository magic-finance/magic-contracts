pragma solidity >=0.6.0;

import "./MERLIN.sol";

contract MerlinFactory {

    address[] public contracts;
    address public lastContractAddress;

    mapping(address => bool) public ownedContracts;

    event deployedMerlin (
        address indexed addr,
        string name,
        string indexed symbol,
        string tokenURI,
        address indexed LP
    );

    function getContractCount() public view returns(uint contractCount) {
      return contracts.length;
    }

    function deployMerlin(string memory name, string memory symbol, string memory tokenURI, address LP) internal returns(MERLIN newContract) {
      MERLIN c = new MERLIN(name, symbol, tokenURI, LP);
      address cAddr = address(c);
      contracts.push(cAddr);
      lastContractAddress = cAddr;

      ownedContracts[cAddr] = true;

      emit deployedMerlin(cAddr, name, symbol, tokenURI, LP);

      return c;
    }
    function mintMerlin(MERLIN _merlin, address recipient) internal {
      _merlin.mint(recipient);
    }
}
