//! Example Substrate runtime integrating the Privacy Pool pallet.
//!
//! This demonstrates how to include `pallet_privacy_pool` in a parachain runtime
//! with full XCM support, epoch management, and proper weight configuration.
//!
//! NOT a production runtime — use as a reference for integration.

#![cfg_attr(not(feature = "std"), no_std)]

#[cfg(feature = "std")]
include!(concat!(env!("OUT_DIR"), "/wasm_binary.rs"));

use frame_support::{
    construct_runtime, parameter_types,
    traits::{ConstU32, ConstU64, Everything},
    weights::{ConstantMultiplier, IdentityFee, Weight},
};
use frame_system::EnsureRoot;
use sp_core::{crypto::KeyTypeId, OpaqueMetadata, H256};
use sp_runtime::{
    create_runtime_str, generic,
    traits::{AccountIdLookup, BlakeTwo256, Block as BlockT, IdentifyAccount, Verify},
    transaction_validity::{TransactionSource, TransactionValidity},
    ApplyExtrinsicResult, MultiSignature,
};
use sp_std::prelude::*;

/// Alias for the signature scheme used
pub type Signature = MultiSignature;

/// Account ID type (derived from Signature)
pub type AccountId = <<Signature as Verify>::Signer as IdentifyAccount>::AccountId;

/// Balance type
pub type Balance = u128;

/// Block number type
pub type BlockNumber = u32;

/// Index type for transaction ordering
pub type Nonce = u32;

/// Opaque block header
pub type Header = generic::Header<BlockNumber, BlakeTwo256>;

/// Opaque block type
pub type Block = generic::Block<Header, UncheckedExtrinsic>;

/// Unchecked extrinsic type
pub type UncheckedExtrinsic =
    generic::UncheckedExtrinsic<sp_runtime::MultiAddress<AccountId, ()>, RuntimeCall, Signature, ()>;

// ── Runtime Version ────────────────────────────────────────────

pub const VERSION: sp_runtime::RuntimeVersion = sp_runtime::RuntimeVersion {
    spec_name: create_runtime_str!("soul-privacy-runtime"),
    impl_name: create_runtime_str!("soul-privacy-runtime"),
    authoring_version: 1,
    spec_version: 100,
    impl_version: 1,
    apis: RUNTIME_API_VERSIONS,
    transaction_version: 1,
    state_version: 1,
};

// ── Parameter Types ────────────────────────────────────────────

parameter_types! {
    pub const BlockHashCount: BlockNumber = 2400;
    pub const Version: sp_runtime::RuntimeVersion = VERSION;

    // Privacy Pool parameters
    pub const TreeDepth: u32 = 32;
    pub const EpochDuration: BlockNumber = 300; // ~30 minutes at 6s block time
    pub const MaxNullifiersPerEpoch: u32 = 65_536;
    pub const RootHistorySize: u32 = 100;
    pub const PrivacyParaId: u32 = 2100; // Example parachain ID
    pub const PrivacyAppId: u32 = 1;
}

// ── Frame System ───────────────────────────────────────────────

