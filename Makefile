SHELL := /bin/bash

ROOT_DIR := $(CURDIR)
RUNTIME_DIR ?= $(ROOT_DIR)/runtime
RUNTIME_INSPECTION ?= $(ROOT_DIR)/.work/runtime.detected.yaml
CANDIDATE_DIR ?= $(ROOT_DIR)/stable/volcano
CANDIDATE_EXPECTED_COMMIT ?= d57d10f47129b11f12d875de1195a42c0a53270f
CANDIDATE_PREFLIGHT ?= $(ROOT_DIR)/.work/candidate-preflight.yaml
CANDIDATE_MISSING_MODULES ?= $(ROOT_DIR)/.work/candidate-missing-modules.txt
CANDIDATE_BENCHMARK_DEPS ?= $(ROOT_DIR)/.work/candidate-benchmark-deps.json
CANDIDATE_BENCHMARK_ASSET_DIR ?= $(ROOT_DIR)/runtime/benchmark-assets
CANDIDATE_BENCHMARK_SOURCES ?= $(ROOT_DIR)/configs/benchmark-assets.sources.json
CANDIDATE_AUDIT_EXPORTER_IMAGE ?= volcanosh/kube-apiserver-audit-exporter:$(CANDIDATE_EXPECTED_COMMIT)
CANDIDATE_REGISTRY_HOST ?= localhost:15001
PERFORMANCE_TOOLS_IMAGE ?= $(CANDIDATE_REGISTRY_HOST)/volcanosh/performance-guard-tools:$(CANDIDATE_EXPECTED_COMMIT)
PERFORMANCE_TOOLS_DOCKERFILE ?= $(ROOT_DIR)/tools/Dockerfile
TOOLS_PYTHON ?= bash $(ROOT_DIR)/scripts/run-performance-tools.sh
CANDIDATE_DEPS_ASSET_DIR ?= $(ROOT_DIR)/.work/offline-assets/go-mod/$(CANDIDATE_EXPECTED_COMMIT)
CANDIDATE_GO_PROXY ?= https://goproxy.cn,direct
STABLE_DIR ?= $(ROOT_DIR)/stable/volcano
STABLE_COMMIT ?= $(shell awk -F= '$$1 == "STABLE_COMMIT" {print $$2; exit}' "$(ROOT_DIR)/stable/stable.env")
STABLE_DEPS_ASSET_DIR ?= $(ROOT_DIR)/.work/offline-assets/go-mod/$(STABLE_COMMIT)
STABLE_RUNNER_IMAGE ?= volcano-stable-runner:$(STABLE_COMMIT)
CANDIDATE_RUNNER_IMAGE ?= volcano-candidate-runner:$(CANDIDATE_EXPECTED_COMMIT)
CANDIDATE_BUILD_DIR ?= $(ROOT_DIR)/.work/candidates/build
CANDIDATE_CLUSTER_NAME ?= volcano-candidate-smoke
CANDIDATE_CLUSTER_STATE ?= $(ROOT_DIR)/.work/clusters/$(CANDIDATE_CLUSTER_NAME)
CANDIDATE_REPORT_DIR ?= $(ROOT_DIR)/.work/reports/$(CANDIDATE_CLUSTER_NAME)
CANDIDATE_COMMUNITY_BENCHMARK_DIR ?= $(CANDIDATE_REPORT_DIR)/community-benchmark
CANDIDATE_AUDIT_CLUSTER_NAME ?= volcano-candidate-audit
CANDIDATE_AUDIT_CLUSTER_STATE ?= $(ROOT_DIR)/.work/clusters/$(CANDIDATE_AUDIT_CLUSTER_NAME)
CANDIDATE_AUDIT_REPORT_DIR ?= $(ROOT_DIR)/.work/reports/$(CANDIDATE_AUDIT_CLUSTER_NAME)
CANDIDATE_AUDIT_PROMETHEUS_PORT ?= 30013
CANDIDATE_AUDIT_GRAFANA_PORT ?= 30014
COMMUNITY_SCENARIO ?= pod
COMMUNITY_COUNT ?= 10
COMMUNITY_SCHEDULER ?= volcano
COMMUNITY_USE_KWOK ?= 0
CONTRACT_DEMO_DIR ?= $(ROOT_DIR)/.work/contract-demo
MOCK_BUNDLE ?= $(ROOT_DIR)/tests/fixtures/mock-bundle
MOCK_ENV_DIR ?= $(CONTRACT_DEMO_DIR)/environment
PROFILE ?= $(ROOT_DIR)/profiles/pr-gate.yaml
TIMESTAMP_PROFILE ?= $(ROOT_DIR)/profiles/offline-timestamp-smoke.yaml
TIMESTAMP_RUN_ID ?= candidate-timestamp-smoke
TIMESTAMP_REPORT_DIR ?= $(CANDIDATE_REPORT_DIR)/timestamp-profile
TIMESTAMP_SUBJECT_TYPE ?= candidate
TIMESTAMP_SUBJECT_VERSION ?=
BASELINE ?=
THRESHOLDS ?= $(ROOT_DIR)/configs/timestamp-thresholds.example.yaml
COMPARISON_DIR ?= $(CANDIDATE_REPORT_DIR)/comparison
CANDIDATE_RELEASE ?= $(ROOT_DIR)/tests/fixtures/candidate-release.yaml
RUN_METRICS_DIR ?= $(ROOT_DIR)/tests/fixtures/run-metrics

