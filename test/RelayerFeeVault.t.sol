// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/RelayerFeeVault.sol";

contract RelayerFeeVaultTest is Test {
    RelayerFeeVault vault;
    address governance;
    address relayer1;
    address relayer2;

    uint256 constant FEE_PER_RELAY = 0.01 ether;
    uint256 constant MAX_FEE = 0.1 ether;
    uint256 constant MIN_STAKE = 1 ether;

    function setUp() public {
        governance = address(this);
        relayer1 = makeAddr("relayer1");
        relayer2 = makeAddr("relayer2");

        vault = new RelayerFeeVault(FEE_PER_RELAY, MAX_FEE, MIN_STAKE);

        // Fund test accounts
        vm.deal(relayer1, 10 ether);
        vm.deal(relayer2, 10 ether);
        vm.deal(governance, 100 ether);
    }

    // ── Registration ───────────────────────────────────

    function test_registerRelayer() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        assertTrue(vault.registeredRelayers(relayer1));
        assertEq(vault.stakedAmount(relayer1), MIN_STAKE);
    }

    function test_registerRelayer_insufficientStake() public {
        vm.prank(relayer1);
        vm.expectRevert("FeeVault: insufficient stake");
        vault.registerRelayer{value: 0.5 ether}();
    }

    function test_registerRelayer_alreadyRegistered() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vm.prank(relayer1);
        vm.expectRevert("FeeVault: already registered");
        vault.registerRelayer{value: MIN_STAKE}();
    }

    function test_deregisterRelayer() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        uint256 balBefore = relayer1.balance;
        vm.prank(relayer1);
        vault.deregisterRelayer();

        assertFalse(vault.registeredRelayers(relayer1));
        assertEq(relayer1.balance, balBefore + MIN_STAKE);
    }

    function test_deregister_withPendingClaims_reverts() public {
        // Register and fund vault
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        // Credit a relay
        bytes32 relayHash = keccak256("relay1");
        vault.creditRelay(relayer1, relayHash, 1, 2, 0);

        // Try to deregister with pending claims
        vm.prank(relayer1);
        vm.expectRevert("FeeVault: claim fees first");
        vault.deregisterRelayer();
    }

    // ── Fee Deposits ───────────────────────────────────

    function test_depositFees() public {
        vault.depositFees{value: 5 ether}();
        assertEq(vault.vaultBalance(), 5 ether);
    }

    function test_depositFees_zero_reverts() public {
        vm.expectRevert("FeeVault: zero deposit");
        vault.depositFees{value: 0}();
    }

    function test_receive_depositsFees() public {
        (bool ok, ) = address(vault).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(vault.vaultBalance(), 2 ether);
    }

    // ── Relay Credit ───────────────────────────────────

    function test_creditRelay() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        bytes32 relayHash = keccak256("relay1");
        vault.creditRelay(relayer1, relayHash, 43113, 1284, 5);

        assertEq(vault.claimableBalance(relayer1), FEE_PER_RELAY);
        assertEq(vault.relayCount(relayer1), 1);
        assertTrue(vault.relayProcessed(relayHash));
    }

    function test_creditRelay_duplicateHash_reverts() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        bytes32 relayHash = keccak256("relay1");
        vault.creditRelay(relayer1, relayHash, 1, 2, 0);

        vm.expectRevert("FeeVault: relay already processed");
        vault.creditRelay(relayer1, relayHash, 1, 2, 0);
    }

    function test_creditRelay_unregistered_reverts() public {
        vault.depositFees{value: 1 ether}();

        vm.expectRevert("FeeVault: relayer not registered");
        vault.creditRelay(relayer1, keccak256("r"), 1, 2, 0);
    }

    function test_creditRelay_insufficientVault_reverts() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        // No fee deposits — vault empty

        vm.expectRevert("FeeVault: insufficient vault balance");
        vault.creditRelay(relayer1, keccak256("r"), 1, 2, 0);
    }

    function test_creditRelay_onlyGovernance() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vm.prank(relayer1);
        vm.expectRevert("FeeVault: not governance");
        vault.creditRelay(relayer1, keccak256("r"), 1, 2, 0);
    }

    // ── Fee Claims ─────────────────────────────────────

    function test_claimFees() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        vault.creditRelay(relayer1, keccak256("r1"), 1, 2, 0);
        vault.creditRelay(relayer1, keccak256("r2"), 1, 2, 1);

        uint256 balBefore = relayer1.balance;
        vm.prank(relayer1);
        vault.claimFees();

        assertEq(relayer1.balance, balBefore + 2 * FEE_PER_RELAY);
        assertEq(vault.claimableBalance(relayer1), 0);
    }

    function test_claimFees_nothingToClaim_reverts() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vm.prank(relayer1);
        vm.expectRevert("FeeVault: nothing to claim");
        vault.claimFees();
    }

    // ── Governance ─────────────────────────────────────

    function test_setFeePerRelay() public {
        vault.setFeePerRelay(0.05 ether);
        assertEq(vault.feePerRelay(), 0.05 ether);
    }

    function test_setFeePerRelay_exceedsMax_reverts() public {
        vm.expectRevert("FeeVault: exceeds max");
        vault.setFeePerRelay(1 ether);
    }

    function test_slashRelayer() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vault.slashRelayer(relayer1, 0.5 ether, "submitted bad root");
        assertEq(vault.stakedAmount(relayer1), 0.5 ether);
        assertEq(vault.vaultBalance(), 0.5 ether);
    }

    function test_slashRelayer_fullSlash_deregisters() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vault.slashRelayer(relayer1, MIN_STAKE, "malicious");
        assertFalse(vault.registeredRelayers(relayer1));
    }

    function test_transferGovernance() public {
        address newGov = makeAddr("newGov");
        vault.transferGovernance(newGov);
        assertEq(vault.governance(), newGov);
    }

    function test_transferGovernance_toZero_reverts() public {
        vm.expectRevert("FeeVault: zero address");
        vault.transferGovernance(address(0));
    }

    // ── View Functions ─────────────────────────────────

    function test_getRelayerStats() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();
        vault.creditRelay(relayer1, keccak256("r1"), 1, 2, 0);

        (bool reg, uint256 stake, uint256 pending, uint256 relays) = vault
            .getRelayerStats(relayer1);

        assertTrue(reg);
        assertEq(stake, MIN_STAKE);
        assertEq(pending, FEE_PER_RELAY);
        assertEq(relays, 1);
    }
}
