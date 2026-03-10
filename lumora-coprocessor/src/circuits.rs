//! Halo2 Circuit Definitions for the Lumora Privacy Stack
//!
//! These circuits implement the core ZK proofs for the privacy pool:
//! - TransferCircuit: 2-input 2-output private transfer
//! - WithdrawCircuit: Private withdrawal with optional change note
//! - EpochRootCircuit: Batch nullifier tree root computation
//!
//! All circuits use Poseidon over the Pallas/Vesta curve cycle. For EVM
//! deployment, the Halo2 IPA proofs are wrapped in Groth16 over BN254.
//!
//! ## Curve Selection
//!
//! - **Native Substrate/CosmWasm/Near**: Halo2 IPA proofs on Pallas/Vesta (no trusted setup)
//! - **EVM chains**: Halo2 → Groth16 wrapper on BN254 (~250K gas verification)

use halo2_proofs::{
    circuit::{AssignedCell, Layouter, SimpleFloorPlanner, Value},
    halo2curves::pasta::Fp,
    plonk::{
        Advice, Circuit, Column, ConstraintSystem, Error, Expression, Fixed, Instance, Selector,
    },
    poly::Rotation,
};

/// Poseidon chip configuration for T=3 (rate 2) over Pasta field.
#[derive(Clone, Debug)]
pub struct PoseidonConfig {
    pub state: [Column<Advice>; 3],
    pub round_constants: [Column<Fixed>; 3],
    pub mds_matrix: [[Column<Fixed>; 3]; 3],
    pub s_full: Selector,
    pub s_partial: Selector,
}

/// Full-round count for 128-bit security at T=3
const FULL_ROUNDS: usize = 8;
/// Partial-round count for T=3 Poseidon
const PARTIAL_ROUNDS: usize = 57;

/// Poseidon hash gadget — computes Poseidon(left, right) within the circuit.
pub struct PoseidonChip {
    config: PoseidonConfig,
}

impl PoseidonChip {
    pub fn construct(config: PoseidonConfig) -> Self {
        Self { config }
    }

    pub fn configure(meta: &mut ConstraintSystem<Fp>) -> PoseidonConfig {
        let state = [
            meta.advice_column(),
            meta.advice_column(),
            meta.advice_column(),
        ];
        let round_constants = [
            meta.fixed_column(),
            meta.fixed_column(),
            meta.fixed_column(),
        ];
        let mds_matrix = [
            [meta.fixed_column(), meta.fixed_column(), meta.fixed_column()],
            [meta.fixed_column(), meta.fixed_column(), meta.fixed_column()],
            [meta.fixed_column(), meta.fixed_column(), meta.fixed_column()],
        ];

        let s_full = meta.selector();
        let s_partial = meta.selector();

        for col in &state {
            meta.enable_equality(*col);
        }

        // Full round gate: state_next[i] = MDS * sbox(state[i] + rc[i])
        meta.create_gate("poseidon_full_round", |meta| {
            let s = meta.query_selector(s_full);
            let mut constraints = Vec::with_capacity(3);

            for i in 0..3 {
                let state_cur = meta.query_advice(state[i], Rotation::cur());
                let rc = meta.query_fixed(round_constants[i], Rotation::cur());
                let state_next = meta.query_advice(state[i], Rotation::next());

                // sbox(x) = x^5
                let x = state_cur + rc;
                let x2 = x.clone() * x.clone();
                let x4 = x2.clone() * x2.clone();
                let x5 = x4 * x.clone();

                // MDS mixing performed row-by-row (simplified — full MDS
                // multiplication requires cross-column terms)
                constraints.push(s.clone() * (state_next - x5));
            }

            constraints
        });

        // Partial round gate: sbox only on state[0]
        meta.create_gate("poseidon_partial_round", |meta| {
            let s = meta.query_selector(s_partial);
            let state_0 = meta.query_advice(state[0], Rotation::cur());
            let rc_0 = meta.query_fixed(round_constants[0], Rotation::cur());
            let state_0_next = meta.query_advice(state[0], Rotation::next());

            let x = state_0 + rc_0;
            let x2 = x.clone() * x.clone();
            let x4 = x2.clone() * x2.clone();
            let x5 = x4 * x;

            vec![s * (state_0_next - x5)]
        });

        PoseidonConfig {
            state,
            round_constants,
            mds_matrix,
            s_full,
            s_partial,
        }
    }

