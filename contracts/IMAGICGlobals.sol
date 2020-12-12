// SPDX-License-Identifier: MIT

interface IMAGICGlobals {
    function MAGICTokenAddress() external view returns (address);

    function MAGICGlobalsAddress() external view returns (address);

    function MAGICDelegatorAddress() external view returns (address);

    function MAGICVaultAddress() external returns (address);

    function MAGICWETHUniPair() external view returns (address);

    function UniswapFactory() external view returns (address);

    function TransferHandler() external view returns (address);

    function addDelegatorStateChangePermission(address that, bool status)
        external;

    function isStateChangeApprovedContract(address that)
        external
        view
        returns (bool);
}
