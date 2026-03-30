# Natsume — 开发进度

> 最后更新：2026-03-30

## 总览

| 指标 | 数量 |
|------|------|
| 已合并 PR | 55 |
| 源代码文件 | 62 个 `.gd` |
| 测试文件 | 27 个 |
| 测试用例 | 259 个，全绿 |
| 断言数 | 517 |

---

## 已完成

### Core 层（100%）

| 模块 | 说明 |
|------|------|
| DSL 解析器 | Lexer + Parser，支持全部指令（含 @elif、@call） |
| 剧情引擎 | 主循环、命令派发、跳转、子场景调用 + 返回栈 |
| 命令处理器 | 19 个（dialogue/bg/show/hide/expr/anim/move/choice/jump/condition/set/bgm/se/fade/wait/cg/effect/parallel/call） |
| 变量系统 | 3 作用域（global/scenario/temp）+ 表达式求值器 |
| 存档系统 | 快照协议、JSON 持久化、多槽位 |
| 设置系统 | 文字速度/音量/自动播放/快进，JSON 持久化 |
| 播放控制 | 自动播放/快进/已读管理/Backlog |
| 状态机 | 6 种状态，previous_state 追踪 + return_to_previous |
| 表情时间轴 | 句内 [expression] 标记提取和查询 |
| 语音收藏 | VoiceBookmarkManager |
| 鉴赏管理 | UnlockManager（CG/BGM/场景） |
| 本地化 | LocalizationManager（多语言 key-value） |
| 角色配置 | CharacterConfig + CharacterConfigLoader（sprite/layered 渲染） |

### Presentation 层

| 模块 | 说明 |
|------|------|
| 对话系统 | 打字机效果、ADV/NVL/overlay 三模式、句内效果 {wait}/{speed}、句内表情切换 |
| 立绘系统 | 单图/差分双层渲染、状态机驱动（EMPTY→SHOWING→VISIBLE→HIDING）、jump/shake/nod/bounce 动画 |
| 背景系统 | 双缓冲、fade/dissolve/wipe 转场 Shader、多格式支持（png/jpg/webp） |
| 选项 UI | 动态按钮生成 |
| 音频播放 | BGM 淡入淡出 + SE 多通道 |
| 屏幕特效 | FadeLayer 独立分层 + shake/flash |
| 输入处理 | 鼠标/键盘 → 信号 |

### 用户交互 UI

| 模块 | 说明 |
|------|------|
| 工具栏 | 自动/快进/记录/快存/快读/存档/读档/设置（8 按钮） |
| 快进 | 工具栏按钮 + Ctrl 长按，跳过打字机 + 自动推进 |
| 自动播放 | 打字机完成后等 auto_play_delay 自动推进 |
| Backlog | 全屏对话历史，ScrollContainer |
| 存档/读档 | 8 槽位网格 + 时间戳 |
| 设置 | 文字速度/音量/全屏 滑条 |
| 标题画面 | 开始/继续/退出 |
| 右键隐藏 UI | 右键隐藏对话框，再次点击恢复 |

### 架构

| 项目 | 说明 |
|------|------|
| 场景分离 | title.tscn + game.tscn，游戏组件按需加载 |
| 资源路径可配置 | NatsumeRuntime.*_path |
| 插件化发布 | EditorPlugin 自动注册 Autoload |
| FadeLayer 独立 | 不遮挡 UI（layer 2，UI 在 layer 3） |
| 立绘状态机 | 消除 tween 竞态（EMPTY/SHOWING/VISIBLE/HIDING） |
| 信号桥接 | Engine 信号 → SignalBus → Presentation |

### DSL 指令覆盖率（100%）

| 指令 | 状态 |
|------|------|
| `@scene` / `@end` | ✅ |
| 对话 / 旁白 / 独白 | ✅ |
| `#voice:id` / `[expression]` / `{wait}` / `{speed}` | ✅ |
| `@bg` / `@show` / `@hide` / `@expr` | ✅ |
| `@anim` / `@move` | ✅ |
| `@cg` / `@effect` / `@fade` / `@wait` | ✅ |
| `@bgm` / `@se` | ✅ |
| `@nvl` / `@overlay` | ✅ |
| `@choice` | ✅ |
| `@set` (=, +=, -=) | ✅ |
| `@if` / `@elif` / `@else` / `@end` | ✅ |
| `@jump` / `@call` | ✅ |
| `@parallel` | ✅ |

### Demo

- 2 个角色：sakura（7 表情）、senpai（4 表情），nano banana 生成
- 4 张背景：校门、走廊、咖啡店、室外，nano banana 生成
- 7 个场景的完整剧本（对话/选择/分支/NVL/overlay/动画/fade）

### 规范化

- 开发工作流（CLAUDE.md）：branch → TDD → test → PR → CR agent → merge
- CR agent 独占合并权，主 agent 不得自行 merge
- CR checklist：端到端验证、Godot API、信号桥接、状态管理
- 禁止用延时修竞态，必须用状态机/信号守卫
- 计划内/计划外 PR 合并策略区分

---

## 未完成

| 项目 | 说明 | 优先级 |
|------|------|--------|
| 立绘 zoom + offset 系统 | 替代固定 slot，逐句精确控制立绘缩放/偏移/位置 | 高 |
| @show 扩展参数 | `x:0.3 y:0.5 zoom:1.5 oy:-100` 精确定位 | 高 |
| @camera 指令 | 演出中动态调整角色视口（带过渡动画） | 高 |
| 可视化编辑器 | 拖拽调整立绘位置/大小，预览 DSL，自动输出参数 | 中 |
| 运行时调试面板 | F2 打开，拖拽调参，输出到控制台供编剧复制 | 中 |
| 角色 config.json 默认 zoom/offset | 角色级别的默认显示参数，DSL 逐句可覆盖 | 中 |
| 音频实际播放调试 | 需要真实音频素材测试 BGM/SE/Voice | 低 |
| sprite sheet 支持 | 表情差分用一张合图 + 坐标裁切，减少文件数 | 低 |
