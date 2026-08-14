#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
root_preset="$repo_root/export_presets.cfg"
root_local="$repo_root/stella.local.cfg"
fixture_preset="$repo_root/tests/fixtures/pck_smoke/export_presets.cfg"
smoke_root=""
installed_fixture=0
installed_local=0

cleanup() {
	if (( installed_fixture == 1 )); then
		rm -f -- "$root_preset"
	fi
	if (( installed_local == 1 )); then
		rm -f -- "$root_local"
	fi
	if [[ -n "$smoke_root" && -d "$smoke_root" ]]; then
		rm -rf -- "$smoke_root"
	fi
}
trap cleanup EXIT

if [[ ! -f "$fixture_preset" ]]; then
	echo "error: missing export preset fixture" >&2
	exit 1
fi

# A repository may later gain real release presets. Keep those authoritative:
# this smoke never overwrites them, and generates only its temporary fixture.
if [[ -e "$root_preset" || -L "$root_preset" ]]; then
	echo "error: refusing to replace existing export_presets.cfg" >&2
	echo "move it aside explicitly before running the CI-only export smoke" >&2
	exit 1
fi
if [[ -e "$root_local" || -L "$root_local" ]]; then
	echo "error: refusing to replace existing stella.local.cfg" >&2
	exit 1
fi

smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/stella-export-smoke.XXXXXX")"
pack_dir="$smoke_root/packs"
run_dir="$smoke_root/outside-source"
mkdir -p "$pack_dir" "$run_dir"

case "$run_dir/" in
	"$repo_root/"*)
		echo "error: export probe must run outside the source directory" >&2
		exit 1
		;;
esac

installed_fixture=1
cp -- "$fixture_preset" "$root_preset"
installed_local=1
printf '%s\n' \
	'[game]' \
	'title = "PCK_LOCAL_CONFIG_MUST_NOT_BE_EXPORTED"' \
	> "$root_local"

run_probe() {
	local preset_name="$1"
	local pack_name="$2"
	local probe_mode="$3"
	local expected_marker="$4"
	local pack_path="$pack_dir/$pack_name.pck"
	local marker_path="$smoke_root/$pack_name.marker"
	local export_log="$smoke_root/$pack_name-export.log"
	local run_log="$smoke_root/$pack_name-run.log"

	if ! "$godot_bin" --headless --path "$repo_root" \
		--export-pack "$preset_name" "$pack_path" >"$export_log" 2>&1; then
		cat "$export_log"
		return 1
	fi
	if [[ ! -s "$pack_path" ]]; then
		echo "error: export did not create $pack_name.pck" >&2
		return 1
	fi

	if ! (
		cd "$run_dir"
		STELLA_EXPORT_PROBE_MODE="$probe_mode" \
		STELLA_EXPORT_PROBE_MARKER="$marker_path" \
			"$godot_bin" --headless --main-pack "$pack_path" --quit-after 600 \
			res://tests/fixtures/pck_smoke/export_probe_host.tscn
	) >"$run_log" 2>&1; then
		cat "$run_log"
		return 1
	fi
	if grep -Eq \
		'PRIVATE_(DEGRADED_TITLE|DEGRADED_GAME|EXT|SUB|VECTOR|PACKED|LEADING|BOM|BODY_TAG|GAME_BODY_TAG|RESOURCE_TAG|NODE_TYPE|SUBRESOURCE_TYPE|PARENT_PATH|OWNER_PATH|ATTRIBUTE|GAME_NODE_TYPE|OVERLAY_PARENT_PATH)' \
		"$run_log"; then
		cat "$run_log"
		echo "error: $pack_name leaked private dependency source" >&2
		return 1
	fi
	if [[ ! -f "$marker_path" ]] || ! grep -Fxq "$expected_marker" "$marker_path"; then
		cat "$run_log"
		echo "error: $pack_name did not produce marker $expected_marker" >&2
		return 1
	fi
	echo "ok: $pack_name ($expected_marker)"
}

run_probe "Stella PCK Binary Tokens" "binary-tokens" "config" "config-ok"
run_probe \
	"Stella PCK Compressed Binary Tokens" \
	"compressed-binary-tokens" \
	"config" \
	"config-ok"
run_probe "Stella PCK Selected Scenes" "selected-scenes" "fallback" "fallback-ok"
run_probe \
	"Stella PCK Compressed Binary Tokens" \
	"compressed-navigation" \
	"navigation-interleaving" \
	"navigation-interleaving-ok"
run_probe \
	"Stella PCK Compressed Binary Tokens" \
	"compressed-degraded" \
	"degraded-title-fallback" \
	"degraded-fallback-ok"
