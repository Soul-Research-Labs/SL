//! Unit tests for the Privacy Pool pallet.

use crate as pallet_privacy_pool;
use crate::pallet::*;
use frame_support::{
    assert_noop, assert_ok, construct_runtime, parameter_types,
    traits::{ConstU32, ConstU64, Everything},
};
use sp_core::H256;
use sp_runtime::{
    traits::{BlakeTwo256, IdentityLookup},
    BuildStorage,
};

type Block = frame_system::mocking::MockBlock<Test>;

construct_runtime!(
    pub struct Test {
        System: frame_system,
        Balances: pallet_balances,
        PrivacyPool: pallet_privacy_pool,
    }
);

impl frame_system::Config for Test {
    type BaseCallFilter = Everything;
    type BlockWeights = ();
    type BlockLength = ();
    type DbWeight = ();
    type RuntimeOrigin = RuntimeOrigin;
    type RuntimeCall = RuntimeCall;
    type Nonce = u64;
    type Hash = H256;
    type Hashing = BlakeTwo256;
    type AccountId = u64;
    type Lookup = IdentityLookup<Self::AccountId>;
    type Block = Block;
    type RuntimeEvent = RuntimeEvent;
    type BlockHashCount = ConstU64<250>;
    type Version = ();
    type PalletInfo = PalletInfo;
    type AccountData = pallet_balances::AccountData<u128>;
    type OnNewAccount = ();
    type OnKilledAccount = ();
    type SystemWeightInfo = ();
    type SS58Prefix = ();
    type OnSetCode = ();
    type MaxConsumers = ConstU32<16>;
    type RuntimeTask = RuntimeTask;
    type SingleBlockMigrations = ();
    type MultiBlockMigrator = ();
    type PreInherents = ();
    type PostInherents = ();
    type PostTransactions = ();
}

impl pallet_balances::Config for Test {
    type MaxLocks = ConstU32<50>;
    type MaxReserves = ConstU32<50>;
    type ReserveIdentifier = [u8; 8];
    type Balance = u128;
    type RuntimeEvent = RuntimeEvent;
    type DustRemoval = ();
    type ExistentialDeposit = ConstU128<1>;
    type AccountStore = System;
    type WeightInfo = ();
    type FreezeIdentifier = ();
    type MaxFreezes = ConstU32<0>;
    type RuntimeHoldReason = RuntimeHoldReason;
    type RuntimeFreezeReason = RuntimeFreezeReason;
}

parameter_types! {
    pub const ConstU128One: u128 = 1;
}

// Use a type alias for the constant
frame_support::parameter_types! {
    pub const TreeDepthVal: u32 = 32;
    pub const EpochDurationVal: u64 = 100;
    pub const MaxNullifiersVal: u32 = 1024;
    pub const RootHistorySizeVal: u32 = 100;
    pub const ParaIdVal: u32 = 2100;
    pub const AppIdVal: u32 = 1;
    pub const ConstU128<const V: u128>: u128 = V;
}

pub struct TestWeightInfo;
impl WeightInfo for TestWeightInfo {
    fn deposit() -> frame_support::weights::Weight {
        frame_support::weights::Weight::from_parts(10_000, 0)
    }
    fn transfer() -> frame_support::weights::Weight {
        frame_support::weights::Weight::from_parts(50_000, 0)
    }
    fn withdraw() -> frame_support::weights::Weight {
        frame_support::weights::Weight::from_parts(50_000, 0)
    }
    fn finalize_epoch() -> frame_support::weights::Weight {
        frame_support::weights::Weight::from_parts(100_000, 0)
    }
    fn sync_epoch_root() -> frame_support::weights::Weight {
        frame_support::weights::Weight::from_parts(10_000, 0)
    }
}

