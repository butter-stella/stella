# Stella Agent 工作规范

## 适用范围与优先级

本文件适用于整个仓库，是当前唯一权威的 Agent 工作指南。`CLAUDE.md`
只用于兼容会自动发现该文件的工具；两者不一致时，以本文件为准。用户指令和系统指令
始终具有更高优先级。

修改子系统前，必须同时阅读实现和对应文档：

- `docs/ARCHITECTURE.md`：分层、所有权与运行时数据流；
- `docs/ARCHITECTURE_REVIEW.md`：已确认的架构风险和演进顺序；
- `docs/DSL.md`：`.stla` 语法与语义；
- `docs/USAGE.md`：公开接入面；
- `docs/INPUT_DESIGN.md`：输入路由和 UI 交互。

不要引用固定的 Handler 数量、测试数量或能力结论，除非已经在当前 checkout 上重新测量。

## 项目与仓库地图

Stella 是基于 Godot 的视觉小说框架。项目声明兼容 Godot 4.6，CI 当前使用 4.6.1，
主要实现语言为 GDScript。只有在确认 Godot 公共 API 存在能力缺口时，才允许引入
GDExtension；同时必须具备明确的设计决策、可复现的多平台构建、许可证审查、导出验证，
并继续服从与 GDScript 表现层相同的 Runtime-owned typed lifecycle。

- `addons/stella/core/`：领域逻辑与运行时协调；
- `addons/stella/presentation/`：UI、渲染、动画和音频节点；
- `addons/stella/autoload/`：`SignalBus` 和组合根 `StellaRuntime`；
- `addons/stella/editor/`：Godot 编辑器集成；
- `addons/stella/scenes/`：框架默认场景；
- `native/`：因 Godot API 缺口而存在的受控原生执行器；
- `examples/demo/`：可再分发的示例内容；
- `tests/unit/`：聚焦的 GUT 测试；
- `tests/integration/`：跨层与 DSL 到运行时测试；
- `docs/`：使用说明、协议和架构文档。

`addons/gut/` 是 vendored 测试基础设施，除非明确升级依赖，否则不要修改。不得手工编辑
生成的 `.godot/` 状态。

## 架构不变量

- 非视觉逻辑放在 `core/`；场景、UI、渲染和物理音频行为放在 `presentation/` 或
  `native/`。Core 可以使用 Godot 基础类型，但不能依赖具体场景布局或具体 UI 节点。
- Core 与 Presentation 的跨层通信必须经过 typed operation 或有文档约束的
  `SignalBus` 端口。新增表现事件时，要同时接通信号、Presenter 和生命周期。
- `StellaRuntime` 是唯一生产组合根，负责构造子系统和注册 Handler。不得增加隐藏的并行
  组合根，也不得让 Core 直接创建具体 Presenter。
- 所有行为都应能沿完整链路追踪：`.stla` 源码 → lexer/parser → 数据模型 →
  CommandHandler → `SignalBus` / `PresentationDirector` → Presenter → 玩家可见结果或输入回执。
- DSL 或命令变更通常需要同步修改解析、数据、Handler 注册、跨层端口、Presenter、测试和
  `docs/DSL.md`。禁止只实现其中一段链路。
- 公共 DSL、配置、存档与扩展 API 都是兼容面。持久化数据发生变化时，必须记录版本、默认值、
  迁移或明确的 fail-close 边界。
- 下游 remake / 游戏项目是 Stella 能力的验证者，不是兼容层。严禁把人物或舞台操作编码成
  背景，严禁在项目里复制 Stella 调度器，也严禁在 importer 中静默猜测未支持语义。
  应记录能力缺口并在 Stella 中实现通用契约。
- `DSL.md`、`USAGE.md`、`ARCHITECTURE.md` 分别描述作者语法、宿主接入、运行时所有权。
  受影响时应同步更新，但不要在多份文档中复制大段功能叙述。

## 实现规则

- 遵循邻近 GDScript 风格：Tab 缩进；文件、函数和变量使用 `snake_case`；`class_name`
  使用 `PascalCase`；公开边界尽量写显式类型。
