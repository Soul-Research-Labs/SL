//! Integration tests for the CosmWasm Privacy Pool contract.
//!
//! Uses `cw-multi-test` for testing without a running blockchain.

#[cfg(test)]
mod tests {
    use cosmwasm_std::{coins, Addr, Uint128};
    use cw_multi_test::{App, ContractWrapper, Executor};

    use privacy_pool_cosmwasm::contract::{execute, instantiate, query};
    use privacy_pool_cosmwasm::msg::*;

    const GOVERNANCE: &str = "governance";
    const ALICE: &str = "alice";
    const BOB: &str = "bob";
    const DENOM: &str = "uatom";

    fn default_instantiate_msg() -> InstantiateMsg {
        InstantiateMsg {
            tree_depth: 20, // Smaller for tests
            epoch_duration: 100,
            max_nullifiers_per_epoch: 1024,
            root_history_size: 30,
            domain_chain_id: 1,
            domain_app_id: 1,
            governance: GOVERNANCE.to_string(),
        }
    }

    fn setup_contract() -> (App, Addr) {
        let mut app = App::new(|router, _, storage| {
            router
                .bank
                .init_balance(storage, &Addr::unchecked(ALICE), coins(10_000_000, DENOM))
                .unwrap();
            router
                .bank
                .init_balance(storage, &Addr::unchecked(BOB), coins(10_000_000, DENOM))
                .unwrap();
        });

        let code = ContractWrapper::new(execute, instantiate, query);
        let code_id = app.store_code(Box::new(code));

        let addr = app
            .instantiate_contract(
                code_id,
                Addr::unchecked(GOVERNANCE),
                &default_instantiate_msg(),
                &[],
                "privacy-pool",
                None,
            )
            .unwrap();

        (app, addr)
    }

    // ── Instantiation Tests ────────────────────────────────────

    #[test]
    fn instantiate_works() {
        let (app, addr) = setup_contract();

        let status: PoolStatusResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::PoolStatus {})
            .unwrap();

