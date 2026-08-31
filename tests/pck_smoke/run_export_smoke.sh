#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
root_preset="$repo_root/export_presets.cfg"
root_local="$repo_root/stella.local.cfg"
root_project="$repo_root/project.godot"
fixture_preset="$repo_root/tests/fixtures/pck_smoke/export_presets.cfg"
smoke_root=""
project_backup=""
project_metadata=""
installed_fixture=0
installed_local=0
installed_probe_main=0

cleanup() {
	local test_status=$?
	local cleanup_status=0
	trap - EXIT INT TERM HUP
	set +e

	if (( installed_probe_main == 1 )); then
		if restore_project_main; then
			installed_probe_main=0
		else
			cleanup_status=125
		fi
	fi
	if (( installed_fixture == 1 )); then
		if ! rm -f -- "$root_preset"; then
			echo "error: could not remove temporary export_presets.cfg" >&2
			cleanup_status=125
		fi
	fi
	if (( installed_local == 1 )); then
		if ! rm -f -- "$root_local"; then
			echo "error: could not remove temporary stella.local.cfg" >&2
			cleanup_status=125
		fi
	fi
	if (( cleanup_status == 0 )) && [[ -n "$smoke_root" && -d "$smoke_root" ]]; then
		if ! rm -rf -- "$smoke_root"; then
			echo "error: could not remove export-smoke temporary directory" >&2
			cleanup_status=125
		fi
	fi
	if (( cleanup_status != 0 )); then
		echo \
			"error: export-smoke cleanup failed after test status $test_status; retained $smoke_root" \
			>&2
		exit "$cleanup_status"
	fi
	exit "$test_status"
}

project_file_metadata() {
	local path="$1"
	case "$(uname -s)" in
		Darwin)
			stat -f '%Lp:%u:%g:%m' -- "$path"
			;;
		*)
			stat -c '%a:%u:%g:%Y' -- "$path"
			;;
	esac
}

install_export_probe_main() {
	local canonical_main='run/main_scene="res://addons/stella/scenes/bootstrap.tscn"'
	local probe_main='run/main_scene="res://tests/fixtures/pck_smoke/export_probe_host.tscn"'
	local probe_project="$smoke_root/project.godot.probe"
	local canonical_count
	local main_scene_count

	canonical_count="$(awk -v expected="$canonical_main" \
		'$0 == expected { count += 1 } END { print count + 0 }' \
		"$root_project")"
	main_scene_count="$(awk \
		'/^run\/main_scene=/ { count += 1 } END { print count + 0 }' \
		"$root_project")"
	if [[ "$canonical_count" != "1" || "$main_scene_count" != "1" ]]; then
		echo \
			"error: expected exactly the canonical project main scene; found $canonical_count canonical and $main_scene_count total" \
			>&2
		exit 1
	fi
	project_metadata="$(project_file_metadata "$root_project")"
	cp -a -- "$root_project" "$project_backup"
	if ! cmp -s -- "$root_project" "$project_backup"; then
		echo "error: project.godot backup differs from its source" >&2
		exit 1
	fi
	installed_probe_main=1
	awk -v current="$canonical_main" -v replacement="$probe_main" \
		'{ print ($0 == current ? replacement : $0) }' \
		"$project_backup" > "$probe_project"
	if [[ "$host_os" == "Darwin" ]]; then
		if grep -Eq '^\[rendering\]$|^textures/vram_compression/import_etc2_astc=' \
			"$project_backup"; then
			echo "error: export probe expected no pre-existing rendering override" >&2
			exit 1
		fi
		printf '%s\n' \
			'' \
			'[rendering]' \
			'' \
			'textures/vram_compression/import_etc2_astc=true' \
			>> "$probe_project"
	fi
	if cmp -s -- "$project_backup" "$probe_project"; then
		echo "error: export probe main-scene replacement made no change" >&2
		exit 1
	fi
	cp -- "$probe_project" "$root_project"
}

restore_project_main() {
	local restored_metadata

	if (( installed_probe_main == 0 )); then
		return
	fi
	if ! cp -a -- "$project_backup" "$root_project"; then
		echo "error: could not restore project.godot" >&2
		return 1
	fi
	if ! cmp -s -- "$project_backup" "$root_project"; then
		echo "error: project.godot was not restored exactly" >&2
		return 1
	fi
	if ! restored_metadata="$(project_file_metadata "$root_project")"; then
		echo "error: could not inspect restored project.godot metadata" >&2
		return 1
	fi
	if [[ "$restored_metadata" != "$project_metadata" ]]; then
		echo \
			"error: project.godot metadata changed ($project_metadata -> $restored_metadata)" \
			>&2
		return 1
	fi
	installed_probe_main=0
}

