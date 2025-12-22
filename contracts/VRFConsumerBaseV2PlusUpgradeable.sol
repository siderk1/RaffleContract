// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {IVRFMigratableConsumerV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFMigratableConsumerV2Plus.sol";

abstract contract VRFConsumerBaseV2PlusUpgradeable is
    Initializable,
    OwnableUpgradeable,
    IVRFMigratableConsumerV2Plus
{
    error OnlyCoordinatorCanFulfill(address have, address want);
    error OnlyOwnerOrCoordinator(
        address have,
        address owner,
        address coordinator
    );
    error ZeroAddress();

    IVRFCoordinatorV2Plus public s_vrfCoordinator;

    function __VRFConsumerBaseV2PlusUpgradeable_init(
        address _vrfCoordinator
    ) internal onlyInitializing {
        if (_vrfCoordinator == address(0)) revert ZeroAddress();
        __Ownable_init(msg.sender);
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        emit CoordinatorSet(_vrfCoordinator);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal virtual;

    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        if (msg.sender != address(s_vrfCoordinator)) {
            revert OnlyCoordinatorCanFulfill(
                msg.sender,
                address(s_vrfCoordinator)
            );
        }
        fulfillRandomWords(requestId, randomWords);
    }

    function setCoordinator(
        address _vrfCoordinator
    ) external override onlyOwnerOrCoordinator {
        if (_vrfCoordinator == address(0)) revert ZeroAddress();
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        emit CoordinatorSet(_vrfCoordinator);
    }

    modifier onlyOwnerOrCoordinator() {
        if (msg.sender != owner() && msg.sender != address(s_vrfCoordinator)) {
            revert OnlyOwnerOrCoordinator(
                msg.sender,
                owner(),
                address(s_vrfCoordinator)
            );
        }
        _;
    }
}