- 不得用任意 sleep、Timer 或帧等待掩盖竞态。应使用信号、显式 state/generation、取消或
  Tween 终止。只有真正表达玩法时间或场景生命周期时，Timer/帧等待才是合理模型。
- 阻塞型 Handler 必须可取消。优先使用 `CommandHandler.await_with_abort(...)`，避免裸
  `await` 留下无法被新 context 退休的旧连接。
- 不得静默丢弃未知命令、非法状态、缺失资源或 I/O 失败。按 API 契约选择错误机制，并保留
  足够的源码与运行时位置用于诊断。
- 行为变更应优先添加能够准确证明缺失行为的回归测试。测试必须因目标问题而失败，不能只因
  import、preload 等无关问题失败。纯文档、纯配置或机械修改不要求伪造测试。
- 新增受版本控制的 `.gd` 文件时，应保留 Godot 生成的 `.gd.uid` 配套文件；不要手工编造或
  编辑 UID。

## 测试

所有命令从仓库根目录运行。迭代时运行最窄的相关测试；交付前在可行范围内运行完整适用套件。

```bash
# 导入资源并暴露脚本/资源错误。
godot --audio-driver Dummy --headless --import

# 完整 exact GUT 套件。Stella runner 自己拥有显式 manifest，
# 不会把 .gutconfig.json 的选择合并进命令行请求。
STELLA_DISABLE_LOCAL_CONFIG=1 STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD=1 \
	GODOT_BIN=godot tests/run_gut.sh full

# 聚焦单个测试文件。
STELLA_DISABLE_LOCAL_CONFIG=1 STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD=1 \
	GODOT_BIN=godot tests/run_gut.sh focused \
	res://tests/unit/test_scenario_engine.gd

# Godot 4.6.1 导出/PCK smoke；运行时项目根不得已有 export_presets.cfg。
GODOT_BIN=godot tests/pck_smoke/run_export_smoke.sh
```

不要把这些命令包进会掩盖退出码的 pipeline。exact runner 会把 raw log 保存在
`.godot/stella_test_logs/`，校验唯一 final accounting marker，并在 marker 之后出现任何
非空 shutdown tail 时失败。测试不能依赖 `stella.local.cfg`、`user://` 残留、机器专属路径
或私有导入资产。视觉、音频、时序和输入变更还应补充相应 demo/人工路径，并明确没有人工验证
的部分。

如果当前 checkout 已存在无关失败，必须区分既有失败和本次回归并分别报告；只有当前环境中
实际运行且通过，才能声称套件为绿色。

## Git 与私有内容安全

- 开始前检查 `git status --short` 和当前分支。保留所有既有修改，在 dirty worktree 中绕开
  无关改动。
- 未经明确要求，不得 reset、丢弃、覆盖或 stash 他人的改动。只 stage 本任务文件。
- commit 前再次确认分支。新分支遵循既有 `feat/`、`fix/`、`docs/`、`refactor/` 或
  `chore/` 命名方式。
- 未经用户授权，不得 commit、push、创建/更新 PR、创建 Issue 或 merge。
- LLLJ、L3J 等专有游戏包只能作为本地验证输入。不得提交或公开解包资产、音乐、剧本、生成场景、
  私有路径或衍生 fixture。公开测试与示例必须使用 synthetic 或明确可再分发的内容。
- `stella.local.cfg` 等本地覆盖和生成的私有内容不得进入 commit。

## Review 与 Pull Request

按风险比例审查改动：正确性、边界条件、Godot API、signal/async 时序、取消、状态恢复、下游
兼容、测试缺口和完整端到端接线。修复 review finding 后重新运行相关测试。

聚焦修复中不要顺带进行大规模重构。如果更优架构会显著扩大范围，先展示取舍并取得用户方向。

创建 PR 时，正文应简洁覆盖：

- 修改内容；
- 风险或有意接受的取舍；
- 已运行的测试与人工验证。

没有用户明确授权时，不得合并 PR。
