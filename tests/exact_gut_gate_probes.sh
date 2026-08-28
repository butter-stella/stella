#!/usr/bin/env bash
set -euo pipefail

runner=tests/run_gut.sh
fixture_root=tests/fixtures/exact_gut_runner
generated_malformed=$fixture_root/generated_malformed_test.gd
generated_partial_malformed=$fixture_root/partial/test_z_malformed.gd

for generated_target in "$generated_malformed" "$generated_partial_malformed"; do
	if [[ -e $generated_target || -L $generated_target ]]; then
		printf 'Exact GUT probes: refusing to overwrite existing generated target: %s\n' \
			"$generated_target" >&2
		exit 2
	fi
done

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/stella-exact-gut-probes.XXXXXX")

cleanup() {
  rm -f -- "$generated_malformed"
	rm -f -- "$generated_partial_malformed"
  rm -rf -- "$probe_dir"
}
trap cleanup EXIT

run_probe() {
	local name=$1
	local expected_status=$2
	local expected_reason=$3
	local expected_marker=$4
	local expected_marker_status=$5
	shift 5
  local log=$probe_dir/$name.log
  local status

  set +e
  "$runner" "$@" >"$log" 2>&1
  status=$?
  set -e
  sed -n '1,$p' "$log"

  if [[ $expected_status == zero && $status -ne 0 ]]; then
    printf 'Exact GUT probe %s: expected zero, got %d\n' "$name" "$status" >&2
    exit 1
  fi
	if [[ $expected_status == nonzero && $status -eq 0 ]]; then
		printf 'Exact GUT probe %s: expected nonzero, got zero\n' "$name" >&2
		exit 1
	fi
	if [[ $expected_status =~ ^[0-9]+$ && $status -ne $expected_status ]]; then
		printf 'Exact GUT probe %s: expected status %s, got %d\n' \
			"$name" "$expected_status" "$status" >&2
		exit 1
	fi
	if ! rg -F -- "$expected_reason" "$log" >/dev/null; then
		printf 'Exact GUT probe %s: missing reason: %s\n' "$name" "$expected_reason" >&2
		exit 1
	fi
	local marker_count
	marker_count=$(rg -c '^STELLA_EXACT_GUT_FINAL ' "$log" || true)
	marker_count=${marker_count:-0}
	if [[ $expected_marker == absent && $marker_count -ne 0 ]]; then
		printf 'Exact GUT probe %s: expected no final marker, got %s\n' \
			"$name" "$marker_count" >&2
		exit 1
	fi
	if [[ $expected_marker == present ]]; then
		if [[ $marker_count -ne 1 ]]; then
			printf 'Exact GUT probe %s: expected one final marker, got %s\n' \
				"$name" "$marker_count" >&2
			exit 1
		fi
		if ! rg -F -- "\"status\":\"$expected_marker_status\"" "$log" >/dev/null; then
			printf 'Exact GUT probe %s: final marker did not report %s\n' \
				"$name" "$expected_marker_status" >&2
			exit 1
		fi
	fi
  printf 'Exact GUT probe %s: observed expected %s status (%d)\n' \
    "$name" "$expected_status" "$status"
}

cp "$fixture_root/malformed_test.gd.disabled" "$generated_malformed"
run_probe malformed nonzero \
	"test script could not be parsed/loaded" absent ignored focused \
	res://tests/fixtures/exact_gut_runner/generated_malformed_test.gd
rm -f -- "$generated_malformed"

cp "$fixture_root/partial/test_z_malformed.gd.disabled" "$generated_partial_malformed"
run_probe partial_malformed nonzero \
	"test script could not be parsed/loaded" absent ignored dir \
	res://tests/fixtures/exact_gut_runner/partial
rm -f -- "$generated_partial_malformed"

run_probe empty nonzero \
	"test selection resolved to zero scripts" absent ignored dir \
	res://tests/fixtures/exact_gut_runner/empty
run_probe zero_methods nonzero \
	"preflight collected zero test methods" absent ignored focused \
	res://tests/fixtures/exact_gut_runner/test_zero_methods.gd
run_probe mismatch nonzero \
	"exact method 'test_method_that_does_not_exist' matched 0 collected methods" \
	absent ignored case \
	res://tests/fixtures/exact_gut_runner/test_expected_warning.gd \
	test_method_that_does_not_exist
STELLA_EXACT_GUT_STARTUP_WARNING_PROBE=1 run_probe startup_warning nonzero \
	"preflight emitted 1 unhandled diagnostics" absent ignored focused \
	res://tests/fixtures/exact_gut_runner/test_expected_warning.gd
run_probe expected_warning zero \
	"Stella GUT warnings: raw=1 handled_expected=1 unexpected_unhandled=0" \
	present passed focused \
	res://tests/fixtures/exact_gut_runner/test_expected_warning.gd
run_probe unhandled_warning nonzero \
	"unexpected/unhandled warnings: 1" present failed focused \
	res://tests/fixtures/exact_gut_runner/test_unhandled_warning.gd
run_probe ran_mismatch nonzero \
	"requested methods do not equal ran methods" present failed focused \
	res://tests/fixtures/exact_gut_runner/test_skipped_script.gd
run_probe process_tail nonzero \
	"non-empty line(s) followed the final marker" present passed focused \
	res://tests/fixtures/exact_gut_runner/test_process_tail_warning.gd
GODOT_BIN=$fixture_root/fake_godot_crash.sh run_probe engine_exit 134 \
	"STELLA_EXACT_GUT_FINAL" present passed focused \
	res://tests/fixtures/exact_gut_runner/test_expected_warning.gd