PERFORMANCE_GUARD_TOOLS_IMAGE ?= $(PERFORMANCE_TOOLS_IMAGE)
export PERFORMANCE_GUARD_TOOLS_IMAGE

.PHONY: help setup inspect-runtime scan-benchmark-deps stable-prepare-deps stable-import-deps candidate-preflight candidate-prepare-deps package-candidate-deps import-candidate-deps candidate-build-binaries candidate-build-audit-exporter package-performance-tools package-benchmark-assets import-benchmark-assets candidate-build-images candidate-publish-images candidate-create-cluster candidate-create-audit-cluster candidate-deploy candidate-install-monitoring candidate-smoke candidate-community-benchmark candidate-audit-community-benchmark candidate-timestamp-profile compare-baseline candidate-cleanup contract-validate mock-prepare mock-inspect mock-cleanup dry-run aggregate-demo contract-demo test

help:
	@printf '%s\n' \
	  'Volcano performance guard commands' \
	  '' \
	  'Project runtime:' \
	  '  make setup               Download, verify, and install Runtime and stable assets' \
	  '  make inspect-runtime     Inspect the internal runtime without mutating it' \
	  '  make scan-benchmark-deps Scan candidate benchmark dependencies and calculate the offline image delta' \
	  '  make stable-prepare-deps ONLINE: package the stable checkout Go supplement' \
	  '  make stable-import-deps  OFFLINE: import the stable Go supplement Runner' \
	  '  make candidate-preflight Check candidate Git identity, offline Go cache, and base images' \
	  '  make candidate-prepare-deps Discover, package, import, and verify candidate Go modules' \
	  '  make package-candidate-deps  ONLINE: package only missing Candidate Go modules' \
	  '  make import-candidate-deps   OFFLINE: import supplement into a derived Runner' \
	  '  make candidate-build-binaries Build Candidate binaries with Runner network disabled' \
	  '  make candidate-build-audit-exporter Build commit-labelled Audit Exporter offline' \
	  '  make package-performance-tools ONLINE: build the pinned Python/Docker tooling image' \
	  '  make package-benchmark-assets  ONLINE: package Benchmark images and KWOK charts' \
	  '  make import-benchmark-assets   OFFLINE: verify and publish Benchmark assets' \
	  '  make candidate-build-images   Build commit-tagged Candidate images offline' \
	  '  make candidate-publish-images Publish Candidate images to loopback registry' \
	  '  make candidate-create-cluster Create dedicated Kind cluster and block public IPv4' \
	  '  make candidate-create-audit-cluster Create isolated audit-enabled Kind cluster' \
	  '  make candidate-deploy         Deploy the Candidate commit chart and images' \
	  '  make candidate-install-monitoring Install pinned Prometheus/Grafana/KSM/Audit Exporter' \
	  '  make candidate-smoke          Verify image identity and scheduler smoke Job' \
	  '  make candidate-community-benchmark Run offline upstream Benchmark performance detection' \
	  '  make candidate-audit-community-benchmark Run Benchmark with precise audit latency' \
	  '  make candidate-timestamp-profile Run the configured offline Pod timestamp profile and aggregate it' \
	  '  make compare-baseline          Compare aggregated candidate metrics with an approved baseline (BASELINE=...)' \
	  '  make candidate-cleanup        Delete only the marker-matched Candidate cluster' \
	  '' \
	  'Contract utilities:' \
	  '  make contract-validate   Validate schemas, profiles, and fixtures' \
	  '  make contract-demo       Run the side-effect-free contract demo' \
	  '  make mock-prepare        Generate mock environment outputs' \
	  '  make mock-inspect        Inspect the generated mock environment' \
	  '  make dry-run             Render a candidate execution plan' \
	  '  make aggregate-demo      Aggregate normalized metric fixtures' \
	  '  make mock-cleanup        Mark mock adapter state as cleaned' \
	  '  make test                Run repository unit tests'

