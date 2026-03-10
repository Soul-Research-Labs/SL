// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EmergencyPause — Circuit-breaker module for privacy pool contracts
/// @notice Provides emergency pause/unpause capabilities with role-based
///         access control. Can be mixed into any contract via inheritance.
///         Supports a guardian role for immediate pause and a governance role
///         for unpause (preventing a single compromised key from permanently
///         freezing the system).
///
/// @dev Usage:
///   contract PrivacyPool is EmergencyPause { ... }
///   function deposit(...) external whenNotPaused { ... }
abstract contract EmergencyPause {
    // ── State ──────────────────────────────────────────

    /// @notice Whether the contract is currently paused
    bool public paused;

    /// @notice Guardian address — can pause immediately (e.g., a multisig or automated monitor)
    address public guardian;

    /// @notice Timestamp of the last pause action
    uint256 public lastPauseTime;

    /// @notice Total number of times the contract has been paused
    uint256 public pauseCount;

    /// @notice Maximum pause duration (seconds). After this, anyone can unpause.
    ///         Prevents a compromised guardian from permanently freezing the contract.
    uint256 public constant MAX_PAUSE_DURATION = 7 days;

    // ── Events ─────────────────────────────────────────

    event Paused(address indexed by, string reason);
    event Unpaused(address indexed by);
    event GuardianUpdated(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    // ── Errors ─────────────────────────────────────────

    error ContractPaused();
    error ContractNotPaused();
    error NotGuardianOrGovernance();
    error NotGovernance();

    // ── Modifiers ──────────────────────────────────────

    /// @notice Reverts if the contract is paused.
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /// @notice Reverts if the contract is NOT paused.
    modifier whenPaused() {
        if (!paused) revert ContractNotPaused();
        _;
    }

    // ── Internal Init ──────────────────────────────────

    /// @dev Call in the child constructor.
    function _initPause(address _guardian) internal {
        guardian = _guardian;
    }

    // ── Pause / Unpause ────────────────────────────────

    /// @notice Pause the contract. Callable by the guardian or governance.
    /// @param reason Human-readable reason for the pause (emitted in event).
    function pause(string calldata reason) external {
        if (msg.sender != guardian && msg.sender != _pauseGovernance())
            revert NotGuardianOrGovernance();
        if (paused) revert ContractPaused();

        paused = true;
        lastPauseTime = block.timestamp;
        pauseCount++;

        emit Paused(msg.sender, reason);
    }

    /// @notice Unpause the contract. Only callable by governance.
    ///         This asymmetry (guardian can pause, only governance can unpause)
    ///         prevents a compromised guardian from griefing the system.
    function unpause() external {
        if (!paused) revert ContractNotPaused();

        // Governance can always unpause
        // Anyone can unpause after MAX_PAUSE_DURATION expires (safety valve)
        if (msg.sender != _pauseGovernance()) {
            if (block.timestamp < lastPauseTime + MAX_PAUSE_DURATION)
                revert NotGovernance();
        }

        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Update the guardian address. Only callable by governance.
    function setGuardian(address _newGuardian) external {
        if (msg.sender != _pauseGovernance()) revert NotGovernance();
        emit GuardianUpdated(guardian, _newGuardian);
        guardian = _newGuardian;
    }

    // ── Internal Hook ──────────────────────────────────

    /// @dev Override in the child contract to return the governance address.
    ///      This avoids duplicating governance storage in the pause module.
    function _pauseGovernance() internal view virtual returns (address);
}
