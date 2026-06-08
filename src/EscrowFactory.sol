// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IEscrowFactory} from "./interfaces/IEscrowFactory.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {Helpers} from "./lib/Helpers.sol";
import {Errors} from "./lib/Errors.sol";

contract EscrowFactory is IEscrowFactory, Initializable, AccessControlUpgradeable {
    /// @notice max fee 10%
    uint16 constant MAX_FEE = 1000;

    /// @notice The default fee rate.
    uint16 public defaultFeeRate;

    /// @notice The default grace period.
    uint32 public defaultGracePeriod;

    /// @notice The default arbitrator.
    address public defaultArbitrator;

    /// @notice Mapping to track whether a vault is active.
    mapping(address escrow => bool active) public activeEscrows;

    /// @notice Allowed tokens
    mapping(address token => bool allowed) public allowedTokens;

    /// @dev Address of the upgradeable beacon for escrow deployment.
    UpgradeableBeacon private _beaconProxyForEscrow;

    function initialize(
        uint16 defaultFeeRate_,
        uint32 defaultGracePeriod_,
        address defaultArbitrator_,
        address escrowImplementation
    ) external override initializer {
        Helpers.checkZeroAddress(escrowImplementation, "escrowImplementation");
        Helpers.checkZeroAddress(defaultArbitrator_, "defaultArbitrator");

        if (defaultFeeRate_ > MAX_FEE) revert Errors.DefaultFeeRateError();
        if (defaultGracePeriod_ > 30 days) revert Errors.DefaultGracePeriodError();

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        _beaconProxyForEscrow = new UpgradeableBeacon(escrowImplementation, address(this));

        defaultFeeRate = defaultFeeRate_;
        defaultGracePeriod = defaultGracePeriod_;
        defaultArbitrator = defaultArbitrator_;
    }

    /// @notice Sets a new default fee rate.
    /// @param defaultFeeRate_ The new default fee rate to be set.
    function setDefaultFeeRate(uint16 defaultFeeRate_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (defaultFeeRate_ > MAX_FEE) revert Errors.DefaultFeeRateError();

        defaultFeeRate = defaultFeeRate_;

        emit DefaultFeeRateSet(defaultFeeRate_);
    }

    /// @notice Sets a new default fee rate.
    /// @param defaultGracePeriod_ The new default grace period to be set.
    function setDefaultGracePeriod(uint32 defaultGracePeriod_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (defaultGracePeriod_ > 30 days) revert Errors.DefaultGracePeriodError();

        defaultGracePeriod = defaultGracePeriod_;

        emit DefaultGracePeriodSet(defaultGracePeriod_);
    }

    /// @notice Sets a new default fee rate.
    /// @param defaultArbitrator_ The new default arbitrator to be set.
    function setDefaultArbitrator(address defaultArbitrator_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        Helpers.checkZeroAddress(defaultArbitrator_, "defaultArbitrator");

        defaultArbitrator = defaultArbitrator_;

        emit DefaultArbitratorSet(defaultArbitrator_);
    }

    /// @notice Updates the escrow implementation in the beacon proxy.
    /// @param newImplementation_ The address of the new escrow implementation.
    function setEscrowImplementation(address newImplementation_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        Helpers.checkZeroAddress(newImplementation_, "newImplementation_");

        _beaconProxyForEscrow.upgradeTo(newImplementation_);

        emit EscrowImplementationChanged(newImplementation_);
    }

    /// @notice Activates or deactivates an escrow.
    /// @param escrowAddress_ The address of the escrow.
    /// @param status_ The new status of the vault (active or not).
    function setEscrowStatus(address escrowAddress_, bool status_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        Helpers.checkZeroAddress(escrowAddress_, "escrowAddress_");

        activeEscrows[escrowAddress_] = status_;

        emit EscrowStatusChanged(escrowAddress_, status_);
    }

    /// @notice Allows or disallows a token for newly deployed escrows.
    /// @param token_ The token address.
    /// @param allowed_ Whether the token is allowed.
    function setAllowedToken(address token_, bool allowed_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        Helpers.checkZeroAddress(token_, "token_");

        allowedTokens[token_] = allowed_;

        emit AllowedTokenSet(token_, allowed_);
    }

    function deployEscrow(IEscrow.InitParams calldata params) external override returns (address) {
        Helpers.checkZeroAddress(params.founder, "params.founder");
        Helpers.checkZeroAddress(params.token, "params.token");
        Helpers.checkZeroAddress(params.investor, "params.investor");
        Helpers.checkZeroAmount(params.totalAmount, "params.totalAmount");
        Helpers.validateMilestones(params);

        if (!allowedTokens[params.token]) revert Errors.TokenNotAllowed(params.token);

        address newEscrow = address(
            new BeaconProxy(
                address(_beaconProxyForEscrow),
                abi.encodeWithSelector(
                    IEscrow.initialize.selector,
                    params,
                    address(this), // factory
                    defaultFeeRate,
                    defaultGracePeriod,
                    defaultArbitrator
                )
            )
        );

        if (newEscrow == address(0)) revert Errors.FailedEscrowDeployment();

        activeEscrows[newEscrow] = true;

        emit EscrowDeployed(newEscrow);

        return newEscrow;
    }

    /// @notice Returns the address of the beacon proxy.
    function getBeaconProxyAddress() external view override returns (address) {
        return address(_beaconProxyForEscrow);
    }

    /// @notice Returns the current escrow implementation address.
    function getEscrowImplementationAddress() external view override returns (address) {
        return _beaconProxyForEscrow.implementation();
    }

    /// @notice Checks if an escrow is active.
    /// @param escrowAddress_ The address of the escrow.
    /// @return status True if the escrow is active, false otherwise.
    function isEscrowActive(address escrowAddress_) external view override returns (bool) {
        return activeEscrows[escrowAddress_];
    }
}