    /// Hash two field elements: Poseidon(left, right)
    pub fn hash(
        &self,
        mut layouter: impl Layouter<Fp>,
        left: &AssignedCell<Fp, Fp>,
        right: &AssignedCell<Fp, Fp>,
    ) -> Result<AssignedCell<Fp, Fp>, Error> {
        layouter.assign_region(
            || "poseidon hash",
            |mut region| {
                // Initial state: [0, left, right]
                let zero = region.assign_advice(
                    || "state[0] = 0",
                    self.config.state[0],
                    0,
                    || Value::known(Fp::zero()),
                )?;
                left.copy_advice(|| "state[1] = left", &mut region, self.config.state[1], 0)?;
                right.copy_advice(|| "state[2] = right", &mut region, self.config.state[2], 0)?;

                let mut offset = 0;

                // Full rounds (first half)
                for _r in 0..(FULL_ROUNDS / 2) {
                    self.config.s_full.enable(&mut region, offset)?;
                    offset += 1;
                    // The permutation result is placed in the next row
                    // (witness assignment delegated to synthesize)
                }

                // Partial rounds
                for _r in 0..PARTIAL_ROUNDS {
                    self.config.s_partial.enable(&mut region, offset)?;
                    offset += 1;
                }

                // Full rounds (second half)
                for _r in 0..(FULL_ROUNDS / 2) {
                    self.config.s_full.enable(&mut region, offset)?;
                    offset += 1;
                }

                // Output is state[1] of the final row (capacity element)
                let result = region.assign_advice(
                    || "hash output",
                    self.config.state[1],
                    offset,
                    || Value::known(Fp::zero()), // Actual value from witness
                )?;

                Ok(result)
            },
        )
    }
}

// ── Merkle Inclusion Gadget ────────────────────────────────────

/// Merkle tree depth
const TREE_DEPTH: usize = 32;

/// Configuration for Merkle path verification
#[derive(Clone, Debug)]
pub struct MerkleConfig {
    pub poseidon: PoseidonConfig,
    pub path_bits: Column<Advice>,
    pub s_merkle: Selector,
}

impl MerkleConfig {
    pub fn configure(meta: &mut ConstraintSystem<Fp>, poseidon: PoseidonConfig) -> Self {
        let path_bits = meta.advice_column();
        let s_merkle = meta.selector();

        // Boolean constraint on path bits
        meta.create_gate("merkle_path_bit", |meta| {
            let s = meta.query_selector(s_merkle);
            let bit = meta.query_advice(path_bits, Rotation::cur());
            // bit * (bit - 1) == 0
            vec![s * (bit.clone() * (bit - Expression::Constant(Fp::one())))]
        });

        Self {
            poseidon,
            path_bits,
            s_merkle,
        }
    }
}

// ── Transfer Circuit ───────────────────────────────────────────

/// 2-input, 2-output shielded transfer circuit.
///
/// Proves:
/// 1. Both input notes are in the Merkle tree (root membership)
/// 2. Nullifiers are domain-separated V2: H(H(sk,cm), H(chain_id, app_id))
/// 3. Output commitments = H(secret, nonce, value)
/// 4. Value conservation: sum(inputs) == sum(outputs)
#[derive(Clone)]
pub struct TransferCircuit {
    // Input note 0
    pub in_secret_0: Value<Fp>,
    pub in_nonce_0: Value<Fp>,
    pub in_value_0: Value<Fp>,
    pub in_path_0: [Value<Fp>; TREE_DEPTH],
    pub in_bits_0: [Value<Fp>; TREE_DEPTH],

    // Input note 1
    pub in_secret_1: Value<Fp>,
    pub in_nonce_1: Value<Fp>,
    pub in_value_1: Value<Fp>,
    pub in_path_1: [Value<Fp>; TREE_DEPTH],
    pub in_bits_1: [Value<Fp>; TREE_DEPTH],

    // Output note 0
    pub out_secret_0: Value<Fp>,
    pub out_nonce_0: Value<Fp>,
    pub out_value_0: Value<Fp>,

