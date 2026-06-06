// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * OptimPush — lane-aware webstack driver for optimum delivery utility.
 *
 * Codename: velvet relay / stack harmonizer
 * Remix deploy:
 *   1. Compiler: 0.8.26 (exact), optimizer 200 runs
 *   2. Deploy with NO constructor arguments
 *   3. Call activateFleet(true) when operators may push
 *   4. openLane(...) per route before relayPush
 *
 * Stores no arbitrary bytes on-chain; emits indexed receipts for offchain stacks.
 */

interface IOptimPushReceiver {
    function onOptimPushDelivery(
        bytes32 laneId,
        bytes32 payloadHash,
        address relayer,
        uint64 seq
    ) external;
}

library OptimPushPack {
    function laneKey(string memory slug, uint32 tier) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("OPS_LANE", slug, tier));
    }

    function receiptDigest(
        bytes32 laneId,
        bytes32 payloadHash,
        address sender,
        uint64 seq,
        uint64 stampedAt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(laneId, payloadHash, sender, seq, stampedAt));
    }

    function batchLeaf(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    function clampU32(uint256 v, uint32 lo, uint32 hi) internal pure returns (uint32) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return uint32(v);
    }
}

contract OptimPush {
    using OptimPushPack for bytes32;

    // --- errors ---
    error OPS_NotOwner();
    error OPS_NotPendingOwner();
    error OPS_NotOperator();
    error OPS_NotRelay();
    error OPS_NotCurator();
    error OPS_OwnerRenounced();
    error OPS_Paused();
    error OPS_FleetInactive();
    error OPS_Reentry();
    error OPS_ZeroAddress();
    error OPS_ZeroBytes32();
    error OPS_BadInput();
    error OPS_LaneExists();
    error OPS_LaneMissing();
    error OPS_LaneMuted();
    error OPS_LaneGap();
    error OPS_SchemaExists();
    error OPS_SchemaMissing();
    error OPS_ReceiptUsed();
    error OPS_BatchTooLarge();
    error OPS_BatchEmpty();
    error OPS_BatchMismatch();
    error OPS_SeqStale();
    error OPS_PermitExpired();
    error OPS_InvalidSignature();
    error OPS_QuotaExceeded();
    error OPS_PriorityLocked();
    error OPS_HookRejected();
    error OPS_SameValue();
    error OPS_StringTooLong();
    error OPS_BundleTooLarge();
    error OPS_BundleEmpty();
    error OPS_LaneDeprecatedErr();
    error OPS_DeprecatedLane();

