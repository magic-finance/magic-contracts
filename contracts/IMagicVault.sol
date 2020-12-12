pragma solidity ^0.6.0;

interface IMagicVault {
    function devaddr() external returns (address);

    function addPendingRewards(uint256 _amount) external;

    function depositFor(
        address _depositFor,
        uint256 _pid,
        uint256 _amount
    ) external;
}
