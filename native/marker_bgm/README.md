# Stella Marker BGM 原生执行器

本目录包含 Stella 唯一的自定义 `AudioStreamPlayback`，用于在同步 BGM stems 上按
sample-frame marker 切换完整混音状态。它被严格限制在物理 `bgm:main` transport 内：

- `AudioPresenter` 仍是唯一 main-thread owner；
- `PresentationDirector` 仍是唯一语义 scheduler 和 receipt owner；
- extension 不创建 thread、player、scheduler、Timer 或 wall-clock poll。

## 设计边界

Godot 4.6 没有公开的实时安全 GDScript API，可以在某个 source sample 上同时修改
`AudioStreamSynchronized` 的所有 child gain。公开 child-gain 调用会跨 Variant/同步边界，
native resampled helper 还会在 extension callback 前预解码内部 chunk。

因此本实现直接拥有一个 OGG playback，并负责：

- 同一 cursor/loop 上的多 stem OGG decode；
- source-rate linear interpolation；
- fixed-capacity POD command/event ring；
- marker occurrence 选择；
- sample H 处的 buffer split；
- 完整 stem gain 的原子切换与 source-frame ramp。

Audio callback 不构造 Godot Variant/Array/Ref，不分配、不加锁、不发 signal、不 deferred call、
不查询 Resource。每个 stem 解码到预分配 chunk；resampler 保存每 stem 的 raw prefetched sample，
因此新 mix 仍能作用于 earliest-not-yet-activated source frame。marker selection 与 pending
persistence 使用相同的 `(source frame, loop epoch)` 坐标，包括 rate>1 callback 中跨过多个
中间 frame 或短 loop 的情况。

restore 会在 playback instantiate 前把 exact arm 写入 stream。`_start()` 在 atomic startup
gate 后发布 command；只有唯一 AudioPresenter 注册 owner 和 paused state 后才释放 gate。
gate 期间 callback 返回完整 requested frame count 的 exact zero PCM，decoder、cursor、command、
event、gain 和 ramp 都不前进，因此 Godot 不会把它误判为 short-buffer stream end。

不支持的正 source step 也采用相同的完整静音 hold，并且必须发生在任何 command/control
consume 之前；恢复支持的速率后，原 queued operation 才在下个 callback boundary 执行。只有
stop、EOF 或 decoder terminal 可以 short-return，而且必须先 settle 已接受的 native operation。

`rt_*_violations` 只是禁止 fallback 路径的 sentinel，不是全进程 allocator/mutex hook。
实时线程边界由以下证据共同约束：

- fixed-storage 实现审查；
- first-party warnings-as-errors build；
- 32-stem decoder refill 上界；
- callback/lifecycle contract tests。

godot-cpp header 作为 compiler `SYSTEM` include。`stb_vorbis` 实现单独编译为 vendor object，
只对 upstream 诊断保留明确列出的 warning exemption；first-party
`register_types.cpp` / `stella_marker_bgm.cpp` 继续开启完整 warnings-as-errors 且没有
`-Wno-*` / `/wd*`。

stb vendor object 仅关闭 MSVC upstream narrowing/sign/shadowing 诊断 C4244、C4245、C4456、
C4457，以及 bounded-reader 的 C4701。GCC/Clang/可用的 MSVC compile database 都经过
`tests/check_marker_bgm_compile_commands.py` 检查作用域。

现有 `AudioPresenter._process()` 只 drain 已由 audio callback 决定并带时间戳的 ring event；
marker 选择和触发完全发生在 callback 中，它不是第二 scheduler。

`configure(Dictionary)` 和 debug test hook 都是内部 FFI。`configure` 严格拒绝缺失、额外、
错误类型、非有限或互相矛盾的字段；项目/作者公开面保持 typed resource 和 operation。
debug hook 只在 `DEBUG_ENABLED` 构建中注册。

marker-capable track 当前要求 imported OGG stems。main-thread preflight 从 Godot 导出的
`OggPacketSequence` 确定性重建 Ogg container，再一次性交给 native stream。普通无 marker
BGM 继续使用既有 OGG/MP3/WAV 路径。

## 构建与发布支持

构建使用 C++17，并固定：

- godot-cpp commit `58d1de720b8ffe9f8ffcdfe3a85148582cfd2e74`；
- Godot 4.6 API / CI 的 Godot 4.6.1 ABI；
- stb_vorbis commit `2c980bb59875b0d32144a71867fbdebb2f77cd20`。

第三方许可证见 `THIRD_PARTY_NOTICES.md` 与 `third_party/stb/LICENSE`。

import/export 前必须构建两个 template：

```bash
tests/build_marker_bgm_native.sh template_debug
tests/build_marker_bgm_native.sh template_release
```

生成库位于 `addons/stella/native/bin/`，属于 ignored build artifact，不是源码。构建完成后，
脚本会把受版本控制的 `addons/stella/native/stella_marker_bgm.gdextension.in` 复制成 active
descriptor。未构建的 clean clone 可以正常 import；只有请求 marker track 时才输出精确构建提示
并 fail-close。

CI 从 clean checkout 构建并验证：

- macOS universal：arm64 + x86_64；
- Linux x86_64；
- Windows x86_64；
- 三平台 debug/release；
- native contract 与 exported-PCK PCM probe；
- per-platform descriptor + binary artifact。

支持新系统/架构前，必须添加确定性 CI binary build 和 export/load smoke，不能静默退化成立即
mix。Godot/godot-cpp ABI 更新时，维护者必须重编两个 template，并在 release provenance 中
保留 native toolchain 与 stb 许可证信息。