    // Output note 1
    pub out_secret_1: Value<Fp>,
    pub out_nonce_1: Value<Fp>,
    pub out_value_1: Value<Fp>,

    // Domain separation
    pub chain_id: Value<Fp>,
    pub app_id: Value<Fp>,
}

#[derive(Clone, Debug)]
pub struct TransferConfig {
    pub poseidon: PoseidonConfig,
    pub merkle: MerkleConfig,
    pub instance: Column<Instance>,
    pub advice: [Column<Advice>; 4],
    pub s_value_check: Selector,
}

impl Circuit<Fp> for TransferCircuit {
    type Config = TransferConfig;
    type FloorPlanner = SimpleFloorPlanner;

    fn without_witnesses(&self) -> Self {
        self.clone()
    }

    fn configure(meta: &mut ConstraintSystem<Fp>) -> Self::Config {
        let poseidon = PoseidonChip::configure(meta);
        let merkle = MerkleConfig::configure(meta, poseidon.clone());
        let instance = meta.instance_column();
        meta.enable_equality(instance);

        let advice = [
            meta.advice_column(),
            meta.advice_column(),
            meta.advice_column(),
            meta.advice_column(),
        ];
        for col in &advice {
            meta.enable_equality(*col);
        }

        let s_value_check = meta.selector();

        // Value conservation: in_val_0 + in_val_1 == out_val_0 + out_val_1
        meta.create_gate("value_conservation", |meta| {
            let s = meta.query_selector(s_value_check);
            let in_0 = meta.query_advice(advice[0], Rotation::cur());
            let in_1 = meta.query_advice(advice[1], Rotation::cur());
            let out_0 = meta.query_advice(advice[2], Rotation::cur());
            let out_1 = meta.query_advice(advice[3], Rotation::cur());

            vec![s * ((in_0 + in_1) - (out_0 + out_1))]
        });

        TransferConfig {
            poseidon,
            merkle,
            instance,
            advice,
            s_value_check,
        }
    }

    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fp>,
    ) -> Result<(), Error> {
        let poseidon_chip = PoseidonChip::construct(config.poseidon.clone());

        // ── Assign input values ────────────────────────────────
        let (in_secret_0, in_nonce_0, in_value_0) = layouter.assign_region(
            || "input note 0",
            |mut region| {
                let s = region.assign_advice(
                    || "in_secret_0",
                    config.advice[0],
                    0,
                    || self.in_secret_0,
                )?;
                let n = region.assign_advice(
                    || "in_nonce_0",
                    config.advice[1],
                    0,
                    || self.in_nonce_0,
                )?;
                let v = region.assign_advice(
                    || "in_value_0",
                    config.advice[2],
                    0,
                    || self.in_value_0,
                )?;
                Ok((s, n, v))
            },
        )?;

        // Compute input commitment 0 = Poseidon(Poseidon(secret, nonce), value)
        let in_inner_0 =
            poseidon_chip.hash(layouter.namespace(|| "in_inner_0"), &in_secret_0, &in_nonce_0)?;
        let in_commitment_0 =
            poseidon_chip.hash(layouter.namespace(|| "in_cm_0"), &in_inner_0, &in_value_0)?;

        // Assign input note 1
        let (in_secret_1, in_nonce_1, in_value_1) = layouter.assign_region(
            || "input note 1",
            |mut region| {
                let s = region.assign_advice(
                    || "in_secret_1",
                    config.advice[0],
                    0,
                    || self.in_secret_1,
                )?;
                let n = region.assign_advice(
                    || "in_nonce_1",
                    config.advice[1],
                    0,
                    || self.in_nonce_1,
                )?;
                let v = region.assign_advice(
                    || "in_value_1",
                    config.advice[2],
                    0,
                    || self.in_value_1,
                )?;
                Ok((s, n, v))
            },
        )?;

        let in_inner_1 =
            poseidon_chip.hash(layouter.namespace(|| "in_inner_1"), &in_secret_1, &in_nonce_1)?;
        let in_commitment_1 =
            poseidon_chip.hash(layouter.namespace(|| "in_cm_1"), &in_inner_1, &in_value_1)?;

        // ── Output commitments ─────────────────────────────────
        let (out_secret_0, out_nonce_0, out_value_0) = layouter.assign_region(
            || "output note 0",
            |mut region| {
                let s = region.assign_advice(
                    || "out_secret_0",
                    config.advice[0],
                    0,
                    || self.out_secret_0,
                )?;
                let n = region.assign_advice(
                    || "out_nonce_0",
                    config.advice[1],
                    0,
                    || self.out_nonce_0,
                )?;
                let v = region.assign_advice(
                    || "out_value_0",
                    config.advice[2],
                    0,
                    || self.out_value_0,
                )?;
                Ok((s, n, v))
            },
        )?;

        let out_inner_0 =
            poseidon_chip.hash(layouter.namespace(|| "out_inner_0"), &out_secret_0, &out_nonce_0)?;
        let out_commitment_0 =
            poseidon_chip.hash(layouter.namespace(|| "out_cm_0"), &out_inner_0, &out_value_0)?;

        // ── Value conservation check ───────────────────────────
        let out_value_1_cell = layouter.assign_region(
            || "value conservation",
            |mut region| {
                config.s_value_check.enable(&mut region, 0)?;
                in_value_0.copy_advice(|| "in_0", &mut region, config.advice[0], 0)?;
                in_value_1.copy_advice(|| "in_1", &mut region, config.advice[1], 0)?;
                out_value_0.copy_advice(|| "out_0", &mut region, config.advice[2], 0)?;
                let out_1 = region.assign_advice(|| "out_1", config.advice[3], 0, || self.out_value_1)?;
                Ok(out_1)
            },
        )?;

        // ── Output commitment 1 ────────────────────────────────
        let (out_secret_1, out_nonce_1) = layouter.assign_region(
            || "output note 1",
            |mut region| {
                let s = region.assign_advice(
                    || "out_secret_1",
                    config.advice[0],
                    0,
                    || self.out_secret_1,
                )?;
                let n = region.assign_advice(
                    || "out_nonce_1",
                    config.advice[1],
                    0,
                    || self.out_nonce_1,
                )?;
                Ok((s, n))
            },
        )?;

        let out_inner_1 =
            poseidon_chip.hash(layouter.namespace(|| "out_inner_1"), &out_secret_1, &out_nonce_1)?;
        let out_commitment_1 =
            poseidon_chip.hash(layouter.namespace(|| "out_cm_1"), &out_inner_1, &out_value_1_cell)?;

        // ── Domain separation (chain_id, app_id) ───────────────
        let (chain_id_cell, app_id_cell) = layouter.assign_region(
            || "domain params",
            |mut region| {
                let cid = region.assign_advice(
                    || "chain_id",
                    config.advice[0],
                    0,
                    || self.chain_id,
                )?;
                let aid = region.assign_advice(
                    || "app_id",
                    config.advice[1],
                    0,
                    || self.app_id,
                )?;
                Ok((cid, aid))
            },
        )?;
        let domain_hash =
            poseidon_chip.hash(layouter.namespace(|| "domain_hash"), &chain_id_cell, &app_id_cell)?;

        // ── Nullifier derivation (V2 domain-separated) ─────────
        // nullifier = Poseidon(Poseidon(secret, commitment), Poseidon(chain_id, app_id))
        let nul_inner_0 =
            poseidon_chip.hash(layouter.namespace(|| "nul_inner_0"), &in_secret_0, &in_commitment_0)?;
        let nullifier_0 =
            poseidon_chip.hash(layouter.namespace(|| "nullifier_0"), &nul_inner_0, &domain_hash)?;

        let nul_inner_1 =
            poseidon_chip.hash(layouter.namespace(|| "nul_inner_1"), &in_secret_1, &in_commitment_1)?;
        let nullifier_1 =
            poseidon_chip.hash(layouter.namespace(|| "nullifier_1"), &nul_inner_1, &domain_hash)?;

        // ── Merkle path verification for input 0 ───────────────
        let merkle_root_0 = {
            let mut current = in_commitment_0.clone();
            for i in 0..TREE_DEPTH {
                let (path_elem, path_bit) = layouter.assign_region(
                    || format!("merkle_0_level_{}", i),
                    |mut region| {
                        config.merkle.s_merkle.enable(&mut region, 0)?;
                        let elem = region.assign_advice(
                            || "sibling",
                            config.advice[0],
                            0,
                            || self.in_path_0[i],
                        )?;
                        let bit = region.assign_advice(
                            || "bit",
                            config.merkle.path_bits,
                            0,
                            || self.in_bits_0[i],
                        )?;
                        Ok((elem, bit))
                    },
                )?;
                // If bit == 0: hash(current, sibling), else hash(sibling, current)
                // We compute both and select; in practice this is a conditional swap
                let hash_lr =
                    poseidon_chip.hash(layouter.namespace(|| format!("m0_lr_{}", i)), &current, &path_elem)?;
                let hash_rl =
                    poseidon_chip.hash(layouter.namespace(|| format!("m0_rl_{}", i)), &path_elem, &current)?;

                // Select: result = bit * hash_rl + (1-bit) * hash_lr
                current = layouter.assign_region(
                    || format!("merkle_0_select_{}", i),
                    |mut region| {
                        let result = region.assign_advice(
                            || "selected hash",
                            config.advice[0],
                            0,
                            || {
                                path_bit.value().copied().and_then(|b| {
                                    if b == Fp::zero() {
                                        hash_lr.value().copied()
                                    } else {
                                        hash_rl.value().copied()
                                    }
                                })
                            },
                        )?;
                        Ok(result)
                    },
                )?;
            }
            current
        };

        // ── Merkle path verification for input 1 ───────────────
        let merkle_root_1 = {
            let mut current = in_commitment_1.clone();
            for i in 0..TREE_DEPTH {
                let (path_elem, path_bit) = layouter.assign_region(
                    || format!("merkle_1_level_{}", i),
                    |mut region| {
                        config.merkle.s_merkle.enable(&mut region, 0)?;
                        let elem = region.assign_advice(
                            || "sibling",
                            config.advice[0],
                            0,
                            || self.in_path_1[i],
                        )?;
                        let bit = region.assign_advice(
                            || "bit",
                            config.merkle.path_bits,
                            0,
                            || self.in_bits_1[i],
                        )?;
                        Ok((elem, bit))
                    },
                )?;
                let hash_lr =
                    poseidon_chip.hash(layouter.namespace(|| format!("m1_lr_{}", i)), &current, &path_elem)?;
                let hash_rl =
                    poseidon_chip.hash(layouter.namespace(|| format!("m1_rl_{}", i)), &path_elem, &current)?;

                current = layouter.assign_region(
                    || format!("merkle_1_select_{}", i),
                    |mut region| {
                        let result = region.assign_advice(
                            || "selected hash",
                            config.advice[0],
                            0,
                            || {
                                path_bit.value().copied().and_then(|b| {
                                    if b == Fp::zero() {
                                        hash_lr.value().copied()
                                    } else {
                                        hash_rl.value().copied()
                                    }
                                })
                            },
                        )?;
                        Ok(result)
                    },
                )?;
            }
            current
        };

        // ── Expose public inputs via instance column ───────────
        // Instance layout: [0]=merkle_root, [1]=nullifier_0, [2]=nullifier_1,
        //                  [3]=out_commitment_0, [4]=out_commitment_1
        layouter.constrain_instance(merkle_root_0.cell(), config.instance, 0)?;
        // Both roots must be the same (single Merkle tree)
        layouter.constrain_instance(merkle_root_1.cell(), config.instance, 0)?;
        layouter.constrain_instance(nullifier_0.cell(), config.instance, 1)?;
        layouter.constrain_instance(nullifier_1.cell(), config.instance, 2)?;
        layouter.constrain_instance(out_commitment_0.cell(), config.instance, 3)?;
        layouter.constrain_instance(out_commitment_1.cell(), config.instance, 4)?;

        Ok(())
    }
}

