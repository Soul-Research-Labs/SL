use cosmwasm_std::{
    entry_point, to_json_binary, BankMsg, Binary, Coin, Deps, DepsMut, Env, MessageInfo, Response,
    StdResult, Uint128,
};

use crate::error::ContractError;
use crate::msg::*;
use crate::state::*;

// ── Constants ──────────────────────────────────────────────

const ZERO_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const CONTRACT_NAME: &str = "crates.io:privacy-pool-cosmwasm";
const CONTRACT_VERSION: &str = env!("CARGO_PKG_VERSION");

// ── Entry Points ───────────────────────────────────────────

#[entry_point]
pub fn instantiate(
    deps: DepsMut,
    env: Env,
    _info: MessageInfo,
    msg: InstantiateMsg,
) -> Result<Response, ContractError> {
    cw2::set_contract_version(deps.storage, CONTRACT_NAME, CONTRACT_VERSION)?;

    let config = Config {
        tree_depth: msg.tree_depth,
        epoch_duration: msg.epoch_duration,
        max_nullifiers_per_epoch: msg.max_nullifiers_per_epoch,
        root_history_size: msg.root_history_size,
        domain_chain_id: msg.domain_chain_id,
        domain_app_id: msg.domain_app_id,
        governance: msg.governance,
        accepted_denom: msg.accepted_denom,
        authorized_relayer: None,
    };
    CONFIG.save(deps.storage, &config)?;

    // Initialize Merkle tree with zero subtrees
    let mut current_zero = ZERO_HASH.to_string();
    for level in 0..msg.tree_depth {
        FILLED_SUBTREES.save(deps.storage, level, &current_zero)?;
        current_zero = poseidon_hash_hex(&current_zero, &current_zero);
    }
    ROOTS.save(deps.storage, 0u32, &current_zero)?;
    CURRENT_ROOT_INDEX.save(deps.storage, &0u32)?;
    NEXT_LEAF_INDEX.save(deps.storage, &0u64)?;
    POOL_BALANCE.save(deps.storage, &Uint128::zero())?;

    // Initialize first epoch
    CURRENT_EPOCH_ID.save(deps.storage, &0u64)?;
    EPOCHS.save(
        deps.storage,
        0u64,
        &EpochInfo {
            start_height: env.block.height,
            end_height: None,
            nullifier_root: ZERO_HASH.to_string(),
            nullifier_count: 0,
            finalized: false,
        },
    )?;
    EPOCH_NULLIFIERS.save(deps.storage, 0u64, &vec![])?;

    Ok(Response::new()
        .add_attribute("action", "instantiate")
        .add_attribute("tree_depth", msg.tree_depth.to_string())
        .add_attribute("domain_chain_id", msg.domain_chain_id.to_string()))
}

#[entry_point]
pub fn execute(
    deps: DepsMut,
    env: Env,
    info: MessageInfo,
    msg: ExecuteMsg,
) -> Result<Response, ContractError> {
    match msg {
        ExecuteMsg::Deposit { commitment } => execute_deposit(deps, env, info, commitment),
        ExecuteMsg::Transfer {
            proof,
            merkle_root,
            nullifiers,
            output_commitments,
        } => execute_transfer(deps, env, proof, merkle_root, nullifiers, output_commitments),
        ExecuteMsg::Withdraw {
            proof,
            merkle_root,
            nullifiers,
            output_commitments,
            recipient,
            exit_value,
        } => execute_withdraw(
            deps,
            env,
            proof,
            merkle_root,
            nullifiers,
            output_commitments,
            recipient,
            exit_value,
        ),
        ExecuteMsg::FinalizeEpoch {} => execute_finalize_epoch(deps, env, info),
        ExecuteMsg::SyncEpochRoot {
            source_chain_id,
            epoch_id,
            nullifier_root,
        } => execute_sync_epoch_root(deps, info, source_chain_id, epoch_id, nullifier_root),
        ExecuteMsg::UpdateGovernance { new_governance } => {
            execute_update_governance(deps, info, new_governance)
        }
        ExecuteMsg::SetAuthorizedRelayer { relayer } => {
            execute_set_authorized_relayer(deps, info, relayer)
        }
    }
}

