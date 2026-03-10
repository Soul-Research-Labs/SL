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
///         Usage: POOL=0x... EPOCH_MANAGER=0x... forge script scripts/VerifyDeployment.s.sol --rpc-url $RPC_URL
contract VerifyDeployment is Script {
    uint256 checks;
    uint256 passed;
    uint256 failed;

    function run() external {
        console2.log("=== Soul Privacy Stack — Post-Deploy Verification ===");
        console2.log("");

        address pool = _envAddressOr("POOL", address(0));
        address epochManager = _envAddressOr("EPOCH_MANAGER", address(0));
        address timelock = _envAddressOr("TIMELOCK", address(0));
        address verifier = _envAddressOr("VERIFIER", address(0));
        address compliance = _envAddressOr("COMPLIANCE", address(0));
        address expectedGovernance = _envAddressOr(
            "EXPECTED_GOVERNANCE",
            address(0)
        );
        address expectedGuardian = _envAddressOr(
            "EXPECTED_GUARDIAN",
            address(0)
        );
        uint256 expectedChainId = _envUintOr(
            "EXPECTED_CHAIN_ID",
            block.chainid
        );
        uint256 expectedAppId = _envUintOr("EXPECTED_APP_ID", 1);
        uint256 expectedDelay = _envUintOr("EXPECTED_DELAY", 2 days);

        if (pool != address(0))
            _verifyPool(
                pool,
                verifier,
                epochManager,
                expectedChainId,
                expectedAppId
            );
        if (epochManager != address(0)) _verifyEpochManager(epochManager, pool);
        if (timelock != address(0)) _verifyTimelock(timelock, expectedDelay);
        if (verifier != address(0)) _verifyVerifier(verifier);
        if (compliance != address(0)) _verifyCompliance(compliance);

        if (pool != address(0) && timelock != address(0)) {
            _verifyCrossLinks(pool, timelock);
        }

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

    // ── Env helpers ────────────────────────────────────

    function _envAddressOr(
        string memory key,
        address fallback_
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return fallback_;
        }
    }

    function _envUintOr(
        string memory key,
        uint256 fallback_
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 val) {
            return val;
        } catch {
            return fallback_;
        }
    }

    // ── Pool Checks ────────────────────────────────────

    function _verifyPool(
        address poolAddr,
        address verifier,
        address epochManager,
        uint256 expectedChainId,
        uint256 expectedAppId
    ) internal {
        console2.log("--- PrivacyPool ---");
        IPoolVerify pool = IPoolVerify(poolAddr);

        _check("Pool: verifier set", pool.verifier() != address(0));
        if (verifier != address(0)) {
            _check("Pool: verifier matches", pool.verifier() == verifier);
        }
        _check("Pool: epochManager set", pool.epochManager() != address(0));
        if (epochManager != address(0)) {
            _check(
                "Pool: epochManager matches",
                pool.epochManager() == epochManager
            );
        }
        _check(
            "Pool: domainChainId correct",
            pool.domainChainId() == expectedChainId
        );
        _check(
            "Pool: domainAppId correct",
            pool.domainAppId() == expectedAppId
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

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(poolAddr)
        }
        _check("Pool: has code", codeSize > 0);
    }

    // ── Epoch Manager Checks ───────────────────────────

    function _verifyEpochManager(
        address epochManagerAddr,
        address pool
    ) internal {
        console2.log("--- EpochManager ---");
        IEpochVerify em = IEpochVerify(epochManagerAddr);

        if (pool != address(0)) {
            _check("Epoch: pool authorized", em.authorizedPools(pool));
        }
        _check("Epoch: initial epoch = 0", em.currentEpochId() == 0);
        _check("Epoch: duration > 0", em.epochDuration() > 0);
    }

    // ── Timelock Checks ────────────────────────────────

    function _verifyTimelock(
        address timelockAddr,
        uint256 expectedDelay
    ) internal {
        console2.log("--- GovernanceTimelock ---");
        ITimelockVerify tl = ITimelockVerify(timelockAddr);

        _check("Timelock: admin set", tl.admin() != address(0));
        _check("Timelock: delay >= MINIMUM", tl.delay() >= tl.MINIMUM_DELAY());
        _check("Timelock: delay <= MAXIMUM", tl.delay() <= tl.MAXIMUM_DELAY());
        _check("Timelock: delay matches expected", tl.delay() == expectedDelay);
        _check(
            "Timelock: grace period = 14 days",
            tl.GRACE_PERIOD() == 14 days
        );
    }

    // ── Verifier Checks ────────────────────────────────

    function _verifyVerifier(address verifierAddr) internal {
        console2.log("--- ProofVerifier ---");
        IVerifierCheck v = IVerifierCheck(verifierAddr);

        string memory ps = v.provingSystem();
        bytes memory psBytes = bytes(ps);
        _check("Verifier: provingSystem not empty", psBytes.length > 0);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(verifierAddr)
        }
        _check("Verifier: has code", codeSize > 0);
    }

    // ── Compliance Checks ──────────────────────────────

    function _verifyCompliance(address complianceAddr) internal {
        console2.log("--- ComplianceOracle ---");
        IComplianceCheck c = IComplianceCheck(complianceAddr);

        _check("Compliance: governance set", c.governance() != address(0));
        _check("Compliance: policy version >= 1", c.policyVersion() >= 1);
    }

    // ── Cross-link Checks ──────────────────────────────

    function _verifyCrossLinks(
        address poolAddr,
        address timelockAddr
    ) internal {
        console2.log("--- Cross-Links ---");

        IPoolVerify pool = IPoolVerify(poolAddr);
        if (pool.governance() == timelockAddr) {
            ITimelockVerify tl = ITimelockVerify(timelockAddr);
            _check(
                "CrossLink: pool.governance = timelock",
                pool.governance() == timelockAddr
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
