// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IPoolVerify {
    function verifier() external view returns (address);

    function epochManager() external view returns (address);

    function domainChainId() external view returns (uint256);

    function domainAppId() external view returns (uint256);

    function governance() external view returns (address);

    function paused() external view returns (bool);

    function guardian() external view returns (address);

    function getLatestRoot() external view returns (bytes32);

    function getNextLeafIndex() external view returns (uint256);

    function poolBalance() external view returns (uint256);
}

interface IEpochVerify {
    function authorizedPools(address) external view returns (bool);

    function currentEpochId() external view returns (uint256);

    function epochDuration() external view returns (uint256);
}

interface ITimelockVerify {
    function admin() external view returns (address);

    function delay() external view returns (uint256);

    function MINIMUM_DELAY() external view returns (uint256);

    function MAXIMUM_DELAY() external view returns (uint256);

    function GRACE_PERIOD() external view returns (uint256);
}

interface IVerifierCheck {
    function provingSystem() external view returns (string memory);
}

interface IComplianceCheck {
    function governance() external view returns (address);

    function policyVersion() external view returns (uint256);
}

/// @title VerifyDeployment — Post-deploy health checks for all contracts
/// @notice Run after deployment to validate all contracts are correctly configured.
///         Usage: forge script scripts/VerifyDeployment.s.sol --rpc-url $RPC_URL
contract VerifyDeployment is Script {
    // ── Set these before running ───────────────────────

    address constant POOL = address(0); // Replace with deployed address
    address constant EPOCH_MANAGER = address(0);
    address constant TIMELOCK = address(0);
    address constant VERIFIER = address(0);
    address constant COMPLIANCE = address(0);
    address constant EXPECTED_GOVERNANCE = address(0);
    address constant EXPECTED_GUARDIAN = address(0);
    uint256 constant EXPECTED_CHAIN_ID = 43114;
    uint256 constant EXPECTED_APP_ID = 1;
    uint256 constant EXPECTED_DELAY = 2 days;

    uint256 checks;
    uint256 passed;
    uint256 failed;

    function run() external {
        console2.log("=== Soul Privacy Stack — Post-Deploy Verification ===");
        console2.log("");

        if (POOL != address(0)) _verifyPool();
        if (EPOCH_MANAGER != address(0)) _verifyEpochManager();
        if (TIMELOCK != address(0)) _verifyTimelock();
        if (VERIFIER != address(0)) _verifyVerifier();
        if (COMPLIANCE != address(0)) _verifyCompliance();

        _verifyCrossLinks();

        console2.log("");
        console2.log("=== Results ===");
        console2.log("Total checks:", checks);
        console2.log("Passed:      ", passed);
        console2.log("Failed:      ", failed);

        if (failed > 0) {
            console2.log("");
            console2.log("!! DEPLOYMENT VERIFICATION FAILED !!");
        } else {
            console2.log("");
            console2.log("All checks passed.");
        }
    }

    // ── Pool Checks ────────────────────────────────────

    function _verifyPool() internal {
        console2.log("--- PrivacyPool ---");
        IPoolVerify pool = IPoolVerify(POOL);

        _check("Pool: verifier set", pool.verifier() != address(0));
        _check("Pool: verifier matches", pool.verifier() == VERIFIER);
        _check("Pool: epochManager set", pool.epochManager() != address(0));
        _check(
            "Pool: epochManager matches",
            pool.epochManager() == EPOCH_MANAGER
        );
        _check(
            "Pool: domainChainId correct",
            pool.domainChainId() == EXPECTED_CHAIN_ID
        );
        _check(
            "Pool: domainAppId correct",
            pool.domainAppId() == EXPECTED_APP_ID
        );
        _check("Pool: governance set", pool.governance() != address(0));
        _check("Pool: not paused", !pool.paused());
        _check("Pool: guardian set", pool.guardian() != address(0));
        _check(
            "Pool: merkle tree initialized",
            pool.getLatestRoot() != bytes32(0)
        );
        _check("Pool: leaf index = 0", pool.getNextLeafIndex() == 0);
        _check("Pool: balance = 0", pool.poolBalance() == 0);

        // Code size check
        uint256 codeSize;
        address poolAddr = POOL;
        assembly {
            codeSize := extcodesize(poolAddr)
        }
        _check("Pool: has code", codeSize > 0);
    }

    // ── Epoch Manager Checks ───────────────────────────

    function _verifyEpochManager() internal {
        console2.log("--- EpochManager ---");
        IEpochVerify em = IEpochVerify(EPOCH_MANAGER);

        _check("Epoch: pool authorized", em.authorizedPools(POOL));
        _check("Epoch: initial epoch = 0", em.currentEpochId() == 0);
        _check("Epoch: duration > 0", em.epochDuration() > 0);
    }

    // ── Timelock Checks ────────────────────────────────

    function _verifyTimelock() internal {
        console2.log("--- GovernanceTimelock ---");
        ITimelockVerify tl = ITimelockVerify(TIMELOCK);

        _check("Timelock: admin set", tl.admin() != address(0));
        _check("Timelock: delay >= MINIMUM", tl.delay() >= tl.MINIMUM_DELAY());
        _check("Timelock: delay <= MAXIMUM", tl.delay() <= tl.MAXIMUM_DELAY());
        _check(
            "Timelock: delay matches expected",
            tl.delay() == EXPECTED_DELAY
        );
        _check(
            "Timelock: grace period = 14 days",
            tl.GRACE_PERIOD() == 14 days
        );
    }

    // ── Verifier Checks ────────────────────────────────

    function _verifyVerifier() internal {
        console2.log("--- ProofVerifier ---");
        IVerifierCheck v = IVerifierCheck(VERIFIER);

        string memory ps = v.provingSystem();
        bytes memory psBytes = bytes(ps);
        _check("Verifier: provingSystem not empty", psBytes.length > 0);

        uint256 codeSize;
        address vAddr = VERIFIER;
        assembly {
            codeSize := extcodesize(vAddr)
        }
        _check("Verifier: has code", codeSize > 0);
    }

    // ── Compliance Checks ──────────────────────────────

    function _verifyCompliance() internal {
        console2.log("--- ComplianceOracle ---");
        IComplianceCheck c = IComplianceCheck(COMPLIANCE);

        _check("Compliance: governance set", c.governance() != address(0));
        _check("Compliance: policy version >= 1", c.policyVersion() >= 1);
    }

    // ── Cross-link Checks ──────────────────────────────

    function _verifyCrossLinks() internal {
        if (POOL == address(0) || TIMELOCK == address(0)) return;

        console2.log("--- Cross-Links ---");

        // If governance is the timelock, verify the chain
        IPoolVerify pool = IPoolVerify(POOL);
        if (pool.governance() == TIMELOCK) {
            ITimelockVerify tl = ITimelockVerify(TIMELOCK);
            _check(
                "CrossLink: pool.governance → timelock",
                pool.governance() == TIMELOCK
            );
            _check("CrossLink: timelock admin set", tl.admin() != address(0));
        }
    }

    // ── Assertion Helper ───────────────────────────────

    function _check(string memory label, bool condition) internal {
        checks++;
        if (condition) {
            passed++;
            console2.log(unicode"  ✓", label);
        } else {
            failed++;
            console2.log(unicode"  ✗ FAIL:", label);
        }
    }
}
