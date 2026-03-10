// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RelayerFeeVault — Gas compensation for cross-chain relayers
/// @notice Allows users to deposit fees that relayers can claim after performing
///         epoch root relay operations. This incentivizes timely propagation of
///         nullifier roots across all chains.
///
/// @dev Fee flow:
///   1. Users/protocol top up the vault with native tokens (or can be funded
///      per-deposit from PrivacyPool)
///   2. Relayers submit relay proofs (tx hash + chain evidence)
///   3. Governance approves relay claims in batches
///   4. Relayers withdraw their earned fees
contract RelayerFeeVault {
    // ── Storage ────────────────────────────────────────

    address public governance;

    /// @notice Registered relayers eligible for fee claims.
    mapping(address => bool) public registeredRelayers;

    /// @notice Accumulated claimable balance per relayer.
    mapping(address => uint256) public claimableBalance;

    /// @notice Total relay operations recorded per relayer (for analytics).
    mapping(address => uint256) public relayCount;

    /// @notice Fee per relay operation (set by governance).
    uint256 public feePerRelay;

    /// @notice Maximum fee per relay (safety cap).
    uint256 public maxFeePerRelay;

    /// @notice Minimum stake required to register as a relayer.
    uint256 public minimumStake;

    /// @notice Staked amounts per relayer.
    mapping(address => uint256) public stakedAmount;

    /// @notice Whether a relay has already been claimed (tx hash → bool).
    mapping(bytes32 => bool) public relayProcessed;

    /// @notice Total vault balance available for distribution.
    uint256 public vaultBalance;

    // ── Events ─────────────────────────────────────────

    event RelayerRegistered(address indexed relayer, uint256 stake);
    event RelayerDeregistered(address indexed relayer, uint256 stakeReturned);
    event FeeDeposited(address indexed depositor, uint256 amount);
    event RelayCredited(
        address indexed relayer,
        bytes32 indexed relayHash,
        uint256 fee,
        uint64 sourceChainId,
        uint64 targetChainId,
        uint64 epochId
    );
    event FeesClaimed(address indexed relayer, uint256 amount);
    event FeePerRelayUpdated(uint256 newFee);
    event RelayerSlashed(
        address indexed relayer,
        uint256 amount,
        string reason
    );

    // ── Modifiers ──────────────────────────────────────

    modifier onlyGovernance() {
        require(msg.sender == governance, "FeeVault: not governance");
        _;
    }

    modifier onlyRegisteredRelayer() {
        require(registeredRelayers[msg.sender], "FeeVault: not registered");
        _;
    }

    // ── Constructor ────────────────────────────────────

    constructor(
        uint256 _feePerRelay,
        uint256 _maxFeePerRelay,
        uint256 _minimumStake
    ) {
        governance = msg.sender;
        feePerRelay = _feePerRelay;
        maxFeePerRelay = _maxFeePerRelay;
        minimumStake = _minimumStake;
    }

    // ── Relayer Registration ───────────────────────────

    /// @notice Register as a relayer by staking the minimum amount.
    function registerRelayer() external payable {
        require(
            !registeredRelayers[msg.sender],
            "FeeVault: already registered"
        );
        require(msg.value >= minimumStake, "FeeVault: insufficient stake");

        registeredRelayers[msg.sender] = true;
        stakedAmount[msg.sender] = msg.value;

        emit RelayerRegistered(msg.sender, msg.value);
    }

    /// @notice Deregister and withdraw stake (only if no pending claims).
    function deregisterRelayer() external onlyRegisteredRelayer {
        require(
            claimableBalance[msg.sender] == 0,
            "FeeVault: claim fees first"
        );

        registeredRelayers[msg.sender] = false;
        uint256 stake = stakedAmount[msg.sender];
        stakedAmount[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: stake}("");
        require(sent, "FeeVault: stake return failed");

        emit RelayerDeregistered(msg.sender, stake);
    }

    // ── Fee Deposits ───────────────────────────────────

    /// @notice Deposit fees into the vault (anyone can fund it).
    function depositFees() external payable {
        require(msg.value > 0, "FeeVault: zero deposit");
        vaultBalance += msg.value;
        emit FeeDeposited(msg.sender, msg.value);
    }

    /// @notice Receive native tokens directly.
    receive() external payable {
        vaultBalance += msg.value;
        emit FeeDeposited(msg.sender, msg.value);
    }

    // ── Relay Credit ───────────────────────────────────

    /// @notice Credit a relayer for completing a relay operation.
    /// @dev Called by governance (or an authorized contract) after verifying
    ///      that the relayer actually submitted the epoch root on the target chain.
    /// @param relayer The relayer address to credit.
    /// @param relayHash Unique hash identifying the relay (e.g., keccak256(sourceChain, targetChain, epochId)).
    /// @param sourceChainId Source chain ID of the relayed epoch.
    /// @param targetChainId Target chain ID where the root was submitted.
    /// @param epochId The epoch that was relayed.
    function creditRelay(
        address relayer,
        bytes32 relayHash,
        uint64 sourceChainId,
        uint64 targetChainId,
        uint64 epochId
    ) external onlyGovernance {
        require(
            registeredRelayers[relayer],
            "FeeVault: relayer not registered"
        );
        require(
            !relayProcessed[relayHash],
            "FeeVault: relay already processed"
        );
        require(
            feePerRelay <= vaultBalance,
            "FeeVault: insufficient vault balance"
        );

        relayProcessed[relayHash] = true;
        claimableBalance[relayer] += feePerRelay;
        relayCount[relayer]++;
        vaultBalance -= feePerRelay;

        emit RelayCredited(
            relayer,
            relayHash,
            feePerRelay,
            sourceChainId,
            targetChainId,
            epochId
        );
    }

    // ── Fee Claims ─────────────────────────────────────

    /// @notice Claim all accumulated fees.
    function claimFees() external onlyRegisteredRelayer {
        uint256 amount = claimableBalance[msg.sender];
        require(amount > 0, "FeeVault: nothing to claim");

        claimableBalance[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "FeeVault: transfer failed");

        emit FeesClaimed(msg.sender, amount);
    }

    // ── Governance ─────────────────────────────────────

    /// @notice Update the fee per relay operation.
    function setFeePerRelay(uint256 _feePerRelay) external onlyGovernance {
        require(_feePerRelay <= maxFeePerRelay, "FeeVault: exceeds max");
        feePerRelay = _feePerRelay;
        emit FeePerRelayUpdated(_feePerRelay);
    }

    /// @notice Slash a relayer's stake for misbehavior (e.g., submitting incorrect roots).
    function slashRelayer(
        address relayer,
        uint256 amount,
        string calldata reason
    ) external onlyGovernance {
        require(
            stakedAmount[relayer] >= amount,
            "FeeVault: slash exceeds stake"
        );
        stakedAmount[relayer] -= amount;

        // Slashed funds go to the vault for redistribution.
        vaultBalance += amount;

        // If stake falls below minimum, deregister.
        if (stakedAmount[relayer] < minimumStake) {
            registeredRelayers[relayer] = false;
        }

        emit RelayerSlashed(relayer, amount, reason);
    }

    /// @notice Transfer governance.
    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "FeeVault: zero address");
        governance = newGovernance;
    }

    // ── View Functions ─────────────────────────────────

    /// @notice Get total fees earned by a relayer.
    function getRelayerStats(
        address relayer
    )
        external
        view
        returns (
            bool registered,
            uint256 stake,
            uint256 pending,
            uint256 totalRelays
        )
    {
        return (
            registeredRelayers[relayer],
            stakedAmount[relayer],
            claimableBalance[relayer],
            relayCount[relayer]
        );
    }
}
