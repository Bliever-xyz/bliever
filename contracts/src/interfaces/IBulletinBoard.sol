// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @notice A single on-chain clarification posted against an oracle question.
struct AncillaryDataUpdate {
    uint256 timestamp;
    bytes   update;
}

/// @title  IBulletinBoard
/// @notice Interface for the BulletinBoard mixin — on-chain ancillary data update registry.
interface IBulletinBoard {
    /// @notice Emitted whenever an update is posted for a question.
    /// @param questionID  The UMA oracle question identifier
    /// @param poster      Address that posted the update (anyone can post; weight by reputation)
    /// @param update      Raw bytes of the clarification / rule amendment
    event AncillaryDataUpdated(bytes32 indexed questionID, address indexed poster, bytes update);

    /// @notice Post an on-chain clarification for a question.
    ///         Any address may post. UMA DVM voters consider updates from the question creator.
    /// @param questionID  The question to update
    /// @param update      Clarification bytes (UTF-8 recommended)
    function postUpdate(bytes32 questionID, bytes memory update) external;

    /// @notice Retrieve all updates posted for a question by a specific owner.
    /// @param questionID  The question identifier
    /// @param owner       Address whose updates to fetch
    /// @return Array of AncillaryDataUpdate structs in posting order
    function getUpdates(bytes32 questionID, address owner) external view returns (AncillaryDataUpdate[] memory);

    /// @notice Retrieve only the most recent update posted for a question by a specific owner.
    /// @param questionID  The question identifier
    /// @param owner       Address whose updates to fetch
    /// @return The latest AncillaryDataUpdate (timestamp == 0 if none posted)
    function getLatestUpdate(bytes32 questionID, address owner) external view returns (AncillaryDataUpdate memory);
}