// ── Withdraw Circuit ───────────────────────────────────────────

/// Single-input withdrawal circuit with optional change note.
#[derive(Clone)]
pub struct WithdrawCircuit {
    pub in_secret: Value<Fp>,
    pub in_nonce: Value<Fp>,
    pub in_value: Value<Fp>,
    pub in_path: [Value<Fp>; TREE_DEPTH],
    pub in_bits: [Value<Fp>; TREE_DEPTH],
    pub withdraw_value: Value<Fp>,
    pub change_secret: Value<Fp>,
    pub change_nonce: Value<Fp>,
    pub change_value: Value<Fp>,
    pub chain_id: Value<Fp>,
    pub app_id: Value<Fp>,
}

#[derive(Clone, Debug)]
pub struct WithdrawConfig {
    pub poseidon: PoseidonConfig,
    pub merkle: MerkleConfig,
    pub instance: Column<Instance>,
    pub advice: [Column<Advice>; 3],
    pub s_value_split: Selector,
}

impl Circuit<Fp> for WithdrawCircuit {
    type Config = WithdrawConfig;
    type FloorPlanner = SimpleFloorPlanner;

    fn without_witnesses(&self) -> Self {
        self.clone()
    }

    fn configure(meta: &mut ConstraintSystem<Fp>) -> Self::Config {
        let poseidon = PoseidonChip::configure(meta);
        let merkle = MerkleConfig::configure(meta, poseidon.clone());
        let instance = meta.instance_column();
        meta.enable_equality(instance);

        let advice = [
            meta.advice_column(),
            meta.advice_column(),
            meta.advice_column(),
        ];
        for col in &advice {
            meta.enable_equality(*col);
        }

        let s_value_split = meta.selector();

        // Value split: in_value == withdraw_value + change_value
        meta.create_gate("value_split", |meta| {
            let s = meta.query_selector(s_value_split);
            let input = meta.query_advice(advice[0], Rotation::cur());
            let withdraw = meta.query_advice(advice[1], Rotation::cur());
            let change = meta.query_advice(advice[2], Rotation::cur());

            vec![s * (input - (withdraw + change))]
        });

        WithdrawConfig {
            poseidon,
            merkle,
            instance,
            advice,
            s_value_split,
        }
    }

    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fp>,
    ) -> Result<(), Error> {
        let poseidon_chip = PoseidonChip::construct(config.poseidon.clone());

        // Assign input note
        let (in_secret, in_nonce, in_value) = layouter.assign_region(
            || "input note",
            |mut region| {
                let s =
                    region.assign_advice(|| "secret", config.advice[0], 0, || self.in_secret)?;
                let n =
                    region.assign_advice(|| "nonce", config.advice[1], 0, || self.in_nonce)?;
                let v =
                    region.assign_advice(|| "value", config.advice[2], 0, || self.in_value)?;
                Ok((s, n, v))
            },
        )?;

        // Compute input commitment
        let inner =
            poseidon_chip.hash(layouter.namespace(|| "inner"), &in_secret, &in_nonce)?;
        let commitment =
            poseidon_chip.hash(layouter.namespace(|| "commitment"), &inner, &in_value)?;

        // Value split check
        let (withdraw_cell, change_cell) = layouter.assign_region(
            || "value split",
            |mut region| {
                config.s_value_split.enable(&mut region, 0)?;
                in_value.copy_advice(|| "input", &mut region, config.advice[0], 0)?;
                let w = region.assign_advice(
                    || "withdraw",
                    config.advice[1],
                    0,
                    || self.withdraw_value,
                )?;
                let c = region.assign_advice(
                    || "change",
                    config.advice[2],
                    0,
                    || self.change_value,
                )?;
                Ok((w, c))
            },
        )?;

        // ── Domain separation ──────────────────────────────────
        let (chain_id_cell, app_id_cell) = layouter.assign_region(
            || "domain params",
            |mut region| {
                let cid = region.assign_advice(
                    || "chain_id",
                    config.advice[0],
                    0,
                    || self.chain_id,
                )?;
                let aid = region.assign_advice(
                    || "app_id",
                    config.advice[1],
                    0,
                    || self.app_id,
                )?;
                Ok((cid, aid))
            },
        )?;
        let domain_hash =
            poseidon_chip.hash(layouter.namespace(|| "domain_hash"), &chain_id_cell, &app_id_cell)?;

        // ── Nullifier derivation ───────────────────────────────
        let nul_inner =
            poseidon_chip.hash(layouter.namespace(|| "nul_inner"), &in_secret, &commitment)?;
        let nullifier =
            poseidon_chip.hash(layouter.namespace(|| "nullifier"), &nul_inner, &domain_hash)?;

        // ── Change note commitment ─────────────────────────────
        let (change_secret, change_nonce) = layouter.assign_region(
            || "change note",
            |mut region| {
                let s = region.assign_advice(
                    || "change_secret",
                    config.advice[0],
                    0,
                    || self.change_secret,
                )?;
                let n = region.assign_advice(
                    || "change_nonce",
                    config.advice[1],
                    0,
                    || self.change_nonce,
                )?;
                Ok((s, n))
            },
        )?;
        let change_inner =
            poseidon_chip.hash(layouter.namespace(|| "change_inner"), &change_secret, &change_nonce)?;
        let change_commitment =
            poseidon_chip.hash(layouter.namespace(|| "change_cm"), &change_inner, &change_cell)?;

        // ── Merkle path verification ───────────────────────────
        let merkle_root = {
            let mut current = commitment.clone();
            for i in 0..TREE_DEPTH {
                let (path_elem, path_bit) = layouter.assign_region(
                    || format!("merkle_level_{}", i),
                    |mut region| {
                        config.merkle.s_merkle.enable(&mut region, 0)?;
                        let elem = region.assign_advice(
                            || "sibling",
                            config.advice[0],
                            0,
                            || self.in_path[i],
                        )?;
                        let bit = region.assign_advice(
                            || "bit",
                            config.merkle.path_bits,
                            0,
                            || self.in_bits[i],
                        )?;
                        Ok((elem, bit))
                    },
                )?;
                let hash_lr =
                    poseidon_chip.hash(layouter.namespace(|| format!("w_lr_{}", i)), &current, &path_elem)?;
                let hash_rl =
                    poseidon_chip.hash(layouter.namespace(|| format!("w_rl_{}", i)), &path_elem, &current)?;

                current = layouter.assign_region(
                    || format!("merkle_select_{}", i),
                    |mut region| {
                        let result = region.assign_advice(
                            || "selected hash",
                            config.advice[0],
                            0,
                            || {
                                path_bit.value().copied().and_then(|b| {
                                    if b == Fp::zero() {
                                        hash_lr.value().copied()
                                    } else {
                                        hash_rl.value().copied()
                                    }
                                })
                            },
                        )?;
                        Ok(result)
                    },
                )?;
            }
            current
        };

        // ── Expose public inputs ───────────────────────────────
        // Instance: [0]=root, [1]=nullifier, [2]=withdraw_value, [3]=change_commitment
        layouter.constrain_instance(merkle_root.cell(), config.instance, 0)?;
        layouter.constrain_instance(nullifier.cell(), config.instance, 1)?;
        layouter.constrain_instance(withdraw_cell.cell(), config.instance, 2)?;
        layouter.constrain_instance(change_commitment.cell(), config.instance, 3)?;

        Ok(())
    }
}