append_native_host_export_preset() {
	local platform="$1"
	local preset_index_count

	preset_index_count="$(awk \
		'$0 == "[preset.3]" { count += 1 } END { print count + 0 }' \
		"$root_preset")"
	if [[ "$preset_index_count" != "0" ]]; then
		echo "error: temporary native-host preset index is already occupied" >&2
		exit 1
	fi
	printf '%s\n' \
		'' \
		'[preset.3]' \
		'' \
		'name="Stella PCK Native Host"' \
		"platform=\"$platform\"" \
		'runnable=false' \
		'dedicated_server=false' \
		'custom_features=""' \
		'export_filter="all_resources"' \
		'include_filter="stella.cfg,stella.local.cfg,tests/fixtures/scenarios/dialogue/presentation_profile.stla,tests/fixtures/movies/*.ogv"' \
		'exclude_filter="stella.local.cfg"' \
		'export_path=""' \
		'script_export_mode=1' \
		'' \
		'[preset.3.options]' \
		>> "$root_preset"
	case "$platform" in
		macOS)
			printf '%s\n' \
				'application/bundle_identifier="org.stella.exportsmoke"' \
				'binary_format/architecture="universal"' \
				'codesign/codesign=1' \
				'codesign/identity_type=0' \
				>> "$root_preset"
			;;
	esac
}

normalize_temporary_export_presets() {
	local normalized_preset="$smoke_root/export_presets.normalized.cfg"
	local platform_count
	local preset_count
	local runnable_count

	preset_count="$(awk \
		'/^\[preset\.[0-9]+\]$/ { count += 1 } END { print count + 0 }' \
		"$root_preset")"
	platform_count="$(awk \
		'/^platform=/ { count += 1 } END { print count + 0 }' \
		"$root_preset")"
	runnable_count="$(awk \
		'/^runnable=/ { count += 1 } END { print count + 0 }' \
		"$root_preset")"
	if [[ "$preset_count" != "3" || "$platform_count" != "3" || "$runnable_count" != "0" ]]; then
		echo \
			"error: unexpected export fixture shape ($preset_count presets, $platform_count platforms, $runnable_count runnable fields)" \
			>&2
		exit 1
	fi
	awk \
		'{ print; if ($0 ~ /^platform=/) print "runnable=false" }' \
		"$root_preset" > "$normalized_preset"
	cp -- "$normalized_preset" "$root_preset"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

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
project_backup="$smoke_root/project.godot.original"
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
normalize_temporary_export_presets
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
	if [[ "$probe_mode" == "degraded-title-fallback" ]]; then
		if ! grep -E \
			'^Export probe hardcoded 1e33 oracle: ResourceLoader (accepted|rejected)$' \
			"$run_log"; then
			cat "$run_log"
			echo "error: degraded probe did not report its direct numeric oracle" >&2
			return 1
		fi
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

native_export_dir="$smoke_root/native-export"
native_export_preset="Stella PCK Binary Tokens"
native_platform_label="linux"
mkdir -p "$native_export_dir"
case "$host_os" in
	Darwin)
		native_export_preset="Stella PCK Native Host"
		native_platform_label="macos"
		append_native_host_export_preset "macOS"
		;;
	Linux)
		;;
	*)
		exit 0
		;;
esac

# Official export templates disable scene/path overrides. Put the synthetic
# probe in the exported PCK's own project settings, then launch the artifact
# exactly as a shipped game would start. The trap restores project.godot on
# every exit, and the explicit restore below verifies its original bytes and
# metadata.
install_export_probe_main
for export_kind in debug release; do
	native_export_log="$smoke_root/native-export-$export_kind.log"
	native_run_log="$smoke_root/native-export-$export_kind-run.log"
	native_marker="$smoke_root/native-export-$export_kind.marker"
	case "$host_os" in
		Darwin)
			native_export_path="$native_export_dir/stella-native-$export_kind.app"
			native_executable="$native_export_path/Contents/MacOS/Stella"
			;;
		Linux)
			native_export_path="$native_export_dir/stella-native-$export_kind.x86_64"
			native_executable="$native_export_path"
			;;
	esac
	if ! "$godot_bin" --audio-driver Dummy --headless --path "$repo_root" \
		"--export-$export_kind" "$native_export_preset" \
		"$native_export_path" \
		>"$native_export_log" 2>&1; then
		cat "$native_export_log"
		exit 1
	fi
	if [[ ! -x "$native_executable" ]]; then
		cat "$native_export_log"
		echo "error: full $native_platform_label $export_kind export is not executable" >&2
		exit 1
	fi
	if ! STELLA_EXPORT_PROBE_MODE="config" \
		STELLA_EXPORT_PROBE_MARKER="$native_marker" \
		"$native_executable" \
		--audio-driver Dummy --headless --quit-after 600 \
		>"$native_run_log" 2>&1; then
		cat "$native_run_log"
		exit 1
	fi
	if [[ ! -f "$native_marker" ]] || ! grep -Fxq "config-ok" "$native_marker"; then
		cat "$native_run_log"
		echo \
			"error: full $native_platform_label $export_kind export did not load marker BGM" \
			>&2
		exit 1
	fi
	echo "ok: full-$native_platform_label-native-$export_kind-export (config-ok)"
done
restore_project_main
