pragma solidity ^0.6.0;

import "@openzeppelin/contracts/presets/ERC721PresetMinterPauserAutoId.sol";

contract MERLIN is ERC721PresetMinterPauserAutoId {
  constructor(string memory name, string memory symbol, string memory tokenURI)
      public
      ERC721PresetMinterPauserAutoId(
          name,
          symbol,
          tokenURI
      )
  {}
}