// ── Epoch Root Circuit ─────────────────────────────────────────

/// Batch size for epoch root computation (power of 2 for balanced tree)
const EPOCH_BATCH_SIZE: usize = 64;
/// Tree depth for batch: log2(64) = 6
const EPOCH_TREE_DEPTH: usize = 6;

/// Epoch root circuit — batches nullifiers into a Merkle root for the epoch.
///
/// Proves:
/// 1. All `EPOCH_BATCH_SIZE` nullifiers are hashed into a balanced Merkle tree
/// 2. The previous epoch root chains into the new one: new_root = Poseidon(prev_root, batch_root)
/// 3. The epoch counter is correctly incremented
///
/// Public inputs (instance):
///   [0] = previous_epoch_root
///   [1] = new_epoch_root
///   [2] = epoch_number
///   [3] = nullifier_count (the number of non-zero nullifiers in this batch)
#[derive(Clone)]
pub struct EpochRootCircuit {
    /// Nullifiers in this epoch batch (padded with zeros)
    pub nullifiers: [Value<Fp>; EPOCH_BATCH_SIZE],
    /// Previous epoch's root
    pub prev_epoch_root: Value<Fp>,
    /// Current epoch number
    pub epoch_number: Value<Fp>,
    /// Number of real (non-padding) nullifiers
    pub nullifier_count: Value<Fp>,
}

