#!/usr/bin/env bash
set -uo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  tests/run_gut.sh full' \
    '  tests/run_gut.sh focused res://path/test_file.gd [more scripts...]' \
    '  tests/run_gut.sh case res://path/test_file.gd test_method' \
    '  tests/run_gut.sh dir res://tests/directory [more directories...]' \
    '  tests/run_gut.sh rendering'
}

if (( $# == 0 )); then
  usage >&2
  exit 2
fi

godot_bin=${GODOT_BIN:-godot}
mode=$1
shift
runner_args=()
godot_args=(--audio-driver Dummy)

case "$mode" in
  full)
    (( $# == 0 )) || { usage >&2; exit 2; }
    runner_args+=(--full)
    ;;
  focused)
    (( $# > 0 )) || { usage >&2; exit 2; }
    for path in "$@"; do
      runner_args+=("--test=$path")
    done
    ;;
  case)
    (( $# == 2 )) || { usage >&2; exit 2; }
    runner_args+=("--case=$1::$2")
    ;;
  dir)
    (( $# > 0 )) || { usage >&2; exit 2; }
    for path in "$@"; do
      runner_args+=("--dir=$path")
    done
    ;;
  rendering)
    (( $# == 0 )) || { usage >&2; exit 2; }
    runner_args+=(--dir=res://tests/rendering)
    if [[ -n ${STELLA_EXPECT_RENDERING_METHOD:-} ]]; then
      godot_args+=(--rendering-method "$STELLA_EXPECT_RENDERING_METHOD")
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ ${STELLA_EXACT_GUT_STARTUP_WARNING_PROBE:-0} == 1 ]]; then
  runner_args+=(--startup-warning-probe)
fi

raw_log=${STELLA_GUT_RAW_LOG:-}
if [[ -z $raw_log ]]; then
  log_dir=.godot/stella_test_logs
  mkdir -p "$log_dir"
  raw_log=$log_dir/"$mode"-"$(date -u +%Y%m%dT%H%M%SZ)"-$$.log
else
  mkdir -p "$(dirname "$raw_log")"
fi
printf 'Stella exact GUT raw log: %s\n' "$raw_log"

godot_command=("$godot_bin" "${godot_args[@]}" --path .)
if [[ $mode != rendering ]]; then
  godot_command+=(--headless)
fi
godot_command+=(-s tests/helpers/exact_gut_runner.gd -- "${runner_args[@]}")

set +e
STELLA_DISABLE_LOCAL_CONFIG=${STELLA_DISABLE_LOCAL_CONFIG:-1} \
STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD=${STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD:-1} \
  "${godot_command[@]}" 2>&1 | tee "$raw_log"
pipeline_status=("${PIPESTATUS[@]}")
godot_status=${pipeline_status[0]}
tee_status=${pipeline_status[1]}

shell_gate_status=0
if [[ $tee_status -ne 0 ]]; then
  printf 'Stella exact GUT shell gate: tee could not preserve the raw log (status %d)\n' \
    "$tee_status" >&2
  shell_gate_status=1
fi

marker_prefix='STELLA_EXACT_GUT_FINAL '
marker_count=$(awk -v prefix="$marker_prefix" 'index($0, prefix) == 1 { count += 1 } END { print count + 0 }' "$raw_log")
marker_status=$?
if [[ $marker_status -ne 0 ]]; then
  printf 'Stella exact GUT shell gate: could not inspect final marker (status %d)\n' \
    "$marker_status" >&2
  marker_count=0
  shell_gate_status=1
fi
if [[ $marker_count -ne 1 ]]; then
  printf 'Stella exact GUT shell gate: expected one final marker, got %s\n' "$marker_count" >&2
  shell_gate_status=1
fi

tail_count=$(awk -v prefix="$marker_prefix" '
  index($0, prefix) == 1 { after = 1; next }
  after && $0 !~ /^[[:space:]]*$/ { count += 1 }
  END { print count + 0 }
' "$raw_log")
tail_status=$?
if [[ $tail_status -ne 0 ]]; then
  printf 'Stella exact GUT shell gate: could not inspect shutdown tail (status %d)\n' \
    "$tail_status" >&2
  tail_count=0
  shell_gate_status=1
fi
if [[ $tail_count -ne 0 ]]; then
  printf 'Stella exact GUT shell gate: %s non-empty line(s) followed the final marker\n' "$tail_count" >&2
  shell_gate_status=1
fi

if [[ $godot_status -ne 0 ]]; then
  exit "$godot_status"
fi
exit "$shell_gate_status"