setup:
	bash setup.sh

inspect-runtime:
	bash adapters/runtime/inspect.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--output "$(RUNTIME_INSPECTION)"

scan-benchmark-deps:
	$(TOOLS_PYTHON) scripts/scan-benchmark-deps.py \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runtime-dir "$(RUNTIME_DIR)" \
		--output "$(CANDIDATE_BENCHMARK_DEPS)"

stable-prepare-deps:
	@test "$(ALLOW_NETWORK)" = "1" || { echo 'Set ALLOW_NETWORK=1 for the explicit online stable dependency preparation phase' >&2; exit 1; }
	bash adapters/runtime/prepare-candidate-deps.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(STABLE_DIR)" \
		--asset-dir "$(STABLE_DEPS_ASSET_DIR)" \
		--runner-image "$(STABLE_RUNNER_IMAGE)" \
		--expected-commit "$(STABLE_COMMIT)" \
		--goproxy "$(CANDIDATE_GO_PROXY)" \
		--embedded-go-mod \
		--allow-network

stable-import-deps:
	bash adapters/runtime/import-version-deps.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--asset-dir "$(STABLE_DEPS_ASSET_DIR)" \
		--runner-image "$(STABLE_RUNNER_IMAGE)" \
		--expected-commit "$(STABLE_COMMIT)"

candidate-preflight:
	@expected_args=(); \
	runner_args=(); \
	if [[ -n "$(CANDIDATE_EXPECTED_COMMIT)" ]]; then \
		expected_args+=(--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)"); \
	fi; \
	if [[ -n "$(CANDIDATE_RUNNER_IMAGE)" ]]; then \
		runner_args+=(--runner-image "$(CANDIDATE_RUNNER_IMAGE)"); \
	fi; \
	bash adapters/runtime/preflight-candidate.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--missing-modules-output "$(CANDIDATE_MISSING_MODULES)" \
		--output "$(CANDIDATE_PREFLIGHT)" \
		"$${expected_args[@]}" \
		"$${runner_args[@]}"

