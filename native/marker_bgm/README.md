# Stella marker BGM native playback

This directory contains Stella's one custom `AudioStreamPlayback` for
sample-frame marker switching across synchronized BGM stems. It is deliberately
limited to the physical `bgm:main` transport: `AudioPresenter` remains the sole
main-thread owner and `PresentationDirector` remains the sole semantic
scheduler/receipt owner. The extension does not create a thread, player,
scheduler, timer, or wall-clock poll.

## Design boundary

Godot 4.6 does not expose a real-time-safe way for GDScript to change all
children of `AudioStreamSynchronized` at a source-sample boundary. Its public
child-gain calls cross Variant/locking boundaries, while the native resampled
playback helper predecodes an internal chunk before calling extension code.
Consequently this implementation owns one direct OGG playback, source-rate
linear interpolation, loop cursor, fixed-capacity POD command/event rings, and
the atomic stem-gain ramp. The audio callback performs no Godot Variant/Array
construction, allocation, lock, signal, deferred call, or resource lookup.
Each stem decodes into a fixed preallocated chunk; the resampler keeps raw
per-stem prefetched samples so a new mix can still apply at the earliest
not-yet-activated source frame. Selection and pending persistence use the same
exact `(source frame, loop epoch)` coordinate, including rate>1 callbacks that
activate several intermediate frames or cross multiple short loops. Restore
stores its exact arm in the stream before playback instantiation; `_start()`
publishes that command behind an atomic silent full-buffer hold which the sole
AudioPresenter releases only after registering the owner and paused state. A
callback during the hold returns the complete requested frame count as exact
zero PCM while decoder, cursor, command, event, gain, and ramp state remain
unchanged, so Godot never mistakes the hold for a short-buffer stream end. The
same full-buffer silence contract applies to an unsupported positive source
step before any command/control consumption; the queued operation executes
once when a supported rate returns. Only stop, EOF, or a decoder terminal may
short-return, and those paths settle any admitted native operation first. The
`rt_*_violations` fields are explicit
forbidden-fallback sentinels, not process-wide allocator or mutex hooks. The RT
claim is therefore enforced jointly by fixed-storage code review, warning-as-
error native builds, the 32-stem refill bound, and callback lifecycle tests.
godot-cpp headers are compiler `SYSTEM` includes. The stb implementation is a
separate vendor object with its documented upstream-only warning exemptions;
the first-party `register_types.cpp` and `stella_marker_bgm.cpp` compile with
`-Wall -Wextra -Werror` and no `-Wno-*`, or MSVC `/W4 /WX` and no `/wd*`.
Only the stb object disables MSVC's upstream narrowing/sign and shadowing
diagnostics (C4244/C4245 and C4456/C4457), plus its bounded-reader
potentially-uninitialized diagnostic (C4701). A compile-command gate checks
the exact boundary after every GCC/Clang build and whenever the MSVC generator
provides a compile database.
The existing `AudioPresenter._process()` only drains already timestamped ring
events; marker selection and triggering happen solely at an audio callback
boundary.

`StellaMarkerBgmStream.configure(Dictionary)` and playback control methods are
internal FFI. `configure` rejects any missing, extra, mistyped, non-finite, or
inconsistent field; the public project/author surface remains typed
`BgmTrackDefinition` / `BgmMarkerDefinition`. `debug_*` methods are bound only
when Godot compiles the extension with `DEBUG_ENABLED`.

Marker-capable tracks currently require imported OGG stems. Main-thread
preflight deterministically rebuilds an Ogg container from Godot's exported
`OggPacketSequence`; the audio callback receives immutable byte storage.
Ordinary non-marker BGM keeps the existing OGG/MP3/WAV path.

## Build and release support

The build uses C++17 and is pinned to godot-cpp commit
`58d1de720b8ffe9f8ffcdfe3a85148582cfd2e74`, the Godot 4.6 API and Stella's
Godot 4.6.1 CI ABI. It vendors `stb_vorbis.c` from stb commit
`2c980bb59875b0d32144a71867fbdebb2f77cd20`. See
`THIRD_PARTY_NOTICES.md` and `third_party/stb/LICENSE`.

Build both templates before import/export:

```bash
tests/build_marker_bgm_native.sh template_debug
tests/build_marker_bgm_native.sh template_release
```

Generated libraries live under `addons/stella/native/bin/` and are ignored,
not source artifacts. The build copies the checked-in
`stella_marker_bgm.gdextension.in` to the active `.gdextension` descriptor only
after compiling; an unbuilt clean clone therefore imports without a missing-
library loader error, while requesting a marker track reports the exact build
requirement and fails closed. CI builds macOS universal (arm64+x86_64), Linux
x86_64, and Windows x86_64 debug/release libraries from clean checkouts, runs
the native and exported-PCK PCM probes on each host, and publishes the generated
descriptor plus binaries as per-platform artifacts. Shipping another
OS/architecture requires adding a deterministic CI-built library entry and an
export/load smoke; do not silently fall back to immediate mix.
Maintainers must rebuild both templates for godot-cpp/Godot ABI changes and
carry the native compiler/toolchain plus stb license in release provenance.