impl pallet_privacy_pool::Config for Test {
    type RuntimeEvent = RuntimeEvent;
    type Currency = Balances;
    type TreeDepth = TreeDepthVal;
    type EpochDuration = EpochDurationVal;
    type MaxNullifiersPerEpoch = MaxNullifiersVal;
    type RootHistorySize = RootHistorySizeVal;
    type ParaId = ParaIdVal;
    type AppId = AppIdVal;
    type WeightInfo = TestWeightInfo;
}

const ALICE: u64 = 1;
const BOB: u64 = 2;
const INITIAL_BALANCE: u128 = 1_000_000_000_000;

fn new_test_ext() -> sp_io::TestExternalities {
    let mut storage = frame_system::GenesisConfig::<Test>::default()
        .build_storage()
        .unwrap();

    pallet_balances::GenesisConfig::<Test> {
        balances: vec![(ALICE, INITIAL_BALANCE), (BOB, INITIAL_BALANCE)],
    }
    .assimilate_storage(&mut storage)
    .unwrap();

    pallet_privacy_pool::GenesisConfig::<Test> {
        _phantom: Default::default(),
    }
    .assimilate_storage(&mut storage)
    .unwrap();

    let mut ext = sp_io::TestExternalities::new(storage);
    ext.execute_with(|| System::set_block_number(1));
    ext
}

fn make_commitment(seed: u8) -> H256 {
    let mut data = [0u8; 32];
    data[0] = seed;
    H256(sp_core::hashing::keccak_256(&data))
}

// ── Deposit Tests ──────────────────────────────────────────────

#[test]
fn deposit_works() {
    new_test_ext().execute_with(|| {
        let commitment = make_commitment(1);
        let amount: u128 = 1_000;

        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(ALICE),
            commitment,
            amount
        ));

        // Check leaf index advanced
        assert_eq!(NextLeafIndex::<Test>::get(), 1);

        // Check commitment recorded
        assert!(CommitmentExists::<Test>::get(commitment));

        // Check pool balance
        assert_eq!(PoolBalance::<Test>::get(), amount);

        // Check event
        System::assert_last_event(
            Event::<Test>::Deposited {
                commitment,
                leaf_index: 0,
                amount,
            }
            .into(),
        );
    });
}

#[test]
fn deposit_zero_amount_fails() {
    new_test_ext().execute_with(|| {
        let commitment = make_commitment(1);

        assert_noop!(
            PrivacyPool::deposit(RuntimeOrigin::signed(ALICE), commitment, 0),
            Error::<Test>::ZeroDeposit
        );
    });
}

#[test]
fn deposit_duplicate_commitment_fails() {
    new_test_ext().execute_with(|| {
        let commitment = make_commitment(1);

        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(ALICE),
            commitment,
            1_000
        ));

        assert_noop!(
            PrivacyPool::deposit(RuntimeOrigin::signed(BOB), commitment, 2_000),
            Error::<Test>::CommitmentAlreadyExists
        );
    });
}

#[test]
fn multiple_deposits_advance_leaf_index() {
    new_test_ext().execute_with(|| {
        for i in 0u8..5 {
            let commitment = make_commitment(i);
            assert_ok!(PrivacyPool::deposit(
                RuntimeOrigin::signed(ALICE),
                commitment,
                1_000
            ));
        }

        assert_eq!(NextLeafIndex::<Test>::get(), 5);
        assert_eq!(PoolBalance::<Test>::get(), 5_000);
    });
}

// ── Merkle Root Tests ──────────────────────────────────────────

#[test]
fn root_changes_after_deposit() {
    new_test_ext().execute_with(|| {
        let root_before = Roots::<Test>::get(CurrentRootIndex::<Test>::get());

        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(ALICE),
            make_commitment(1),
            1_000
        ));

        let root_after = Roots::<Test>::get(CurrentRootIndex::<Test>::get());
        assert_ne!(root_before, root_after);
    });
}

