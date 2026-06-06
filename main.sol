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

    // --- events ---
    event OPS_OwnerProposed(address indexed current, address indexed pending);
    event OPS_OwnerAccepted(address indexed previous, address indexed current);
    event OPS_OwnershipRenounced(address indexed former);
    event OPS_PauseSet(bool paused);
    event OPS_FleetActivated(bool active);
    event OPS_OperatorSet(address indexed operator, bool enabled);
    event OPS_RelaySet(address indexed relay, bool enabled);
    event OPS_CuratorSet(address indexed curator, bool enabled);
    event OPS_LaneOpened(
        bytes32 indexed laneId,
        string slug,
        uint8 priority,
        uint32 minGapBlocks,
        uint32 ttlBlocks
    );
    event OPS_LaneTuned(bytes32 indexed laneId, uint32 minGapBlocks, uint32 ttlBlocks);
    event OPS_LaneMuted(bytes32 indexed laneId, bool muted);
    event OPS_LanePrioritySet(bytes32 indexed laneId, uint8 priority);
    event OPS_SchemaRegistered(bytes32 indexed schemaId, bytes32 fingerprint, address indexed author);
    event OPS_SchemaRevoked(bytes32 indexed schemaId);
    event OPS_PushSingle(
        bytes32 indexed laneId,
        address indexed sender,
        bytes32 indexed payloadHash,
        bytes32 receiptId,
        uint64 seq,
        uint64 stampedAt,
        bytes6 tag
    );
    event OPS_PushBatch(
        bytes32 indexed laneId,
        address indexed sender,
        bytes32 batchRoot,
        uint16 count,
        uint64 seq,
        uint64 stampedAt
    );
    event OPS_RelayDelivered(
        bytes32 indexed laneId,
        address indexed relay,
        bytes32 payloadHash,
        bytes32 receiptId,
        uint64 seq
    );
    event OPS_QuotaBurned(address indexed actor, bytes32 indexed laneId, uint32 amount);
    event OPS_MetricsSnapshot(uint64 globalSeq, uint32 openLanes, uint32 liveSchemas);
    event OPS_SchemaBundleRegistered(bytes32 indexed bundleId, uint16 count);
    event OPS_LaneDeprecated(bytes32 indexed laneId, address indexed curator);
    event OPS_FleetProbe(address indexed caller, uint32 liveLanes, uint32 mutedLanes, bool healthy);
    event OPS_OperatorBulkSet(uint16 count, bool enabled);
    event OPS_MultiLanePush(bytes32 indexed rootLane, uint16 laneCount, uint64 seq);

    // --- constants ---
    uint256 public constant OPS_MAX_BATCH = 47;
    uint256 public constant OPS_MAX_SLUG_LEN = 64;
    uint256 public constant OPS_MAX_TAG_LEN = 6;
    uint256 public constant OPS_MAX_OPEN_LANES = 512;
    uint256 public constant OPS_MAX_SCHEMAS = 1024;
    uint256 public constant OPS_DEFAULT_TTL = 2_500_000;
    uint256 public constant OPS_DEFAULT_GAP = 0;
    uint256 public constant OPS_QUOTA_WINDOW = 86_400;
    uint256 public constant OPS_QUOTA_CAP = 4096;
    bytes32 public constant OPS_DOMAIN_MAGIC =
        0x2391d26dd164d246ca4d971ab6dba24df28656d803b1afee662797a4c20500fd;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant PUSH_ATTEST_TYPEHASH =
        keccak256(
            "PushAttest(bytes32 laneId,bytes32 payloadHash,uint64 seq,uint64 deadline,bytes6 tag)"
        );
    bytes32 private constant RELAY_ATTEST_TYPEHASH =
        keccak256(
            "RelayAttest(bytes32 laneId,bytes32 payloadHash,address relayer,uint64 seq,uint64 deadline)"
        );

    // --- immutables ---
    address public immutable STACK_RELAY_BOOT;
    address public immutable EDGE_PROBE_ANCHOR;
    address public immutable ORACLE_TAP_ANCHOR;
    address public immutable MIRROR_GUARD_BOOT;
    bytes32 public immutable CDN_MIRROR_SEED;
    bytes32 public immutable WARMUP_VECTOR_SEED;
    bytes32 public immutable GENESIS_PUSH_DIGEST;
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 public immutable DEPLOYED_AT_BLOCK;
    uint64 public immutable DEPLOYED_AT_TIME;

    // --- access state ---
    address public owner;
