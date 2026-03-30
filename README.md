# Natsume

Godot AVG / Galgame framework — the first open-source Godot framework with commercial-grade Japanese visual novel features.

## Features

- **Custom DSL** (`.nat`) — writer-friendly scripting with smart defaults
- **Scenario Engine** — command-pattern architecture, fully extensible
- **Dialogue System** — typewriter effect, ADV/NVL/overlay modes, inline expression switching
- **Character System** — show/hide/move/animate, expression switching, position presets
- **Background System** — double-buffered with fade transitions
- **Audio System** — BGM/SE/voice with per-character volume control
- **CG System** — fullscreen/SD/animated/differential CG
- **Choice System** — abstract presenter, supports custom UI styles
- **Variable System** — 3 scopes (global/scenario/temp), expression evaluator
- **Save System** — snapshot-based save/load with multiple slots
- **Settings System** — text speed, auto-play, skip, volume, per-character voice
- **Playback Control** — auto-play, skip (read-only), read flag tracking, backlog
- **Game State Machine** — title/playing/paused/save-load/backlog/settings
- **Expression Timeline** — voice/text-driven expression switching
- **Voice Bookmarks** — collect and replay voice lines
- **Gallery System** — CG/BGM/scene unlock tracking
- **Localization** — multi-locale key-value translation

## Tech Stack

- Godot 4.6+, GDScript
- GUT for testing (232+ tests)
- Rust via gdext (for performance extensions, when needed)

## Quick Start

1. Clone this repository
2. Open `project.godot` in Godot 4.6+
3. Press F5 to run the POC demo

## Project Structure

```
addons/natsume/                        ← 框架代码（一般不需要修改）
├── autoload/
│   ├── signal_bus.gd                  ← 信号总线（Core↔Presentation 通信）
│   └── natsume_runtime.gd             ← 框架入口（注册 handler、启动剧本）
├── core/                              ← 核心层（纯逻辑，不依赖 Godot 渲染）
│   ├── data/                          ← 数据模型（CommandData, ScenarioData 等）
│   ├── script_parser/                 ← DSL 解析器（.nat → 内部数据结构）
│   ├── scenario_engine/               ← 剧情引擎（主循环、上下文、等待控制）
│   ├── commands/                      ← 18 个命令处理器（对话/背景/立绘/音频/特效...）
│   ├── variable_system/               ← 变量系统 + 表达式求值
│   ├── save_system/                   ← 存档/读档
│   ├── settings/                      ← 游戏设置
│   ├── playback/                      ← 自动播放/快进/已读/Backlog
│   ├── state/                         ← 游戏状态机
│   ├── bookmark/                      ← 语音收藏
│   ├── gallery/                       ← CG/BGM 解锁管理
│   └── localization/                  ← 多语言本地化
├── presentation/                      ← 表现层（Godot UI/渲染/音频）
│   ├── dialogue/                      ← 对话框 + 打字机 + NVL/overlay
│   ├── background/                    ← 背景 + fade 转场
│   ├── character/                     ← 立绘 + 动画 + 移动
│   ├── choice/                        ← 选项按钮
│   ├── audio/                         ← BGM/SE 播放
│   ├── effects/                       ← 屏幕淡入淡出 + shake/flash
│   └── input/                         ← 鼠标/键盘输入处理
└── plugin.cfg

game/                                  ← 游戏内容（日常工作目录）
├── scenarios/                         ← .nat 剧本文件
├── art/
│   ├── backgrounds/                   ← 背景图（@bg bg_name → bg_name.png）
│   └── characters/{角色名}/            ← 立绘（@show sakura smile → sakura/smile.png）
├── audio/
│   ├── bgm/                           ← BGM（@bgm name → name.ogg）
│   ├── se/                            ← 音效（@se name → name.ogg）
│   └── voice/                         ← 语音
├── scenes/                            ← Godot 场景文件
└── scripts/                           ← 游戏启动脚本

tests/                                 ← GUT 测试（232+ 测试用例）
├── unit/                              ← 单元测试
└── integration/                       ← 端到端集成测试
```

**日常工作流：** 写 `.nat` 剧本 + 放素材到对应目录 → 配置路径 → F5 运行。

## Docs

- [Usage Guide](docs/USAGE.md) — 安装、快速上手、资源命名、自定义扩展
- [DSL Design](docs/DSL.md) — DSL 语法详细设计、智能默认值、完整示例
- [Architecture & Plan](docs/PLAN.md) — 架构设计、技术选型、开发路线图
- [Research](docs/RESEARCH.md) — 竞品调研、语法对比

## License

MIT