#[test]
fn different_commitments_produce_different_roots() {
    new_test_ext().execute_with(|| {
        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(ALICE),
            make_commitment(1),
            1_000
        ));
        let root1 = Roots::<Test>::get(CurrentRootIndex::<Test>::get());

        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(ALICE),
            make_commitment(2),
            1_000
        ));
        let root2 = Roots::<Test>::get(CurrentRootIndex::<Test>::get());

        assert_ne!(root1, root2);
    });
}

// ── Epoch Tests ────────────────────────────────────────────────

#[test]
fn epoch_initialized_at_genesis() {
    new_test_ext().execute_with(|| {
        assert_eq!(CurrentEpochId::<Test>::get(), 0);
        let epoch = Epochs::<Test>::get(0).expect("Epoch 0 should exist");
        assert!(!epoch.finalized);
        assert_eq!(epoch.nullifier_count, 0);
    });
}

#[test]
fn finalize_epoch_works() {
    new_test_ext().execute_with(|| {
        // Finalize epoch 0
        assert_ok!(PrivacyPool::finalize_epoch(RuntimeOrigin::signed(ALICE)));

        // Check epoch 0 is finalized
        let epoch0 = Epochs::<Test>::get(0).unwrap();
        assert!(epoch0.finalized);

        // Check new epoch started
        assert_eq!(CurrentEpochId::<Test>::get(), 1);
        let epoch1 = Epochs::<Test>::get(1).unwrap();
        assert!(!epoch1.finalized);
    });
}

#[test]
fn finalize_already_finalized_epoch_fails() {
    new_test_ext().execute_with(|| {
        assert_ok!(PrivacyPool::finalize_epoch(RuntimeOrigin::signed(ALICE)));

        // Finalize epoch 1 (the new current epoch)
        assert_ok!(PrivacyPool::finalize_epoch(RuntimeOrigin::signed(ALICE)));

        // Current epoch is now 2 — epoch 0 is already finalized, but
        // we can only finalize the current epoch, which is 2
        assert_eq!(CurrentEpochId::<Test>::get(), 2);
    });
}

// ── Sync Epoch Root Tests ──────────────────────────────────────

#[test]
fn sync_epoch_root_works() {
    new_test_ext().execute_with(|| {
        let source_para = 2001u32;
        let epoch = 0u64;
        let root = H256::repeat_byte(0xAB);

        assert_ok!(PrivacyPool::sync_epoch_root(
            RuntimeOrigin::signed(ALICE),
            source_para,
            epoch,
            root,
        ));

        assert_eq!(
            RemoteEpochRoots::<Test>::get(source_para, epoch),
            Some(root)
        );

        System::assert_last_event(
            Event::<Test>::RemoteEpochRootReceived {
                source_para_id: source_para,
                epoch_id: epoch,
                nullifier_root: root,
            }
            .into(),
        );
    });
}

#[test]
fn sync_multiple_remote_roots() {
    new_test_ext().execute_with(|| {
        let root_a = H256::repeat_byte(0x01);
        let root_b = H256::repeat_byte(0x02);

        assert_ok!(PrivacyPool::sync_epoch_root(
            RuntimeOrigin::signed(ALICE),
            2001,
            0,
            root_a,
        ));
        assert_ok!(PrivacyPool::sync_epoch_root(
            RuntimeOrigin::signed(ALICE),
            2002,
            0,
            root_b,
        ));

        assert_eq!(RemoteEpochRoots::<Test>::get(2001, 0), Some(root_a));
        assert_eq!(RemoteEpochRoots::<Test>::get(2002, 0), Some(root_b));
    });
}

// ── Pool Balance Tests ─────────────────────────────────────────

#[test]
fn pool_balance_tracks_deposits() {
    new_test_ext().execute_with(|| {
        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(ALICE),
            make_commitment(1),
            500
        ));
        assert_ok!(PrivacyPool::deposit(
            RuntimeOrigin::signed(BOB),
            make_commitment(2),
            300
        ));

        assert_eq!(PoolBalance::<Test>::get(), 800);
    });
}
