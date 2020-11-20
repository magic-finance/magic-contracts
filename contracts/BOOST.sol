pragma solidity >=0.6.0;

import "@openzeppelin/contracts/presets/ERC721PresetMinterPauserAutoId.sol";

contract BOOST is ERC721PresetMinterPauserAutoId {

  // The LGE that generated this MERLIN
  address public LP;

  constructor(string memory name, string memory symbol, string memory tokenURI, address _LP)
      public
      ERC721PresetMinterPauserAutoId(
          name,
          symbol,
          tokenURI
      )
  {
    LP = _LP;
  }

  function getLP() public view returns (address) {
      return LP;
  }
}
