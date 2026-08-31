#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-template_debug}"

case "$target" in
	template_debug)
		build_type="Debug"
		;;
	template_release)
		build_type="Release"
		;;
	*)
		echo "error: target must be template_debug or template_release" >&2
		exit 2
		;;
esac

build_dir="$repo_root/.godot/native/marker_bgm/$target"
build_jobs="${STELLA_NATIVE_BUILD_JOBS:-2}"
descriptor_template="$repo_root/addons/stella/native/stella_marker_bgm.gdextension.in"
descriptor="$repo_root/addons/stella/native/stella_marker_bgm.gdextension"
if [[ ! -f "$descriptor_template" ]]; then
	echo "error: missing marker BGM extension descriptor template" >&2
	exit 1
fi

platform_args=()
if [[ "$(uname -s)" == "Darwin" ]]; then
	platform_args+=(
		'-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64'
		-DSTELLA_BUILD_ARCH=universal
	)
fi
cmake -S "$repo_root/native/marker_bgm" -B "$build_dir" \
	-DCMAKE_BUILD_TYPE="$build_type" \
	-DGODOTCPP_TARGET="$target" \
	-DGODOTCPP_API_VERSION=4.6 \
	-DSTELLA_GODOT_CPP_COMMIT=58d1de720b8ffe9f8ffcdfe3a85148582cfd2e74 \
	"${platform_args[@]}"
cmake --build "$build_dir" --config "$build_type" --parallel "$build_jobs"
cp -- "$descriptor_template" "$descriptor"
