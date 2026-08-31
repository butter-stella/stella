# Stella

> [!WARNING]
> **Work in Progress:** Stella is still under active development. APIs, features, and documentation may change before a stable release.

A Godot 4.6 visual-novel framework built around a typed authoring DSL and
independent presentation systems.

## Features

- **Custom DSL** (`.stla`) — writer-friendly scripting with smart defaults
- **Scenario Engine** — extensible command-pattern architecture
- **Dialogue System** — typewriter, ADV/NVL/overlay modes, inline `[expr:expression]` and `{wait}/{speed}` markers
- **`@combine` blocks** — group multiple voice segments and named-stage cues into one logical dialogue with a continuous typewriter and shared progress
- **Named Stage System** — arbitrary reusable character/event/SD layers, stable asset/body/face channels, transforms, redraw filters, transitions, and exact save-state projection
- **Dialogue Avatars** — inline `[expr:expression]` markers update the cropped dialogue portrait without implicitly mutating the stage
- **Background System** — double-buffered fade / dissolve / wipe transitions
- **Audio System** — BGM/SE/voice with per-character volume, sequential voice queue, replay, voice progress signal
- **Native Movies** — concise typed `@movie` playback for native OGV, with independent volume and exact save/load cursors
- **Choice System** — abstract presenter, supports custom UI styles
- **Variable System** — 3 scopes (global / scenario / temp), expression evaluator
- **Save System** — snapshot-based save/load with multiple slots, auto-save, quick-save, continue
- **Settings System** — text speed, auto-play, skip, volume, per-character voice
- **Playback Control** — auto-play, skip (read-only), read-flag tracking, backlog with sequential voice replay
- **Game State Machine** — title / playing / save-load / backlog / settings overlays
- **Voice Bookmarks** — collect and replay voice lines
- **Gallery System** — illustration / BGM / scene unlock tracking
- **Localization** — multi-locale key-value translation

## Tech Stack

- Godot 4.6+, GDScript
- GUT for unit and integration testing

## Quick Start

1. Clone this repository
2. Open `project.godot` in Godot 4.6+
3. Press F5 to run the demo

## Project Structure

```
addons/stella/                        ← 框架插件（一般不需要修改）
├── autoload/
│   ├── signal_bus.gd                  ← 信号总线（Core↔Presentation 通信）
│   └── stella_runtime.gd             ← 框架入口（加载配置、注册 handler、管理生命周期）
├── core/                              ← 核心层（纯逻辑，不依赖 Godot 渲染）
│   ├── config/                        ← 项目配置加载（stella.cfg）
│   ├── data/                          ← 数据模型（CommandData, ScenarioData 等）
│   ├── script_parser/                 ← DSL 解析器（.stla → 内部数据结构）
│   ├── scenario_engine/               ← 剧情引擎（主循环、上下文、等待控制）
│   ├── commands/                      ← 命令处理器（对话/舞台/背景/音频/特效...）
│   ├── variable_system/               ← 变量系统 + 表达式求值
│   ├── save_system/                   ← 存档/读档
│   ├── settings/                      ← 游戏设置
│   ├── playback/                      ← 自动播放/快进/已读/Backlog
│   ├── state/                         ← 游戏状态机
│   ├── bookmark/                      ← 语音收藏
│   ├── gallery/                       ← 插画/BGM 解锁管理
│   └── localization/                  ← 多语言本地化
├── presentation/                      ← 表现层（Godot UI/渲染/音频）
│   ├── dialogue/                      ← 对话框 + 打字机 + NVL/overlay
│   ├── background/                    ← 背景 + fade 转场
│   ├── stage/                         ← 动态命名舞台层 + 转场/滤镜
│   ├── choice/                        ← 选项按钮
│   ├── audio/                         ← BGM/SE/voice 播放
│   ├── movie/                         ← Runtime-owned 原生 OGV 电影播放
│   ├── effects/                       ← 屏幕淡入淡出 + shake/flash
│   ├── input/                         ← 鼠标/键盘输入处理
│   └── ui/                            ← 标题/存档/设置/Backlog 界面
├── scenes/                            ← 内置场景（title.tscn, game.tscn）
├── stella_plugin.gd                  ← 编辑器插件（注册 Autoload、设置主场景）
└── plugin.cfg

stella.cfg                            ← 项目配置文件（标题/路径/功能开关）
examples/demo/                         ← 示例项目
├── scenarios/                         ← .stla 剧本
├── video/                             ← 原生电影资源（OGV）
└── art/                               ← 素材（背景/头像/舞台层）

tests/                                 ← GUT 测试
├── unit/                              ← 单元测试
└── integration/                       ← 端到端集成测试
```

**日常工作流：** 写 `.stla` 剧本 + 放素材 + 编辑 `stella.cfg` → F5 运行。

## Docs

- [Usage Guide](docs/USAGE.md) — 安装、快速上手、配置文件、Facade API、自定义扩展
- [DSL Reference](docs/DSL.md) — DSL 语法、智能默认值、`@combine` 合并对话、完整示例
- [Architecture](docs/ARCHITECTURE.md) — 三层架构、命令处理器、状态机
- [Input System Design](docs/INPUT_DESIGN.md) — 鼠标推进 + 工具栏按钮共存的输入路由方案
- [Research](docs/RESEARCH.md) — 竞品调研、语法对比

## License

MIT