#[entry_point]
pub fn query(deps: Deps, _env: Env, msg: QueryMsg) -> StdResult<Binary> {
    match msg {
        QueryMsg::LatestRoot {} => {
            let idx = CURRENT_ROOT_INDEX.load(deps.storage)?;
            let root = ROOTS.load(deps.storage, idx)?;
            to_json_binary(&RootResponse { root })
        }
        QueryMsg::IsKnownRoot { root } => {
            let known = is_known_root(deps, &root)?;
            to_json_binary(&known)
        }
        QueryMsg::IsSpent { nullifier } => {
            let spent = NULLIFIER_SPENT
                .may_load(deps.storage, &nullifier)?
                .unwrap_or(false);
            to_json_binary(&spent)
        }
        QueryMsg::PoolStatus {} => {
            let balance = POOL_BALANCE.load(deps.storage)?;
            let next_idx = NEXT_LEAF_INDEX.load(deps.storage)?;
            let epoch = CURRENT_EPOCH_ID.load(deps.storage)?;
            let root_idx = CURRENT_ROOT_INDEX.load(deps.storage)?;
            let root = ROOTS.load(deps.storage, root_idx)?;
            to_json_binary(&PoolStatusResponse {
                total_deposits: next_idx,
                pool_balance: balance,
                current_epoch: epoch,
                latest_root: root,
            })
        }
        QueryMsg::EpochInfo { epoch_id } => {
            let epoch = EPOCHS.load(deps.storage, epoch_id)?;
            to_json_binary(&EpochInfoResponse {
                epoch_id,
                nullifier_root: epoch.nullifier_root,
                nullifier_count: epoch.nullifier_count,
                finalized: epoch.finalized,
            })
        }
        QueryMsg::RemoteEpochRoot {
            source_chain_id,
            epoch_id,
        } => {
            let root = REMOTE_EPOCH_ROOTS.may_load(deps.storage, (source_chain_id, epoch_id))?;
            to_json_binary(&root)
        }
    }
}

// ── Execute Handlers ───────────────────────────────────────

fn execute_deposit(
    deps: DepsMut,
    _env: Env,
    info: MessageInfo,
    commitment: String,
) -> Result<Response, ContractError> {
    // Validate deposit amount from sent funds
    let amount = info
        .funds
        .iter()
        .find(|c| c.denom == config.accepted_denom)
        .map(|c| c.amount)
        .unwrap_or(Uint128::zero());

    if amount.is_zero() {
        return Err(ContractError::ZeroDeposit {});
    }

    // Check commitment uniqueness
    if COMMITMENT_EXISTS
        .may_load(deps.storage, &commitment)?
        .unwrap_or(false)
    {
        return Err(ContractError::CommitmentAlreadyExists {});
    }

    COMMITMENT_EXISTS.save(deps.storage, &commitment, &true)?;

    // Insert into Merkle tree
    let leaf_index = insert_leaf(deps, &commitment)?;

    // Update pool balance
    POOL_BALANCE.update(deps.storage, |b| -> StdResult<_> { Ok(b + amount) })?;

    Ok(Response::new()
        .add_attribute("action", "deposit")
        .add_attribute("commitment", &commitment)
        .add_attribute("leaf_index", leaf_index.to_string())
        .add_attribute("amount", amount.to_string()))
}

fn execute_transfer(
    deps: DepsMut,
    _env: Env,
    proof: String,
    merkle_root: String,
    nullifiers: [String; 2],
    output_commitments: [String; 2],
) -> Result<Response, ContractError> {
    // Validate root
    if !is_known_root(deps.as_ref(), &merkle_root)? {
        return Err(ContractError::UnknownMerkleRoot {});
    }

    // Check and spend nullifiers
    check_and_spend_nullifiers(deps, &nullifiers)?;

    // Verify ZK proof: structural + Fiat-Shamir binding validation.
    // Production: integrate a WASM-compiled Halo2/Groth16 verifier crate
    // (e.g., groth16-solana adapted for CosmWasm, or bellman-ce).
    if !verify_proof_binding(&proof, &merkle_root, &nullifiers, &output_commitments) {
        return Err(ContractError::InvalidProof {});
    }

    // Insert new commitments — re-borrow deps as mutable
    insert_leaf(deps, &output_commitments[0])?;
    insert_leaf(deps, &output_commitments[1])?;

    Ok(Response::new()
        .add_attribute("action", "transfer")
        .add_attribute("nullifier_0", &nullifiers[0])
        .add_attribute("nullifier_1", &nullifiers[1])
        .add_attribute("output_0", &output_commitments[0])
        .add_attribute("output_1", &output_commitments[1]))
}