candidate-prepare-deps:
	@network_args=(); \
	if [[ "$(ALLOW_NETWORK)" = "1" ]]; then network_args+=(--allow-network); fi; \
	expected_args=(); \
	if [[ -n "$(CANDIDATE_EXPECTED_COMMIT)" ]]; then expected_args+=(--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)"); fi; \
	bash adapters/runtime/prepare-candidate-deps.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--asset-dir "$(CANDIDATE_DEPS_ASSET_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--preflight-output "$(CANDIDATE_PREFLIGHT)" \
		--missing-modules-output "$(CANDIDATE_MISSING_MODULES)" \
		--output-env "$(ROOT_DIR)/.work/candidate-runner.env" \
		--goproxy "$(CANDIDATE_GO_PROXY)" \
		"$${network_args[@]}" "$${expected_args[@]}"

package-candidate-deps:
	@test "$(ALLOW_NETWORK)" = "1" || { echo 'Set ALLOW_NETWORK=1 for the explicit online packaging phase' >&2; exit 1; }
	@expected_args=(); \
	if [[ -n "$(CANDIDATE_EXPECTED_COMMIT)" ]]; then \
		expected_args+=(--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)"); \
	fi; \
	bash adapters/runtime/package-candidate-deps.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--missing-modules "$(CANDIDATE_MISSING_MODULES)" \
		--output-dir "$(CANDIDATE_DEPS_ASSET_DIR)" \
		--allow-network \
		"$${expected_args[@]}"

import-candidate-deps:
	@runner_args=(); \
	expected_args=(); \
	if [[ -n "$(CANDIDATE_RUNNER_IMAGE)" ]]; then \
		runner_args+=(--runner-image "$(CANDIDATE_RUNNER_IMAGE)"); \
	fi; \
	if [[ -n "$(CANDIDATE_EXPECTED_COMMIT)" ]]; then \
		expected_args+=(--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)"); \
	fi; \
	bash adapters/runtime/import-candidate-deps.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--asset-dir "$(CANDIDATE_DEPS_ASSET_DIR)" \
		"$${runner_args[@]}" \
		"$${expected_args[@]}"

candidate-build-binaries:
	@test -n "$(CANDIDATE_RUNNER_IMAGE)" || { echo 'CANDIDATE_RUNNER_IMAGE is required' >&2; exit 1; }
	@expected_args=(); \
	if [[ -n "$(CANDIDATE_EXPECTED_COMMIT)" ]]; then \
		expected_args+=(--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)"); \
	fi; \
	bash adapters/runtime/build-candidate-binaries.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--output-dir "$(CANDIDATE_BUILD_DIR)" \
		"$${expected_args[@]}"

candidate-build-audit-exporter:
	@test -n "$(CANDIDATE_RUNNER_IMAGE)" || { echo 'CANDIDATE_RUNNER_IMAGE is required' >&2; exit 1; }
	@expected_args=(); \
	if [[ -n "$(CANDIDATE_EXPECTED_COMMIT)" ]]; then \
		expected_args+=(--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)"); \
	fi; \
	bash adapters/runtime/build-candidate-audit-exporter.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--output-dir "$(CANDIDATE_BUILD_DIR)/audit-exporter" \
		"$${expected_args[@]}"

package-performance-tools:
	@test "$(ALLOW_NETWORK)" = "1" || { echo 'Set ALLOW_NETWORK=1 for the explicit online packaging phase' >&2; exit 1; }
	docker build --platform linux/amd64 --network host \
		--build-arg BASE_RUNNER_IMAGE="$(CANDIDATE_RUNNER_IMAGE)" \
		--build-arg CANDIDATE_COMMIT="$(CANDIDATE_EXPECTED_COMMIT)" \
		--build-arg TOOLS_VERSION="performance-guard-tools-v1" \
		-f "$(PERFORMANCE_TOOLS_DOCKERFILE)" \
		-t "$(PERFORMANCE_TOOLS_IMAGE)" \
		"$(ROOT_DIR)"

package-benchmark-assets:
	$(MAKE) package-performance-tools ALLOW_NETWORK=$(ALLOW_NETWORK)
	@test "$(ALLOW_NETWORK)" = "1" || { echo 'Set ALLOW_NETWORK=1 for the explicit online packaging phase' >&2; exit 1; }
	@optional_args=(); \
	if [[ "$(INCLUDE_OPTIONAL)" = "1" ]]; then \
		optional_args+=(--include-optional); \
	fi; \
	if [[ "$(REUSE_LOCAL_IMAGES)" = "1" ]]; then \
		optional_args+=(--reuse-local-images); \
	fi; \
	$(TOOLS_PYTHON) scripts/package-benchmark-assets.py \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--output-dir "$(CANDIDATE_BENCHMARK_ASSET_DIR)" \
		--audit-image "$(CANDIDATE_AUDIT_EXPORTER_IMAGE)" \
		--tools-image "$(PERFORMANCE_TOOLS_IMAGE)" \
		--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)" \
		--registry-host "$(CANDIDATE_REGISTRY_HOST)" \
		--sources "$(CANDIDATE_BENCHMARK_SOURCES)" \
		--allow-network \
		"$${optional_args[@]}"

import-benchmark-assets:
	@test -f "$(CANDIDATE_BENCHMARK_ASSET_DIR)/benchmark-images.tar" || { echo 'Benchmark asset archive is missing' >&2; exit 1; }
	docker load -i "$(CANDIDATE_BENCHMARK_ASSET_DIR)/benchmark-images.tar"
	$(TOOLS_PYTHON) scripts/import-benchmark-assets.py \
		--asset-dir "$(CANDIDATE_BENCHMARK_ASSET_DIR)" \
		--expected-commit "$(CANDIDATE_EXPECTED_COMMIT)" \
		--registry-host "$(CANDIDATE_REGISTRY_HOST)" \
		--skip-registry-probe