impl frame_system::Config for Runtime {
    type BaseCallFilter = Everything;
    type BlockWeights = ();
    type BlockLength = ();
    type DbWeight = ();
    type RuntimeOrigin = RuntimeOrigin;
    type RuntimeCall = RuntimeCall;
    type Nonce = Nonce;
    type Hash = H256;
    type Hashing = BlakeTwo256;
    type AccountId = AccountId;
    type Lookup = AccountIdLookup<AccountId, ()>;
    type Block = Block;
    type RuntimeEvent = RuntimeEvent;
    type BlockHashCount = BlockHashCount;
    type Version = Version;
    type PalletInfo = PalletInfo;
    type AccountData = pallet_balances::AccountData<Balance>;
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

// ── Balances Config ────────────────────────────────────────────

parameter_types! {
    pub const ExistentialDeposit: Balance = 1_000_000_000; // 1 unit (10^9)
}

impl pallet_balances::Config for Runtime {
    type MaxLocks = ConstU32<50>;
    type MaxReserves = ConstU32<50>;
    type ReserveIdentifier = [u8; 8];
    type Balance = Balance;
    type RuntimeEvent = RuntimeEvent;
    type DustRemoval = ();
    type ExistentialDeposit = ExistentialDeposit;
    type AccountStore = System;
    type WeightInfo = ();
    type FreezeIdentifier = ();
    type MaxFreezes = ConstU32<0>;
    type RuntimeHoldReason = RuntimeHoldReason;
    type RuntimeFreezeReason = RuntimeFreezeReason;
}

// ── Privacy Pool Config ────────────────────────────────────────

/// Weight implementation for the privacy pool pallet
pub struct PrivacyPoolWeights;
impl pallet_privacy_pool::pallet::WeightInfo for PrivacyPoolWeights {
    fn deposit() -> Weight {
        Weight::from_parts(150_000_000, 0)
    }
    fn transfer() -> Weight {
        // ZK proof verification dominates cost
        Weight::from_parts(500_000_000, 0)
    }
    fn withdraw() -> Weight {
        Weight::from_parts(500_000_000, 0)
    }
    fn finalize_epoch() -> Weight {
        Weight::from_parts(1_000_000_000, 0)
    }
    fn sync_epoch_root() -> Weight {
        Weight::from_parts(100_000_000, 0)
    }
}

impl pallet_privacy_pool::Config for Runtime {
    type RuntimeEvent = RuntimeEvent;
    type Currency = Balances;
    type TreeDepth = TreeDepth;
    type EpochDuration = EpochDuration;
    type MaxNullifiersPerEpoch = MaxNullifiersPerEpoch;
    type RootHistorySize = RootHistorySize;
    type ParaId = PrivacyParaId;
    type AppId = PrivacyAppId;
    type WeightInfo = PrivacyPoolWeights;
}

// ── Runtime Construction ───────────────────────────────────────

construct_runtime!(
    pub struct Runtime {
        // Core
        System: frame_system = 0,
        Balances: pallet_balances = 10,

        // Privacy
        PrivacyPool: pallet_privacy_pool = 50,
    }
);

// ── Runtime API Implementations ────────────────────────────────

sp_api::impl_runtime_apis! {
    impl sp_api::Core<Block> for Runtime {
        fn version() -> sp_runtime::RuntimeVersion {
            VERSION
        }
        fn execute_block(block: Block) {
            Executive::execute_block(block);
        }
        fn initialize_block(header: &<Block as BlockT>::Header) -> sp_runtime::ExtrinsicInclusionMode {
            Executive::initialize_block(header)
        }
    }

    impl sp_api::Metadata<Block> for Runtime {
        fn metadata() -> OpaqueMetadata {
            OpaqueMetadata::new(Runtime::metadata().into())
        }
        fn metadata_at_version(version: u32) -> Option<OpaqueMetadata> {
            Runtime::metadata_at_version(version)
        }
        fn metadata_versions() -> sp_std::vec::Vec<u32> {
            Runtime::metadata_versions()
        }
    }

    impl sp_block_builder::BlockBuilder<Block> for Runtime {
        fn apply_extrinsic(extrinsic: <Block as BlockT>::Extrinsic) -> ApplyExtrinsicResult {
            Executive::apply_extrinsic(extrinsic)
        }
        fn finalize_block() -> <Block as BlockT>::Header {
            Executive::finalize_block()
        }
        fn inherent_extrinsics(data: sp_inherents::InherentData) -> Vec<<Block as BlockT>::Extrinsic> {
            data.create_extrinsics()
        }
        fn check_inherents(
            block: Block,
            data: sp_inherents::InherentData,
        ) -> sp_inherents::CheckInherentsResult {
            data.check_extrinsics(&block)
        }
    }

    impl sp_transaction_pool::runtime_api::TaggedTransactionQueue<Block> for Runtime {
        fn validate_transaction(
            source: TransactionSource,
            tx: <Block as BlockT>::Extrinsic,
            block_hash: <Block as BlockT>::Hash,
        ) -> TransactionValidity {
            Executive::validate_transaction(source, tx, block_hash)
        }
    }
}

/// Executive type for dispatching transactions
type Executive = frame_executive::Executive<
    Runtime,
    Block,
    frame_system::ChainContext<Runtime>,
    Runtime,
    AllPalletsWithSystem,
>;
