# Natsume — 开发进度

> 最后更新：2026-03-29

## 总览

| 指标 | 数量 |
|------|------|
| 已合并 PR | 38 |
| 源代码文件 | 57 个 `.gd` |
| 测试文件 | 23 个 |
| 测试用例 | 240 个，全绿 |
| 断言数 | 474 |

---

## Sprint 完成情况

| Sprint | 内容 | 状态 | PRs |
|--------|------|------|-----|
| Sprint 1 | 核心骨架 + 数据模型 | ✅ 完成 | #14, #15 |
| Sprint 2 | 命令系统 + 剧情引擎 | ✅ 完成 | #16 |
| Sprint 3 | DSL 解析器 | ✅ 完成 | #17, #18 |
| Sprint 4 | 基础表现层（POC） | ✅ 完成 | #20 |
| Sprint 5 | 游戏体验完善 | ✅ 完成 | #22-#26 |
| Sprint 6 | 表现增强 | ✅ 完成 | #27, #28 |
| Sprint 7 | 高级扩展 | ✅ 完成 | #29, #30 |
| Sprint 8 | 开源准备 | ✅ 完成 | #31 |

---

## 已完成的模块

### Core 层（100%）

| 模块 | 文件 | 说明 |
|------|------|------|
| 数据模型 | `core/data/` | CommandData, ScenarioData, SceneData, ChoiceData, CharacterConfig |
| DSL 解析器 | `core/script_parser/` | DslLexer + DslParser，支持全部 DSL 指令 |
| 剧情引擎 | `core/scenario_engine/` | ScenarioEngine 主循环 + ScenarioContext + WaitController + ExpressionTimeline |
| 命令处理器 | `core/commands/` | 18 个 handler（dialogue/bg/char_show/hide/expr/anim/move/choice/jump/condition/set/bgm/se/fade/wait/cg/effect/parallel） |
| 变量系统 | `core/variable_system/` | VariableStore（3 作用域）+ ExpressionEvaluator |
| 存档系统 | `core/save_system/` | SaveManager + 快照协议 |
| 设置系统 | `core/settings/` | GameSettings + SettingsManager |
| 播放控制 | `core/playback/` | AutoPlayController + SkipController + ReadFlagManager + BacklogManager |
| 状态机 | `core/state/` | GameStateMachine（6 种状态） |
| 语音收藏 | `core/bookmark/` | VoiceBookmarkManager |
| 鉴赏管理 | `core/gallery/` | UnlockManager |
| 本地化 | `core/localization/` | LocalizationManager |

### Presentation 层

| 模块 | 文件 | 说明 |
|------|------|------|
| 对话系统 | `presentation/dialogue/` | 打字机效果、ADV/NVL/overlay 三种模式、句内表情切换、{wait}/{speed} 句内效果 |
| 背景系统 | `presentation/background/` | 双缓冲 + fade 转场 |
| 立绘系统 | `presentation/character/` | 单图/差分双层渲染、show/hide/expr/anim/move、jump/shake/nod/bounce 动画 |
| 选项系统 | `presentation/choice/` | 动态按钮生成 |
| 音频系统 | `presentation/audio/` | BGM 淡入淡出 + SE 多通道 |
| 屏幕特效 | `presentation/effects/` | fade 黑屏 + shake/flash |
| 输入处理 | `presentation/input/` | 鼠标/键盘 → 信号 |

### DSL 指令覆盖率

| 指令 | 状态 |
|------|------|
| `@scene` / `@end` | ✅ |
| 对话 `sakura「」` / 旁白 `「」` / 独白 `sakura（）` | ✅ |
| `#voice:id` / `[expression]` 句内表情 | ✅ |
| `@bg` / `@show` / `@hide` / `@expr` | ✅ |
| `@anim` / `@move` | ✅ |
| `@cg` / `@cg off` | ✅ |
| `@bgm` / `@bgm off` / `@se` / `@se off` | ✅ |
| `@effect` / `@fade` / `@wait` | ✅ |
| `@nvl` / `@overlay` | ✅ |
| `@choice` + 选项 | ✅ |
| `@set` (=, +=, -=) | ✅ |
| `@if` / `@else` / `@end` | ✅ |
| `@jump` | ✅ |
| `@parallel` / `@end` | ✅ |
| `@elif` | ❌ 未实现 |
| `@call`（子场景调用+返回） | ❌ 未实现 |

### 其他

| 项目 | 状态 |
|------|------|
| 插件化发布 | ✅ plugin.cfg + Autoload 自动注册 |
| 资源路径可配置 | ✅ NatsumeRuntime.*_path |
| 差分立绘 | ✅ config.json + body/face 分层 |
| 使用文档 | ✅ docs/USAGE.md |
| CI | ✅ GitHub Actions + GUT headless |
| Godot 版本 | 4.6.1 |
| GUT 版本 | 9.6.0 |

---

## 未完成

| 项目 | 说明 | 优先级 |
|------|------|--------|
| `@elif` | 多分支条件 | 低 |
| `@call` | 子场景调用 + 返回栈 | 低 |
| 转场 Shader | dissolve/wipe/pixelate/blur（目前只有 fade） | 中 |
| 存档/读档 UI | 界面 | 中 |
| 设置 UI | 文字速度/音量控制界面 | 中 |
| Backlog UI | 对话历史界面 | 中 |
| 标题画面 | Title screen | 中 |
| 编辑器插件 | GraphEdit 节点图剧情编辑器 | 大 |
| 音频实际播放调试 | 需要真实音频素材测试 | 低 |
| CR 反馈修复 | ScenarioContext.restore_snapshot 缺 is_finished、VariableStore 缺 .get() 防护 | 低 |