candidate-build-images:
	bash adapters/runtime/build-candidate-images.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--build-dir "$(CANDIDATE_BUILD_DIR)"

candidate-publish-images:
	bash adapters/runtime/publish-candidate-images.sh \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--build-dir "$(CANDIDATE_BUILD_DIR)"

candidate-create-cluster:
	@test -n "$(CANDIDATE_RUNNER_IMAGE)" || { echo 'CANDIDATE_RUNNER_IMAGE is required' >&2; exit 1; }
	bash adapters/runtime/create-candidate-cluster.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--cluster-name "$(CANDIDATE_CLUSTER_NAME)" \
		--state-dir "$(CANDIDATE_CLUSTER_STATE)"

candidate-create-audit-cluster:
	@test -n "$(CANDIDATE_RUNNER_IMAGE)" || { echo 'CANDIDATE_RUNNER_IMAGE is required' >&2; exit 1; }
	bash adapters/runtime/create-candidate-audit-cluster.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--cluster-name "$(CANDIDATE_AUDIT_CLUSTER_NAME)" \
		--state-dir "$(CANDIDATE_AUDIT_CLUSTER_STATE)" \
		--asset-dir "$(CANDIDATE_BENCHMARK_ASSET_DIR)" \
		--prometheus-port "$(CANDIDATE_AUDIT_PROMETHEUS_PORT)" \
		--grafana-port "$(CANDIDATE_AUDIT_GRAFANA_PORT)"

candidate-deploy:
	bash adapters/runtime/deploy-candidate.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--cluster-name "$(CANDIDATE_CLUSTER_NAME)" \
		--state-dir "$(CANDIDATE_CLUSTER_STATE)" \
		--report-dir "$(CANDIDATE_REPORT_DIR)"

candidate-install-monitoring:
	bash adapters/runtime/install-candidate-monitoring.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--state-dir "$(CANDIDATE_AUDIT_CLUSTER_STATE)" \
		--asset-dir "$(CANDIDATE_BENCHMARK_ASSET_DIR)" \
		--report-dir "$(CANDIDATE_AUDIT_REPORT_DIR)/monitoring"

candidate-smoke:
	bash adapters/runtime/verify-candidate-smoke.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--cluster-name "$(CANDIDATE_CLUSTER_NAME)" \
		--state-dir "$(CANDIDATE_CLUSTER_STATE)" \
		--report-dir "$(CANDIDATE_REPORT_DIR)"

candidate-community-benchmark:
	@kwok_args=(); \
	if [[ "$(COMMUNITY_USE_KWOK)" = "1" ]]; then \
		kwok_args+=(--asset-dir "$(CANDIDATE_BENCHMARK_ASSET_DIR)" --use-kwok); \
	fi; \
	bash adapters/runtime/run-community-benchmark.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--state-dir "$(CANDIDATE_CLUSTER_STATE)" \
		--output-dir "$(CANDIDATE_COMMUNITY_BENCHMARK_DIR)" \
		--cluster-name "$(CANDIDATE_CLUSTER_NAME)" \
		--scenario "$(COMMUNITY_SCENARIO)" \
		--count "$(COMMUNITY_COUNT)" \
		--scheduler "$(COMMUNITY_SCHEDULER)" \
		"$${kwok_args[@]}"

candidate-audit-community-benchmark:
	@test -n "$(CANDIDATE_RUNNER_IMAGE)" || { echo 'CANDIDATE_RUNNER_IMAGE is required' >&2; exit 1; }
	bash adapters/runtime/run-community-benchmark.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--state-dir "$(CANDIDATE_AUDIT_CLUSTER_STATE)" \
		--output-dir "$(CANDIDATE_AUDIT_REPORT_DIR)/community-benchmark" \
		--cluster-name "$(CANDIDATE_AUDIT_CLUSTER_NAME)" \
		--scenario "$(COMMUNITY_SCENARIO)" \
		--count "$(COMMUNITY_COUNT)" \
		--scheduler "$(COMMUNITY_SCHEDULER)" \
		--prometheus-url "http://127.0.0.1:$(CANDIDATE_AUDIT_PROMETHEUS_PORT)" \
		--require-audit