fn execute_withdraw(
    deps: DepsMut,
    _env: Env,
    proof: String,
    merkle_root: String,
    nullifiers: [String; 2],
    output_commitments: [String; 2],
    recipient: String,
    exit_value: Uint128,
) -> Result<Response, ContractError> {
    if exit_value.is_zero() {
        return Err(ContractError::ZeroWithdrawal {});
    }

    let pool_balance = POOL_BALANCE.load(deps.storage)?;
    if exit_value > pool_balance {
        return Err(ContractError::InsufficientPoolBalance {});
    }

    if !is_known_root(deps.as_ref(), &merkle_root)? {
        return Err(ContractError::UnknownMerkleRoot {});
    }

    check_and_spend_nullifiers(deps, &nullifiers)?;

    if !verify_proof_binding(&proof, &merkle_root, &nullifiers, &output_commitments) {
        return Err(ContractError::InvalidProof {});
    }

    // Insert change commitments
    insert_leaf(deps, &output_commitments[0])?;
    insert_leaf(deps, &output_commitments[1])?;

    // Update pool balance
    POOL_BALANCE.update(deps.storage, |b| -> StdResult<_> {
        Ok(b.checked_sub(exit_value).unwrap_or(Uint128::zero()))
    })?;

    // Send funds to recipient using the configured denom
    let config = CONFIG.load(deps.storage)?;
    let send_msg = BankMsg::Send {
        to_address: recipient.clone(),
        amount: vec![Coin {
            denom: config.accepted_denom,
            amount: exit_value,
        }],
    };

    Ok(Response::new()
        .add_message(send_msg)
        .add_attribute("action", "withdraw")
        .add_attribute("recipient", recipient)
        .add_attribute("amount", exit_value.to_string()))
}

fn execute_finalize_epoch(deps: DepsMut, env: Env, info: MessageInfo) -> Result<Response, ContractError> {
    let config = CONFIG.load(deps.storage)?;
    if info.sender.to_string() != config.governance {
        return Err(ContractError::Unauthorized {});
    }

    let epoch_id = CURRENT_EPOCH_ID.load(deps.storage)?;
    let mut epoch = EPOCHS.load(deps.storage, epoch_id)?;

    if epoch.finalized {
        return Err(ContractError::EpochAlreadyFinalized {});
    }

    let nullifiers = EPOCH_NULLIFIERS.load(deps.storage, epoch_id)?;
    let nullifier_root = compute_nullifier_root(&nullifiers);
    let count = nullifiers.len() as u32;

    epoch.nullifier_root = nullifier_root.clone();
    epoch.nullifier_count = count;
    epoch.end_height = Some(env.block.height);
    epoch.finalized = true;
    EPOCHS.save(deps.storage, epoch_id, &epoch)?;

    // Start new epoch
    let new_epoch_id = epoch_id + 1;
    CURRENT_EPOCH_ID.save(deps.storage, &new_epoch_id)?;
    EPOCHS.save(
        deps.storage,
        new_epoch_id,
        &EpochInfo {
            start_height: env.block.height,
            end_height: None,
            nullifier_root: ZERO_HASH.to_string(),
            nullifier_count: 0,
            finalized: false,
        },
    )?;
    EPOCH_NULLIFIERS.save(deps.storage, new_epoch_id, &vec![])?;

    Ok(Response::new()
        .add_attribute("action", "finalize_epoch")
        .add_attribute("epoch_id", epoch_id.to_string())
        .add_attribute("nullifier_root", nullifier_root)
        .add_attribute("nullifier_count", count.to_string()))
}

fn execute_sync_epoch_root(
    deps: DepsMut,
    info: MessageInfo,
    source_chain_id: u32,
    epoch_id: u64,
    nullifier_root: String,
) -> Result<Response, ContractError> {
    let config = CONFIG.load(deps.storage)?;
    let is_authorized = info.sender.to_string() == config.governance
        || config
            .authorized_relayer
            .as_ref()
            .map_or(false, |r| &info.sender.to_string() == r);
    if !is_authorized {
        return Err(ContractError::Unauthorized {});
    }
    if nullifier_root.is_empty() {
        return Err(ContractError::InvalidNullifierRoot {});
    }

    REMOTE_EPOCH_ROOTS.save(deps.storage, (source_chain_id, epoch_id), &nullifier_root)?;

    Ok(Response::new()
        .add_attribute("action", "sync_epoch_root")
        .add_attribute("source_chain_id", source_chain_id.to_string())
        .add_attribute("epoch_id", epoch_id.to_string())
        .add_attribute("nullifier_root", nullifier_root))
}

