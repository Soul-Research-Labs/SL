# Soul Privacy Stack — Developer Makefile
# ─────────────────────────────────────────────

.PHONY: all build test lint clean \
        build-sol test-sol lint-sol \
        build-rust test-rust lint-rust \
        build-sdk test-sdk lint-sdk \
        build-noir \
        docker-up docker-down docker-build \
        deploy-fuji deploy-moonbase deploy-astar deploy-evmos deploy-aurora \
        deploy-near deploy-cosmwasm \
        fmt coverage

# ── Composite Targets ──────────────────────────

all: build test

build: build-sol build-rust build-sdk build-noir

test: test-sol test-rust test-sdk

lint: lint-sol lint-rust lint-sdk

clean:
	forge clean
	cargo clean
	cd sdk && rm -rf dist node_modules/.cache

fmt:
	forge fmt
	cargo fmt --all
	cd sdk && npx prettier --write 'src/**/*.ts'

# ── Solidity (Foundry) ────────────────────────

build-sol:
	forge build

test-sol:
	forge test -vvv

test-sol-gas:
	forge test --match-contract GasBenchmark -vvv --gas-report

test-sol-invariant:
	forge test --match-contract InvariantPrivacyPool -vvvv

test-sol-multisig:
	forge test --match-contract MultiSigGovernanceTest -vvv

test-sol-epochmanager:
	forge test --match-contract EpochManagerTest -vvv

test-sol-registry:
	forge test --match-contract UniversalNullifierRegistryTest -vvv

test-sol-libraries:
	forge test --match-path test/Libraries.t.sol -vvv

test-sol-fuzz:
	forge test --match-path 'test/fuzz/*' -vvv

test-sol-fuzz-deep:
	FOUNDRY_FUZZ_RUNS=50000 forge test --match-path 'test/fuzz/*' -vvv

test-sol-fork-fuji:
	forge test --fork-url $${AVALANCHE_FUJI_RPC_URL} --match-contract FujiDeployForkTest -vvv

test-sol-fork-moonbase:
	forge test --fork-url $${MOONBASE_ALPHA_RPC_URL} --match-contract MoonbaseForkTest -vvv

test-sol-fork-shibuya:
	forge test --fork-url $${SHIBUYA_RPC_URL} --match-contract ShibuyaForkTest -vvv

test-sol-fork-evmos:
	forge test --fork-url $${EVMOS_TESTNET_RPC_URL} --match-contract EvmosForkTest -vvv

test-sol-fork-aurora:
	forge test --fork-url $${AURORA_TESTNET_RPC_URL} --match-contract AuroraForkTest -vvv

test-sol-fork:
	@echo "Running fork tests (set RPC URL env vars first)"
	-$(MAKE) test-sol-fork-fuji
	-$(MAKE) test-sol-fork-moonbase
	-$(MAKE) test-sol-fork-shibuya
	-$(MAKE) test-sol-fork-evmos
	-$(MAKE) test-sol-fork-aurora

test-sol-integration:
	forge test --match-path 'test/integration/*' -vvv

lint-sol:
	forge fmt --check

coverage:
	forge coverage --report lcov

# ── Rust (Cargo workspace) ────────────────────

build-rust:
	cargo build --workspace

test-rust:
	cargo test --workspace

lint-rust:
	cargo clippy --workspace -- -D warnings
	cargo fmt --all --check

build-relayer:
	cargo build -p soul-relayer --release

build-lumora:
	cargo build -p lumora-coprocessor --release

run-relayer:
	cargo run -p soul-relayer -- --config relayer/config.example.toml

run-lumora:
	cargo run -p lumora-coprocessor -- serve --port 8080

# ── Noir Circuits ─────────────────────────────

build-noir:
	@for dir in circuits/*/; do \
		echo "Building $$dir ..."; \
		cd "$$dir" && nargo build && cd ../..; \
	done

test-noir:
	@for dir in circuits/*/; do \
		echo "Testing $$dir ..."; \
		cd "$$dir" && nargo test && cd ../..; \
	done

# ── TypeScript SDK ────────────────────────────

build-sdk:
	cd sdk && npm run build

test-sdk:
	cd sdk && npm test

lint-sdk:
	cd sdk && npm run lint

install-sdk:
	cd sdk && npm install

# ── Python SDK ────────────────────────────────

test-python:
	cd sdks/python && python -m pytest tests/ -v

lint-python:
	cd sdks/python && python -m ruff check src/ tests/

# ── Subgraph ──────────────────────────────────

subgraph-configure:
	@echo "Set PRIVACY_POOL, EPOCH_MANAGER, GOVERNANCE_TIMELOCK, START_BLOCK, NETWORK"
	cd subgraph && bash configure.sh

# ── Docker ────────────────────────────────────

docker-build:
	docker compose build