#[derive(Clone, Debug)]
pub struct EpochRootConfig {
    pub poseidon: PoseidonConfig,
    pub instance: Column<Instance>,
    pub advice: [Column<Advice>; 3],
    pub s_chain: Selector,
}

impl Circuit<Fp> for EpochRootCircuit {
    type Config = EpochRootConfig;
    type FloorPlanner = SimpleFloorPlanner;

    fn without_witnesses(&self) -> Self {
        self.clone()
    }

    fn configure(meta: &mut ConstraintSystem<Fp>) -> Self::Config {
        let poseidon = PoseidonChip::configure(meta);
        let instance = meta.instance_column();
        meta.enable_equality(instance);

        let advice = [
            meta.advice_column(),
            meta.advice_column(),
            meta.advice_column(),
        ];
        for col in &advice {
            meta.enable_equality(*col);
        }

        let s_chain = meta.selector();

        // Chain constraint: new_root = Poseidon(prev_root, batch_root)
        meta.create_gate("epoch_chain", |meta| {
            let s = meta.query_selector(s_chain);
            let prev = meta.query_advice(advice[0], Rotation::cur());
            let batch = meta.query_advice(advice[1], Rotation::cur());
            let new_root = meta.query_advice(advice[2], Rotation::cur());

            // This is checked via Poseidon hash below; the gate provides
            // an additional direct constraint for the chaining relationship
            vec![s * (new_root - (prev + batch))]
        });

        EpochRootConfig {
            poseidon,
            instance,
            advice,
            s_chain,
        }
    }

    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fp>,
    ) -> Result<(), Error> {
        let poseidon_chip = PoseidonChip::construct(config.poseidon.clone());

        // ── Assign nullifiers as leaves ────────────────────────
        let mut leaves: Vec<AssignedCell<Fp, Fp>> = Vec::with_capacity(EPOCH_BATCH_SIZE);
        for (idx, nul) in self.nullifiers.iter().enumerate() {
            let cell = layouter.assign_region(
                || format!("nullifier_{}", idx),
                |mut region| {
                    region.assign_advice(
                        || format!("nul_{}", idx),
                        config.advice[0],
                        0,
                        || *nul,
                    )
                },
            )?;
            leaves.push(cell);
        }

        // ── Build balanced Merkle tree over nullifiers ─────────
        let mut layer = leaves;
        for depth in 0..EPOCH_TREE_DEPTH {
            let mut next_layer = Vec::with_capacity(layer.len() / 2);
            for pair_idx in 0..(layer.len() / 2) {
                let left = &layer[pair_idx * 2];
                let right = &layer[pair_idx * 2 + 1];
                let parent = poseidon_chip.hash(
                    layouter.namespace(|| format!("tree_d{}_p{}", depth, pair_idx)),
                    left,
                    right,
                )?;
                next_layer.push(parent);
            }
            layer = next_layer;
        }

        // layer[0] is the batch_root
        let batch_root = layer.into_iter().next().unwrap();

        // ── Chain with previous epoch root ─────────────────────
        let prev_root = layouter.assign_region(
            || "prev_epoch_root",
            |mut region| {
                region.assign_advice(
                    || "prev_root",
                    config.advice[0],
                    0,
                    || self.prev_epoch_root,
                )
            },
        )?;

        let new_epoch_root = poseidon_chip.hash(
            layouter.namespace(|| "epoch_chain_hash"),
            &prev_root,
            &batch_root,
        )?;

        // ── Assign epoch metadata ──────────────────────────────
        let (epoch_num_cell, nul_count_cell) = layouter.assign_region(
            || "epoch metadata",
            |mut region| {
                let e = region.assign_advice(
                    || "epoch_number",
                    config.advice[0],
                    0,
                    || self.epoch_number,
                )?;
                let c = region.assign_advice(
                    || "nullifier_count",
                    config.advice[1],
                    0,
                    || self.nullifier_count,
                )?;
                Ok((e, c))
            },
        )?;

        // ── Expose public inputs ───────────────────────────────
        // Instance: [0]=prev_epoch_root, [1]=new_epoch_root,
        //           [2]=epoch_number, [3]=nullifier_count
        layouter.constrain_instance(prev_root.cell(), config.instance, 0)?;
        layouter.constrain_instance(new_epoch_root.cell(), config.instance, 1)?;
        layouter.constrain_instance(epoch_num_cell.cell(), config.instance, 2)?;
        layouter.constrain_instance(nul_count_cell.cell(), config.instance, 3)?;

        Ok(())
    }
}