fn execute_update_governance(
    deps: DepsMut,
    info: MessageInfo,
    new_governance: String,
) -> Result<Response, ContractError> {
    let mut config = CONFIG.load(deps.storage)?;
    if info.sender.to_string() != config.governance {
        return Err(ContractError::Unauthorized {});
    }
    config.governance = new_governance.clone();
    CONFIG.save(deps.storage, &config)?;

    Ok(Response::new()
        .add_attribute("action", "update_governance")
        .add_attribute("new_governance", new_governance))
}

fn execute_set_authorized_relayer(
    deps: DepsMut,
    info: MessageInfo,
    relayer: Option<String>,
) -> Result<Response, ContractError> {
    let mut config = CONFIG.load(deps.storage)?;
    if info.sender.to_string() != config.governance {
        return Err(ContractError::Unauthorized {});
    }
    config.authorized_relayer = relayer.clone();
    CONFIG.save(deps.storage, &config)?;

    Ok(Response::new()
        .add_attribute("action", "set_authorized_relayer")
        .add_attribute("relayer", relayer.unwrap_or_default()))
}

// ── Internal Helpers ───────────────────────────────────────

fn insert_leaf(deps: DepsMut, leaf_hex: &str) -> Result<u64, ContractError> {
    let config = CONFIG.load(deps.storage)?;
    let next_index = NEXT_LEAF_INDEX.load(deps.storage)?;
    let max_leaves = 2u64.pow(config.tree_depth);

    if next_index >= max_leaves {
        return Err(ContractError::TreeFull {});
    }

    let mut current_index = next_index;
    let mut current_hash = leaf_hex.to_string();

    for level in 0..config.tree_depth {
        if current_index % 2 == 0 {
            FILLED_SUBTREES.save(deps.storage, level, &current_hash)?;
            let zero = zero_hash(level);
            current_hash = poseidon_hash_hex(&current_hash, &zero);
        } else {
            let sibling = FILLED_SUBTREES.load(deps.storage, level)?;
            current_hash = poseidon_hash_hex(&sibling, &current_hash);
        }
        current_index /= 2;
    }

    // Update root history
    let new_idx = (CURRENT_ROOT_INDEX.load(deps.storage)? + 1) % config.root_history_size;
    ROOTS.save(deps.storage, new_idx, &current_hash)?;
    CURRENT_ROOT_INDEX.save(deps.storage, &new_idx)?;
    NEXT_LEAF_INDEX.save(deps.storage, &(next_index + 1))?;

    Ok(next_index)
}

fn is_known_root(deps: Deps, root: &str) -> StdResult<bool> {
    let config = CONFIG.load(deps.storage)?;
    let current_idx = CURRENT_ROOT_INDEX.load(deps.storage)?;

    if root == ZERO_HASH {
        return Ok(false);
    }

    let mut idx = current_idx;
    for _ in 0..config.root_history_size {
        if let Ok(stored_root) = ROOTS.load(deps.storage, idx) {
            if stored_root == root {
                return Ok(true);
            }
        }
        if idx == 0 {
            idx = config.root_history_size - 1;
        } else {
            idx -= 1;
        }
    }
    Ok(false)
}

fn check_and_spend_nullifiers(
    deps: DepsMut,
    nullifiers: &[String; 2],
) -> Result<(), ContractError> {
    let epoch_id = CURRENT_EPOCH_ID.load(deps.storage)?;
    let config = CONFIG.load(deps.storage)?;

    for nullifier in nullifiers {
        if NULLIFIER_SPENT
            .may_load(deps.storage, nullifier)?
            .unwrap_or(false)
        {
            return Err(ContractError::NullifierAlreadySpent {
                nullifier: nullifier.clone(),
            });
        }
        NULLIFIER_SPENT.save(deps.storage, nullifier, &true)?;

        // Add to epoch nullifiers
        let mut epoch_nuls = EPOCH_NULLIFIERS.load(deps.storage, epoch_id)?;
        if epoch_nuls.len() >= config.max_nullifiers_per_epoch as usize {
            return Err(ContractError::EpochNullifierOverflow {});
        }
        epoch_nuls.push(nullifier.clone());
        EPOCH_NULLIFIERS.save(deps.storage, epoch_id, &epoch_nuls)?;
    }
    Ok(())
}

fn compute_nullifier_root(nullifiers: &[String]) -> String {
    if nullifiers.is_empty() {
        return ZERO_HASH.to_string();
    }
    let mut current = nullifiers[0].clone();
    for nul in &nullifiers[1..] {
        current = poseidon_hash_hex(&current, nul);
    }
    current
}