docker-up:
	docker compose up -d

docker-down:
	docker compose down

docker-logs:
	docker compose logs -f

# ── Testnet Deployments ───────────────────────

deploy-fuji:
	forge script script/DeployAvalanche.s.sol --rpc-url $${FUJI_RPC_URL} --broadcast --verify

deploy-moonbase:
	forge script script/DeployMoonbeam.s.sol --rpc-url $${MOONBASE_RPC_URL} --broadcast --verify

deploy-astar:
	forge script script/DeployAstar.s.sol --rpc-url $${SHIBUYA_RPC_URL} --broadcast --verify

deploy-evmos:
	forge script script/DeployEvmos.s.sol --rpc-url $${EVMOS_TESTNET_RPC_URL} --broadcast --verify

deploy-aurora:
	forge script script/DeployAurora.s.sol --rpc-url $${AURORA_TESTNET_RPC_URL} --broadcast --verify

deploy-near:
	bash script/deploy-near.sh

deploy-cosmwasm:
	bash script/deploy-cosmwasm.sh

# ── SDK Documentation ──────────────────────────

docs-sdk:
	cd sdk && npm run docs

# ── Certora Formal Verification ───────────────

verify-pool:
	certoraRun certora/conf/PrivacyPool.conf

verify-registry:
	certoraRun certora/conf/NullifierRegistry.conf

verify-multisig:
	certoraRun certora/conf/MultiSigGovernance.conf

verify-timelock:
	certoraRun certora/conf/GovernanceTimelock.conf

verify-compliance:
	certoraRun certora/conf/ComplianceOracle.conf

verify-bridges:
	certoraRun certora/conf/BridgeAdapters.conf

verify-all: verify-pool verify-registry verify-multisig verify-timelock verify-compliance verify-bridges

# ── Help ──────────────────────────────────────

help:
	@echo "Soul Privacy Stack — Available targets:"
	@echo ""
	@echo "  build            Build everything (sol + rust + sdk + noir)"
	@echo "  test             Run all tests (sol + rust + sdk)"
	@echo "  lint             Lint all code"
	@echo "  fmt              Format all code"
	@echo "  clean            Clean build artifacts"
	@echo "  coverage         Solidity test coverage (lcov)"
	@echo ""
	@echo "  build-sol        Build Solidity contracts"
	@echo "  test-sol         Run Foundry tests"
	@echo "  test-sol-gas     Gas benchmarks"
	@echo "  test-sol-invariant  Invariant/fuzz tests"
	@echo "  test-sol-fuzz    Fuzz tests (MerkleTree + DomainNullifier)"
	@echo "  test-sol-fuzz-deep  Fuzz tests (50K runs)"
	@echo "  test-sol-fork    Fork tests (all chains, set RPC URLs)"
	@echo "  test-sol-integration  Integration lifecycle tests"
	@echo ""
	@echo "  build-rust       Build Rust workspace"
	@echo "  test-rust        Run Rust tests"
	@echo "  build-relayer    Build relayer binary (release)"
	@echo "  build-lumora     Build coprocessor binary (release)"
	@echo "  run-relayer      Run relayer with example config"
	@echo "  run-lumora       Run coprocessor HTTP service"
	@echo ""
	@echo "  build-sdk        Build TypeScript SDK"
	@echo "  test-sdk         Run SDK Jest tests"
	@echo "  install-sdk      npm install for SDK"
	@echo "  test-python      Run Python SDK tests"
	@echo ""
	@echo "  docker-build     Build Docker images"
	@echo "  docker-up        Start services (relayer + lumora + prometheus)"
	@echo "  docker-down      Stop services"
	@echo ""
	@echo "  deploy-fuji      Deploy to Avalanche Fuji testnet"
	@echo "  deploy-moonbase  Deploy to Moonbase Alpha"
	@echo "  deploy-astar     Deploy to Shibuya (Astar testnet)"
	@echo "  deploy-evmos     Deploy to Evmos testnet"
	@echo "  deploy-aurora    Deploy to Aurora testnet"
	@echo "  deploy-near      Deploy to NEAR testnet"
	@echo "  deploy-cosmwasm  Deploy to CosmWasm testnet"
	@echo ""
@echo "  docs-sdk         Generate SDK API docs (TypeDoc)"
	@echo ""
	@echo "  verify-pool      Certora: verify PrivacyPool"
	@echo "  verify-registry  Certora: verify NullifierRegistry"
	@echo "  verify-multisig  Certora: verify MultiSigGovernance"
	@echo "  verify-timelock  Certora: verify GovernanceTimelock"
	@echo "  verify-compliance Certora: verify ComplianceOracle"
	@echo "  verify-bridges   Certora: verify BridgeAdapters"
	@echo "  verify-all       Run all Certora specs"
