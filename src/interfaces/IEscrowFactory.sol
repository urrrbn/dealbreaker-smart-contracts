// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEscrow} from "./IEscrow.sol";

interface IEscrowFactory {
    event DefaultFeeRateSet(uint16 defaultFeeRate);
    event DefaultGracePeriodSet(uint32 defaultGracePeriod);
    event DefaultArbitratorSet(address indexed defaultArbitrator);
    event EscrowImplementationChanged(address indexed newImplementation);
    event EscrowStatusChanged(address indexed escrowAddress, bool status);
    event AllowedTokenSet(address indexed token, bool allowed);
    event EscrowDeployed(address indexed escrow);


    function initialize(
        uint16 defaultFeeRate_,
        uint32 defaultGracePeriod_,
        address defaultArbitrator_,
        address escrowImplementation
    ) external;

    function setDefaultFeeRate(uint16 defaultFeeRate_) external;

    function setDefaultGracePeriod(uint32 defaultGracePeriod_) external;

    function setDefaultArbitrator(address defaultArbitrator_) external;

    function setEscrowImplementation(address newImplementation_) external;

    function setEscrowStatus(address escrowAddress_, bool status_) external;

    function setAllowedToken(address token_, bool allowed_) external;

    function deployEscrow(IEscrow.InitParams calldata params) external returns (address);

    function getBeaconProxyAddress() external view returns (address);

    function getEscrowImplementationAddress() external view returns (address);

    function isEscrowActive(address escrowAddress_) external view returns (bool);
}