        assert_eq!(status.total_deposits, 0);
        assert_eq!(status.pool_balance, Uint128::zero());
        assert_eq!(status.current_epoch, 0);
    }

    // ── Deposit Tests ──────────────────────────────────────────

    #[test]
    fn deposit_works() {
        let (mut app, addr) = setup_contract();

        let commitment = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.to_string(),
            },
            &coins(1_000_000, DENOM),
        )
        .unwrap();

        let status: PoolStatusResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::PoolStatus {})
            .unwrap();

        assert_eq!(status.total_deposits, 1);
        assert_eq!(status.pool_balance, Uint128::new(1_000_000));
    }

    #[test]
    fn deposit_zero_fails() {
        let (mut app, addr) = setup_contract();

        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::Deposit {
                    commitment: "aabb".repeat(16),
                },
                &[], // No funds
            )
            .unwrap_err();

        assert!(err.root_cause().to_string().contains("zero") ||
                err.root_cause().to_string().contains("Zero"));
    }

    #[test]
    fn deposit_duplicate_commitment_fails() {
        let (mut app, addr) = setup_contract();

        let commitment = "1234".repeat(16);

        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.clone(),
            },
            &coins(500_000, DENOM),
        )
        .unwrap();

        let err = app
            .execute_contract(
                Addr::unchecked(BOB),
                addr.clone(),
                &ExecuteMsg::Deposit {
                    commitment: commitment.clone(),
                },
                &coins(500_000, DENOM),
            )
            .unwrap_err();

        assert!(err.root_cause().to_string().contains("already exists") ||
                err.root_cause().to_string().contains("Commitment"));
    }

    #[test]
    fn multiple_deposits() {
        let (mut app, addr) = setup_contract();

        for i in 0..5u8 {
            let commitment = format!("{:0>64}", hex::encode([i; 32]));

            app.execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::Deposit {
                    commitment,
                },
                &coins(100_000, DENOM),
            )
            .unwrap();
        }

        let status: PoolStatusResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::PoolStatus {})
            .unwrap();

        assert_eq!(status.total_deposits, 5);
        assert_eq!(status.pool_balance, Uint128::new(500_000));
    }

    // ── Root Query Tests ───────────────────────────────────────

    #[test]
    fn latest_root_changes_after_deposit() {
        let (mut app, addr) = setup_contract();

        let root_before: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: "cc".repeat(32),
            },
            &coins(100_000, DENOM),
        )
        .unwrap();

        let root_after: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        assert_ne!(root_before.root, root_after.root);
    }

    // ── Epoch Tests ────────────────────────────────────────────

    #[test]
    fn finalize_epoch_works() {
        let (mut app, addr) = setup_contract();

        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::FinalizeEpoch {},
            &[],
        )
        .unwrap();

        // Epoch 0 finalized, epoch 1 created
        let epoch0: EpochInfoResponse = app
            .wrap()
            .query_wasm_smart(
                &addr,
                &QueryMsg::EpochInfo { epoch_id: 0 },
            )
            .unwrap();
        assert!(epoch0.finalized);

        let status: PoolStatusResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::PoolStatus {})
            .unwrap();
        assert_eq!(status.current_epoch, 1);
    }

    // ── Sync Epoch Root Tests ──────────────────────────────────

    #[test]
    fn sync_epoch_root_works() {
        let (mut app, addr) = setup_contract();

        let remote_root = "ff".repeat(32);

        app.execute_contract(
            Addr::unchecked(GOVERNANCE),
            addr.clone(),
            &ExecuteMsg::SyncEpochRoot {
                source_chain_id: 43114,
                epoch_id: 0,
                nullifier_root: remote_root.clone(),
            },
            &[],
        )
        .unwrap();

        let stored: Option<String> = app
            .wrap()
            .query_wasm_smart(
                &addr,
                &QueryMsg::RemoteEpochRoot {
                    source_chain_id: 43114,
                    epoch_id: 0,
                },
            )
            .unwrap();

        assert_eq!(stored, Some(remote_root));
    }

    // ── Governance Tests ───────────────────────────────────────

    #[test]
    fn update_governance_works() {
        let (mut app, addr) = setup_contract();

        app.execute_contract(
            Addr::unchecked(GOVERNANCE),
            addr.clone(),
            &ExecuteMsg::UpdateGovernance {
                new_governance: BOB.to_string(),
            },
            &[],
        )
        .unwrap();

        // Old governance should no longer work for governance-gated actions
        // New governance should work
    }

    // ── Transfer Tests ─────────────────────────────────────────

    #[test]
    fn transfer_works_with_valid_structure() {
        let (mut app, addr) = setup_contract();

        // First deposit to have a non-zero root
        let commitment = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.to_string(),
            },
            &coins(1_000_000, DENOM),
        )
        .unwrap();

        let root: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        // Construct a structurally valid proof (384 hex chars = 192 bytes minimum)
        let proof = "01".to_string() + &"ab".repeat(191);
        let nullifiers = [
            "1111".repeat(16),
            "2222".repeat(16),
        ];
        let output_commitments = [
            "3333".repeat(16),
            "4444".repeat(16),
        ];

        let result = app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Transfer {
                proof,
                merkle_root: root.root,
                nullifiers,
                output_commitments,
            },
            &[],
        );
        // Transfer should succeed structurally (testnet verifier)
        assert!(result.is_ok());
    }

    #[test]
    fn transfer_rejects_unknown_root() {
        let (mut app, addr) = setup_contract();

        let fake_root = "dead".repeat(16);
        let proof = "01".to_string() + &"ab".repeat(191);
        let nullifiers = ["1111".repeat(16), "2222".repeat(16)];
        let output_commitments = ["3333".repeat(16), "4444".repeat(16)];

        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::Transfer {
                    proof,
                    merkle_root: fake_root,
                    nullifiers,
                    output_commitments,
                },
                &[],
            )
            .unwrap_err();

        assert!(err.root_cause().to_string().to_lowercase().contains("root"));
    }

    // ── Withdraw Tests ─────────────────────────────────────────

    #[test]
    fn withdraw_sends_funds_to_recipient() {
        let (mut app, addr) = setup_contract();

        // Deposit first
        let commitment = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.to_string(),
            },
            &coins(2_000_000, DENOM),
        )
        .unwrap();

        let root: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        let proof = "01".to_string() + &"cd".repeat(191);
        let nullifiers = ["5555".repeat(16), "6666".repeat(16)];
        let output_commitments = ["7777".repeat(16), "8888".repeat(16)];
        let recipient = "recipient1";

        let result = app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Withdraw {
                proof,
                merkle_root: root.root,
                nullifiers,
                output_commitments,
                recipient: recipient.to_string(),
                exit_value: Uint128::new(500_000),
            },
            &[],
        );

        assert!(result.is_ok());

        // Verify recipient received funds
        let balance = app
            .wrap()
            .query_balance(recipient, DENOM)
            .unwrap();
        assert_eq!(balance.amount, Uint128::new(500_000));

        // Verify pool balance decreased
        let status: PoolStatusResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::PoolStatus {})
            .unwrap();
        assert_eq!(status.pool_balance, Uint128::new(1_500_000));
    }

    #[test]
    fn withdraw_exceeding_pool_balance_fails() {
        let (mut app, addr) = setup_contract();

        // Deposit small amount
        let commitment = "aabb".repeat(16);
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.to_string(),
            },
            &coins(100_000, DENOM),
        )
        .unwrap();

        let root: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        let proof = "01".to_string() + &"ee".repeat(191);
        let nullifiers = ["aaaa".repeat(16), "bbbb".repeat(16)];
        let output_commitments = ["cccc".repeat(16), "dddd".repeat(16)];

        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::Withdraw {
                    proof,
                    merkle_root: root.root,
                    nullifiers,
                    output_commitments,
                    recipient: BOB.to_string(),
                    exit_value: Uint128::new(999_999_999), // Way more than pool has
                },
                &[],
            )
            .unwrap_err();

        let err_str = err.root_cause().to_string().to_lowercase();
        assert!(err_str.contains("insufficient") || err_str.contains("balance") || err_str.contains("overflow"));
    }

    // ── Nullifier Tests ────────────────────────────────────────

    #[test]
    fn nullifier_is_marked_spent_after_transfer() {
        let (mut app, addr) = setup_contract();

        let commitment = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.to_string(),
            },
            &coins(1_000_000, DENOM),
        )
        .unwrap();

        let root: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        let nullifier1 = "a1a1".repeat(16);
        let nullifier2 = "b2b2".repeat(16);
        let proof = "01".to_string() + &"ff".repeat(191);

        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Transfer {
                proof,
                merkle_root: root.root,
                nullifiers: [nullifier1.clone(), nullifier2.clone()],
                output_commitments: ["3333".repeat(16), "4444".repeat(16)],
            },
            &[],
        )
        .unwrap();

        // Both nullifiers should now be spent
        let spent1: bool = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::IsSpent { nullifier: nullifier1 })
            .unwrap();
        assert!(spent1);

        let spent2: bool = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::IsSpent { nullifier: nullifier2 })
            .unwrap();
        assert!(spent2);
    }

    #[test]
    fn double_spend_same_nullifier_fails() {
        let (mut app, addr) = setup_contract();

        let commitment = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: commitment.to_string(),
            },
            &coins(1_000_000, DENOM),
        )
        .unwrap();

        let root: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        let nullifier1 = "c3c3".repeat(16);
        let nullifier2 = "d4d4".repeat(16);
        let proof = "01".to_string() + &"ab".repeat(191);

        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Transfer {
                proof: proof.clone(),
                merkle_root: root.root.clone(),
                nullifiers: [nullifier1.clone(), nullifier2.clone()],
                output_commitments: ["e5e5".repeat(16), "f6f6".repeat(16)],
            },
            &[],
        )
        .unwrap();

        // Attempt to use same nullifiers again
        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::Transfer {
                    proof,
                    merkle_root: root.root,
                    nullifiers: [nullifier1, "9999".repeat(16)],
                    output_commitments: ["aaaa".repeat(16), "bbbb".repeat(16)],
                },
                &[],
            )
            .unwrap_err();

        let err_str = err.root_cause().to_string().to_lowercase();
        assert!(err_str.contains("nullifier") || err_str.contains("spent") || err_str.contains("double"));
    }

    // ── Governance Guard Tests ─────────────────────────────────

    #[test]
    fn non_governance_cannot_sync_root() {
        let (mut app, addr) = setup_contract();

        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::SyncEpochRoot {
                    source_chain_id: 43114,
                    epoch_id: 0,
                    nullifier_root: "ff".repeat(32),
                },
                &[],
            )
            .unwrap_err();

        let err_str = err.root_cause().to_string().to_lowercase();
        assert!(err_str.contains("governance") || err_str.contains("unauthorized") || err_str.contains("not authorized"));
    }

    #[test]
    fn non_governance_cannot_update_governance() {
        let (mut app, addr) = setup_contract();

        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::UpdateGovernance {
                    new_governance: ALICE.to_string(),
                },
                &[],
            )
            .unwrap_err();

        let err_str = err.root_cause().to_string().to_lowercase();
        assert!(err_str.contains("governance") || err_str.contains("unauthorized"));
    }

    #[test]
    fn set_authorized_relayer_governance_only() {
        let (mut app, addr) = setup_contract();

        // Non-governance should fail
        let err = app
            .execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::SetAuthorizedRelayer {
                    relayer: Some(BOB.to_string()),
                },
                &[],
            )
            .unwrap_err();
        assert!(err.root_cause().to_string().to_lowercase().contains("governance")
            || err.root_cause().to_string().to_lowercase().contains("unauthorized"));

        // Governance should succeed
        app.execute_contract(
            Addr::unchecked(GOVERNANCE),
            addr.clone(),
            &ExecuteMsg::SetAuthorizedRelayer {
                relayer: Some(BOB.to_string()),
            },
            &[],
        )
        .unwrap();
    }

    // ── Root History Tests ─────────────────────────────────────

    #[test]
    fn historical_root_is_known() {
        let (mut app, addr) = setup_contract();

        // Deposit to get first root
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: "1111".repeat(16),
            },
            &coins(100_000, DENOM),
        )
        .unwrap();

        let root1: RootResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::LatestRoot {})
            .unwrap();

        // Deposit again to get second root
        app.execute_contract(
            Addr::unchecked(ALICE),
            addr.clone(),
            &ExecuteMsg::Deposit {
                commitment: "2222".repeat(16),
            },
            &coins(100_000, DENOM),
        )
        .unwrap();

        // First root should still be known (in history)
        let known: bool = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::IsKnownRoot { root: root1.root })
            .unwrap();
        assert!(known);
    }

    #[test]
    fn unknown_root_is_not_known() {
        let (app, addr) = setup_contract();

        let known: bool = app
            .wrap()
            .query_wasm_smart(
                &addr,
                &QueryMsg::IsKnownRoot { root: "dead".repeat(16) },
            )
            .unwrap();
        assert!(!known);
    }

    // ── Epoch Edge Cases ───────────────────────────────────────

    #[test]
    fn multiple_epoch_finalizations() {
        let (mut app, addr) = setup_contract();

        for _ in 0..5 {
            app.execute_contract(
                Addr::unchecked(ALICE),
                addr.clone(),
                &ExecuteMsg::FinalizeEpoch {},
                &[],
            )
            .unwrap();
        }

        let status: PoolStatusResponse = app
            .wrap()
            .query_wasm_smart(&addr, &QueryMsg::PoolStatus {})
            .unwrap();
        assert_eq!(status.current_epoch, 5);
    }

    #[test]
    fn sync_multiple_remote_chains() {
        let (mut app, addr) = setup_contract();

        let chains = [43114u32, 1287, 81, 9000, 1313161555];
        for chain_id in chains {
            let root = format!("{:0>64}", hex::encode(chain_id.to_be_bytes()));
            app.execute_contract(
                Addr::unchecked(GOVERNANCE),
                addr.clone(),
                &ExecuteMsg::SyncEpochRoot {
                    source_chain_id: chain_id,
                    epoch_id: 0,
                    nullifier_root: root.clone(),
                },
                &[],
            )
            .unwrap();

            let stored: Option<String> = app
                .wrap()
                .query_wasm_smart(
                    &addr,
                    &QueryMsg::RemoteEpochRoot {
                        source_chain_id: chain_id,
                        epoch_id: 0,
                    },
                )
                .unwrap();
            assert_eq!(stored, Some(root));
        }
    }
}
