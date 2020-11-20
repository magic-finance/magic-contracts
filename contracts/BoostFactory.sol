pragma solidity >=0.6.0;

import "./BOOST.sol";

contract BoostFactory {

    address[] public contracts;
    address public lastContractAddress;

    mapping(address => bool) public ownedContracts;

    event deployedBoost (
        address indexed addr,
        string name,
        string indexed symbol,
        string tokenURI,
        address indexed LP
    );

    function getContractCount() public view returns(uint contractCount) {
      return contracts.length;
    }

    function deployBoost(string memory name, string memory symbol, string memory tokenURI, address LP) internal returns(BOOST newContract) {
      BOOST c = new BOOST(name, symbol, tokenURI, LP);
      address cAddr = address(c);
      contracts.push(cAddr);
      lastContractAddress = cAddr;

      ownedContracts[cAddr] = true;

      emit deployedBoost(cAddr, name, symbol, tokenURI, LP);

      return c;
    }
    function mintBoost(BOOST _boost, address recipient) internal {
      _boost.mint(recipient);
    }
}
