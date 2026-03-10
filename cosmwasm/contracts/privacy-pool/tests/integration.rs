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
}