candidate-timestamp-profile:
	@test -n "$(CANDIDATE_RUNNER_IMAGE)" || { echo 'CANDIDATE_RUNNER_IMAGE is required' >&2; exit 1; }
	$(TOOLS_PYTHON) scripts/run-timestamp-profile.py \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--state-dir "$(CANDIDATE_CLUSTER_STATE)" \
		--cluster-name "$(CANDIDATE_CLUSTER_NAME)" \
		--profile "$(TIMESTAMP_PROFILE)" \
		--run-id "$(TIMESTAMP_RUN_ID)" \
		--report-dir "$(TIMESTAMP_REPORT_DIR)" \
		--subject-type "$(TIMESTAMP_SUBJECT_TYPE)" \
		$(if $(TIMESTAMP_SUBJECT_VERSION),--subject-version "$(TIMESTAMP_SUBJECT_VERSION)",)

compare-baseline:
	@test -n "$(BASELINE)" || { echo 'BASELINE must point to an independently approved aggregated metrics JSON' >&2; exit 1; }
	$(TOOLS_PYTHON) scripts/compare-baseline.py \
		--candidate "$(TIMESTAMP_REPORT_DIR)/metrics.json" \
		--baseline "$(BASELINE)" \
		--thresholds "$(THRESHOLDS)" \
		--output "$(COMPARISON_DIR)/comparison.json" \
		--markdown-output "$(COMPARISON_DIR)/comparison.md" \
		--junit-output "$(COMPARISON_DIR)/comparison.junit.xml" \
		--html-output "$(COMPARISON_DIR)/comparison.html"

candidate-cleanup:
	bash adapters/runtime/cleanup-candidate-cluster.sh \
		--runtime-dir "$(RUNTIME_DIR)" \
		--candidate-dir "$(CANDIDATE_DIR)" \
		--runner-image "$(CANDIDATE_RUNNER_IMAGE)" \
		--cluster-name "$(CANDIDATE_CLUSTER_NAME)" \
		--state-dir "$(CANDIDATE_CLUSTER_STATE)"

contract-validate:
	$(TOOLS_PYTHON) scripts/validate-contracts.py environment tests/fixtures/mock-bundle/environment.json
	$(TOOLS_PYTHON) scripts/validate-contracts.py profile profiles/smoke.yaml profiles/pr-gate.yaml
	$(TOOLS_PYTHON) scripts/validate-contracts.py candidate-release tests/fixtures/candidate-release.yaml
	$(TOOLS_PYTHON) scripts/validate-contracts.py run-metrics \
		tests/fixtures/run-metrics/formal-1.json \
		tests/fixtures/run-metrics/formal-2.json \
		tests/fixtures/run-metrics/formal-3.json

mock-prepare:
	bash adapters/mock/prepare.sh \
		--bundle "$(MOCK_BUNDLE)" \
		--workdir "$(MOCK_ENV_DIR)" \
		--output-env "$(MOCK_ENV_DIR)/environment.env"

mock-inspect: mock-prepare
	bash adapters/mock/inspect.sh --environment "$(MOCK_ENV_DIR)/environment.json"

mock-cleanup:
	bash adapters/mock/cleanup.sh --environment "$(MOCK_ENV_DIR)/environment.json"

dry-run: mock-prepare
	$(TOOLS_PYTHON) scripts/render-run-plan.py \
		--environment "$(MOCK_ENV_DIR)/environment.json" \
		--profile "$(PROFILE)" \
		--candidate "$(CANDIDATE_RELEASE)" \
		--run-id contract-demo \
		--output "$(CONTRACT_DEMO_DIR)/run-plan.json"

aggregate-demo:
	$(TOOLS_PYTHON) scripts/aggregate-metrics.py \
		--input "$(RUN_METRICS_DIR)/formal-1.json" \
		--input "$(RUN_METRICS_DIR)/formal-2.json" \
		--input "$(RUN_METRICS_DIR)/formal-3.json" \
		--expected-runs 3 \
		--run-id contract-demo \
		--output "$(CONTRACT_DEMO_DIR)/metrics.json"

contract-demo: contract-validate dry-run aggregate-demo mock-inspect

test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v
