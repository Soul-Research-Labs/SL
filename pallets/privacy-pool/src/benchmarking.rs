//! Benchmarks for the Privacy Pool pallet.
//!
//! Run with:
//! ```sh
//! cargo bench -p pallet-privacy-pool --features runtime-benchmarks
//! ```
//! Then generate weights:
//! ```sh
//! frame-benchmarking-cli benchmark pallet \
//!   --chain dev \
//!   --pallet pallet_privacy_pool \
//!   --extrinsic "*" \
//!   --output pallets/privacy-pool/src/weights.rs
//! ```

#![cfg(feature = "runtime-benchmarks")]

use super::*;
use frame_benchmarking::v2::*;
use frame_support::traits::Currency;
use frame_system::RawOrigin;
use sp_core::H256;
use sp_std::vec;

fn funded_account<T: Config>(name: &'static str, index: u32) -> T::AccountId {
    let caller: T::AccountId = account(name, index, 0);
    let deposit_amount = 1_000_000_000_000u128;
    let balance: <<T as Config>::Currency as Currency<T::AccountId>>::Balance =
        deposit_amount.into();
    T::Currency::make_free_balance_be(&caller, balance);
    caller
}

fn mock_commitment(seed: u8) -> H256 {
    let mut bytes = [0u8; 32];
    bytes[0] = seed;
    bytes[31] = seed.wrapping_add(1);
    H256::from(bytes)
}

fn mock_proof() -> BoundedVec<u8, ConstU32<4096>> {
    // Non-empty proof (placeholder verifier accepts any non-empty proof)
    let proof_bytes = vec![1u8; 128];
    BoundedVec::try_from(proof_bytes).expect("proof fits bound")
}

#[benchmarks]
mod benchmarks {
    use super::*;

    #[benchmark]
    fn deposit() {
        let caller = funded_account::<T>("depositor", 0);
        let commitment = mock_commitment(1);
        let amount: u128 = 1_000_000;

        #[extrinsic_call]
        deposit(RawOrigin::Signed(caller), commitment, amount);

        assert!(CommitmentExists::<T>::get(commitment));
    }

    #[benchmark]
    fn transfer() {
        // Setup: deposit two notes first to establish a known root.
        let caller = funded_account::<T>("transferor", 0);

        let cm0 = mock_commitment(10);
        let cm1 = mock_commitment(11);
        Pallet::<T>::deposit(
            RawOrigin::Signed(caller.clone()).into(),
            cm0,
            1_000_000,
        )
        .expect("deposit 0");
        Pallet::<T>::deposit(
            RawOrigin::Signed(caller.clone()).into(),
            cm1,
            1_000_000,
        )
        .expect("deposit 1");

        let root = Pallet::<T>::get_latest_root();
        let nullifiers = [mock_commitment(20), mock_commitment(21)];
        let output_commitments = [mock_commitment(30), mock_commitment(31)];
        let proof = mock_proof();

        #[extrinsic_call]
        transfer(
            RawOrigin::Signed(caller),
            proof,
            root,
            nullifiers,
            output_commitments,
        );

        assert!(NullifierSpent::<T>::get(nullifiers[0]));
        assert!(NullifierSpent::<T>::get(nullifiers[1]));
    }

    #[benchmark]
    fn withdraw() {
        let caller = funded_account::<T>("withdrawer", 0);
        let recipient = funded_account::<T>("recipient", 1);

        // Deposit to establish pool balance and known root.
        let cm = mock_commitment(40);
        Pallet::<T>::deposit(
            RawOrigin::Signed(caller.clone()).into(),
            cm,
            10_000_000,
        )
        .expect("deposit");

        let root = Pallet::<T>::get_latest_root();
        let nullifiers = [mock_commitment(50), mock_commitment(51)];
        let output_commitments = [mock_commitment(60), mock_commitment(61)];
        let proof = mock_proof();
        let exit_value: u128 = 5_000_000;

        #[extrinsic_call]
        withdraw(
            RawOrigin::Signed(caller),
            proof,
            root,
            nullifiers,
            output_commitments,
            recipient.clone(),
            exit_value,
        );

        assert!(NullifierSpent::<T>::get(nullifiers[0]));
    }

    #[benchmark]
    fn finalize_epoch() {
        let caller = funded_account::<T>("finalizer", 0);

        #[extrinsic_call]
        finalize_epoch(RawOrigin::Signed(caller));

        // Epoch should have advanced.
        let epoch = CurrentEpoch::<T>::get();
        assert!(epoch >= 1);
    }

    #[benchmark]
    fn sync_epoch_root() {
        let caller = funded_account::<T>("syncer", 0);
        let source_chain_id: u32 = 2100;
        let epoch_id: u32 = 0;
        let root = mock_commitment(70);

        #[extrinsic_call]
        sync_epoch_root(
            RawOrigin::Signed(caller),
            source_chain_id,
            epoch_id,
            root,
        );

        assert!(RemoteEpochRoots::<T>::get((source_chain_id, epoch_id)).is_some());
    }

    impl_benchmark_test_suite!(
        Pallet,
        crate::tests::new_test_ext(),
        crate::tests::Test,
    );
}