/// Proof verification with Fiat-Shamir binding.
///
/// Validates proof structure AND a binding tag that ties the proof to its
/// specific public inputs, preventing cross-input replay attacks.
///
/// ## Proof format (hex-encoded)
///
///   [0..64):    Binding tag — SHA-256("Halo2-IPA-bind" || inputs_hash || body)
///   [64..192):  Commitment (64 bytes)
///   [192..256): Evaluation scalar (32 bytes)
///   [256..N):   IPA rounds, each 128 hex chars (64 bytes)
///
/// ## Production upgrade path
///
/// Replace this function body with a call to a WASM-compiled Groth16/Halo2
/// verifier. Candidates:
///   - `ark-groth16` compiled to `wasm32-unknown-unknown`
///   - `bellman-ce` BN254 verifier
///   - Custom Halo2 IPA verifier over Pasta curves
///
/// The binding tag check below is retained in production as an
/// additional transcript integrity assertion.
fn verify_proof_binding(
    proof: &str,
    merkle_root: &str,
    nullifiers: &[String; 2],
    output_commitments: &[String; 2],
) -> bool {
    // Minimum proof size: hex-encoded 192 bytes = 384 hex chars
    if proof.len() < 384 {
        return false;
    }
    // Maximum proof size
    if proof.len() > 8192 {
        return false;
    }
    // Proof must be valid hex
    if !proof.chars().all(|c| c.is_ascii_hexdigit()) {
        return false;
    }
    // Proof must be even length (complete bytes)
    if proof.len() % 2 != 0 {
        return false;
    }
    // Reject all-zero proof
    if proof.chars().all(|c| c == '0') {
        return false;
    }
    // Nullifiers must be distinct
    if nullifiers[0] == nullifiers[1] {
        return false;
    }
    // Nullifiers must be non-empty and non-zero
    for nul in nullifiers {
        if nul.is_empty() || nul.chars().all(|c| c == '0') {
            return false;
        }
    }
    // Merkle root must be non-zero
    if merkle_root.is_empty() || merkle_root.chars().all(|c| c == '0') {
        return false;
    }
    // Output commitments must be non-zero and distinct
    for cm in output_commitments {
        if cm.is_empty() || cm.chars().all(|c| c == '0') {
            return false;
        }
    }
    if output_commitments[0] == output_commitments[1] {
        return false;
    }

    // ── Binding verification ──────────────────────────────────
    if proof.len() < 64 {
        return false;
    }
    let binding_hex = &proof[..64];
    let body_hex = &proof[64..];

    // Hash public inputs
    use sha2::{Sha256, Digest};
    let mut inputs_hasher = Sha256::new();
    inputs_hasher.update(merkle_root.as_bytes());
    for nul in nullifiers {
        inputs_hasher.update(nul.as_bytes());
    }
    for cm in output_commitments {
        inputs_hasher.update(cm.as_bytes());
    }
    let inputs_hash = inputs_hasher.finalize();

    // Compute expected binding = SHA-256("Halo2-IPA-bind" || inputs_hash || body)
    let mut binding_hasher = Sha256::new();
    binding_hasher.update(b"Halo2-IPA-bind");
    binding_hasher.update(&inputs_hash);
    binding_hasher.update(body_hex.as_bytes());
    let expected_binding = binding_hasher.finalize();
    let expected_hex = hex::encode(expected_binding);

    binding_hex == expected_hex
}

/// Poseidon hash — domain-separated hash for ZK-compatible Merkle trees.
///
/// Currently uses SHA-256 as a cryptographically secure stand-in.
/// For production, replace with a BN254 Poseidon implementation compiled
/// to `wasm32-unknown-unknown`. Candidates:
///   - `light-poseidon` crate (used in lumora-coprocessor) with `no_std`
///   - `poseidon-rs` with BN254 field arithmetic
///   - Custom T=3 Poseidon with canonical round constants from
///     https://extgit.iaik.tugraz.at/krypto/hadeshash
///
/// The SHA-256 stand-in is acceptable for testnet but will produce
/// different Merkle roots than the Solidity `PoseidonHasher.sol`,
/// breaking cross-chain root verification on mainnet.
fn poseidon_hash_hex(left: &str, right: &str) -> String {
    use sha2::{Sha256, Digest};
    let mut hasher = Sha256::new();
    hasher.update(left.as_bytes());
    hasher.update(right.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

fn zero_hash(level: u32) -> String {
    let mut z = ZERO_HASH.to_string();
    for _ in 0..level {
        z = poseidon_hash_hex(&z, &z);
    }
    z
}
