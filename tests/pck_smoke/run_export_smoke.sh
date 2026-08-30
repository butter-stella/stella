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

host_os="$(uname -s)"
host_arch="$(uname -m)"
case "$host_os:$host_arch" in
	Darwin:arm64|Darwin:x86_64)
		host_extension="$repo_root/addons/stella/native/bin/libstella_marker_bgm.macos.template_debug.universal.dylib"
		;;
	Linux:x86_64)
		host_extension="$repo_root/addons/stella/native/bin/libstella_marker_bgm.linux.template_debug.x86_64.so"
		;;
	MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
		host_extension="$repo_root/addons/stella/native/bin/stella_marker_bgm.windows.template_debug.x86_64.dll"
		;;
	*)
		echo "error: unsupported export-smoke host $host_os/$host_arch" >&2
		exit 1
		;;
esac
if [[ ! -f "$host_extension" ]]; then
	echo "error: build the host marker BGM extension before export smoke" >&2
	exit 1
fi
# A raw PCK cannot ask the OS loader to mmap an embedded shared library. Keep
# the canonical resource-relative sidecar layout used by an exported game;
# the probe then proves that the PCK contains and loads the .gdextension
# descriptor while the matching host library is present.
mkdir -p "$run_dir/addons/stella/native/bin"
cp -- "$host_extension" "$run_dir/addons/stella/native/bin/"

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

	if ! "$godot_bin" --audio-driver Dummy --headless --path "$repo_root" \
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
			"$godot_bin" --audio-driver Dummy --headless \
			--main-pack "$pack_path" --quit-after 600 \
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

if [[ "$host_os" == "Linux" ]]; then
	native_export_dir="$smoke_root/native-export"
	mkdir -p "$native_export_dir"
	for export_kind in debug release; do
		native_export_log="$smoke_root/native-export-$export_kind.log"
		native_run_log="$smoke_root/native-export-$export_kind-run.log"
		native_marker="$smoke_root/native-export-$export_kind.marker"
		native_executable="$native_export_dir/stella-native-$export_kind.x86_64"
		if ! "$godot_bin" --audio-driver Dummy --headless --path "$repo_root" \
			"--export-$export_kind" "Stella PCK Binary Tokens" \
			"$native_executable" \
			>"$native_export_log" 2>&1; then
			cat "$native_export_log"
			exit 1
		fi
		if ! STELLA_EXPORT_PROBE_MODE="config" \
			STELLA_EXPORT_PROBE_MARKER="$native_marker" \
			"$native_executable" \
			--audio-driver Dummy --headless --quit-after 600 \
			res://tests/fixtures/pck_smoke/export_probe_host.tscn \
			>"$native_run_log" 2>&1; then
			cat "$native_run_log"
			exit 1
		fi
		if [[ ! -f "$native_marker" ]] || ! grep -Fxq "config-ok" "$native_marker"; then
			cat "$native_run_log"
			echo "error: full Linux $export_kind export did not load marker BGM" >&2
			exit 1
		fi
		echo "ok: full-linux-native-$export_kind-export (config-ok)"
	done
fi
