# Natsume — Unity AVG / Galgame 框架架构设计

> 框架名称：**Natsume（夏目）**
> 仓库：`github.com/MadCcc/Natsume`
> 命名空间：`Natsume.*`

## Context

基于 Unity 的视觉小说框架。自用为主，后期开源。要求架构质量高、扩展性好。

## 已确认的决策

- **脚本格式**：YAML（存储层/IR） + 轻量 DSL（编剧书写层），双向转换
- **架构**：四层分离（Core / Presentation / Editor / Tool），Core 为纯 C#
- **开发范围**：完整规划，按优先级分步执行

---

## 一、架构总览

```
┌─────────────────────────────────────────────────┐
│              Editor Layer (编辑器层)              │
│  节点式剧情编辑器 | 资源浏览器 | 实时预览面板      │
├─────────────────────────────────────────────────┤
│           Presentation Layer (表现层/Unity)       │
│  对话系统 | 立绘系统 | 背景系统 | 音频系统         │
│  UI系统 | CG鉴赏 | 转场/特效系统                  │
├─────────────────────────────────────────────────┤
│              Core Layer (核心层/纯C#)             │
│  脚本解析器 | 剧情引擎 | 变量系统 | 存档系统        │
│  资源抽象 | 命令注册表 | 事件总线                   │
├─────────────────────────────────────────────────┤
│              Tool Layer (工具层)                   │
│  本地化 | 调试工具 | 资源打包 | 热更新              │
└─────────────────────────────────────────────────┘
```

Core 与 Presentation 通过 EventBus 解耦。Core 层可独立单元测试。

---

## 二、脚本格式

### 存储层 — YAML（编辑器/引擎直接使用的 IR）

```yaml
scenes:
  - id: "scene_001"
    commands:
      - type: bg
        asset: "bg_school_gate"
        transition: { type: fade, duration: 0.8 }
      - type: dialogue
        character: "sakura"
        text: "初次见面，我叫樱。"
        voice: "sakura_ch01_001"
      - type: choice
        prompt: "你该怎么回应？"
        options:
          - text: "你好，我叫..."
            jump: "scene_002a"
            set: { sakura_affection: "+5" }
          - text: "......"
            jump: "scene_002b"
```

### 书写层 — 轻量 DSL（面向编剧，转译为 YAML）

```
@scene scene_001
@bg bg_school_gate fade 0.8

sakura「初次见面，我叫樱。」 #voice:sakura_ch01_001

@choice "你该怎么回应？"
  - "你好，我叫..." -> scene_002a {sakura_affection += 5}
  - "......" -> scene_002b
```

DSL 为后期功能，前期仅实现 YAML。

---

## 三、核心设计

### 3.1 命令模式 — 整个框架的基石

```csharp
public interface ICommandHandler
{
    string CommandType { get; }
    Task ExecuteAsync(CommandData data, ScenarioContext context);
    void Rollback(CommandData data, ScenarioContext context);
}

public class CommandRegistry
{
    private Dictionary<string, ICommandHandler> _handlers;
    public void Register(ICommandHandler handler);
    public ICommandHandler GetHandler(string commandType);
}
```

新增指令只需添加 Handler，符合开闭原则。

### 3.2 剧情引擎

主循环：`LoadScenario → SetScene → FetchCommand → Dispatch → WaitForCompletion → Next`

```
ScenarioEngine/
├── ScenarioEngine.cs        -- 主引擎
├── ScenarioContext.cs       -- 运行时上下文（场景、指令指针、调用栈）
├── CommandExecutor.cs       -- 指令调度
├── ICommandHandler.cs       -- 命令接口
└── WaitController.cs        -- 等待控制（点击/动画/选择）
```

### 3.3 事件总线

```csharp
public class EventBus
{
    public static void Publish<T>(T evt) where T : IEvent;
    public static void Subscribe<T>(Action<T> handler) where T : IEvent;
    public static void Unsubscribe<T>(Action<T> handler) where T : IEvent;
}
```

### 3.4 变量系统

三个作用域：
- `global`：跨存档永久变量（CG 解锁、已读标记）
- `scenario`：当前存档变量（好感度、flag）
- `temp`：临时变量（不入存档）

ExpressionEvaluator 支持：比较、逻辑、算术运算。

### 3.5 存档系统

```csharp
public interface ISnapshotProvider
{
    string ProviderId { get; }
    object CaptureSnapshot();
    void RestoreSnapshot(object snapshot);
}
```

各子系统实现此接口，存档时统一收集快照，读档时统一恢复。

### 3.6 指令并行执行

```yaml
- type: parallel
  commands:
    - type: bg
      asset: "bg_sunset"
      transition: { type: fade, duration: 1.0 }
    - type: char_show
      character: "sakura"
      transition: { type: dissolve, duration: 1.0 }
```

### 3.7 设计模式汇总

| 模式 | 应用 |
|------|------|
| **命令模式** | 剧本指令抽象与执行 |
| **事件总线/观察者** | Core ↔ Presentation 层间通信 |
| **状态机** | 游戏宏观流程（标题/游戏中/暂停/存档） |
| **策略模式** | 转场效果、文字动画可插拔 |
| **快照/备忘录** | 存档系统状态捕获与恢复 |
| **服务定位器** | 全局服务注册与访问 |

---

## 四、表现层

### 4.1 对话系统
- 打字机效果：TMP `maxVisibleCharacters`（不破坏富文本）
- 内联标签：`{wait:0.5}` 暂停、`{speed:0.5}` 变速、`{shake}` 震动
- Backlog 数据管理

### 4.2 立绘系统
- 整张替换 / 分层合成（身体底图 + 表情差分叠加）
- 位置预设（left/center/right + 自定义）
- 动画（入场/退场/呼吸）

### 4.3 背景系统
- 双缓冲（front/back RawImage）
- 转场效果基于 Shader（fade/dissolve/wipe/pixelate/blur），可扩展

### 4.4 音频系统
- BGM（淡入淡出、交叉混合）、SE（多通道）、Voice（对话同步）
- 语音未播完可阻止自动推进

### 4.5 UI 系统
- 标题画面、选项分支、Backlog、存读档界面
- 自动播放 / 快进（仅已读/全部）
- 游戏状态机管理宏观流程

### 4.6 游戏设置（参考柚子社）

分 Tab 布局：**文字 | 音量 | 语音 | 画面 | 操作**

```csharp
public class GameSettings
{
    // ═══ 文字 ═══
    float TextSpeed;                // 文字速度（0~1）
    float AutoPlaySpeed;            // 自动播放等待（秒）
    bool  AutoPlayWaitVoice;        // 自动播放等语音播完
    float SkipSpeed;                // 快进速度
    bool  SkipOnlyRead;             // 仅跳过已读
    bool  SkipUnreadConfirm;        // 跳过未读时确认
    float TextWindowOpacity;        // 文本框透明度

    // ═══ 音量 ═══
    float MasterVolume;
    float BgmVolume;
    float SeVolume;
    float SystemSeVolume;           // 系统音效（UI 点击等）
    float VoiceVolume;
    Dictionary<string, float> CharacterVoiceVolume;  // 角色单独音量
    Dictionary<string, bool>  CharacterVoiceEnabled;  // 角色语音开关

    // ═══ 语音 ═══
    bool VoiceContinueOnAdvance;    // 推进后语音继续播放
    bool VoiceReplayOnBacklog;      // Backlog 点击重播
    bool TitleCallVoiceEnabled;     // 标题语音开关

    // ═══ 画面 ═══
    ScreenMode ScreenMode;          // 全屏/窗口/无边框
    Resolution Resolution;
    bool EffectEnabled;             // 特效开关
    int  TextWindowStyle;           // 文本框样式

    // ═══ 操作 ═══
    MouseWheelBehavior MouseWheelUp;   // 滚轮上：回看/上一条
    MouseWheelBehavior MouseWheelDown; // 滚轮下：推进/下一条
    bool RightClickBehavior;        // 右键行为
    bool ConfirmOnExit;
    bool ConfirmOnTitle;
    Dictionary<string, KeyCode> KeyBindings;  // 快捷键
}
```

设置变更实时生效，通过 `SettingsChangedEvent` 通知各子系统。角色列表从 `CharacterDatabase` 自动生成。

```
Settings/
├── GameSettings.cs / GameSettingsManager.cs
├── SettingsPresenter.cs
├── Tabs/  (Text / Audio / Voice / Display / Control)
├── SettingsSlider.cs / SettingsToggle.cs
```

### 4.7 CG 鉴赏 / 回忆模式
- CG 鉴赏、音乐鉴赏、场景回放
- 与 global 变量联动的解锁管理

---

## 五、编辑器层

**方案：UI Toolkit + GraphView**

```
Editor/
├── ScenarioEditor/
│   ├── ScenarioEditorWindow.cs       -- 主窗口
│   ├── ScenarioGraphView.cs          -- 节点图
│   ├── Nodes/                        -- 场景/对话/分支/条件节点
│   ├── Inspectors/                   -- 属性面板
│   ├── Serialization/                -- Graph ↔ YAML
│   └── Preview/                      -- 实时预览
├── ResourceBrowser/
└── Tools/                            -- 剧本验证、批量导出
```

**双粒度视图**：
- 宏观：每个节点 = 一个场景，连线 = 跳转
- 微观：选中场景后，侧面板编辑指令序列

---

## 六、高级功能（扩展规划）

> 以下功能在基础系统稳定后实现。前期只需在架构上预留扩展点。

### 6.1 语音驱动差分切换（Voice-Driven Expression）

一句对话中，角色表情随语音时间轴自动切换。

**扩展点**：dialogue 指令预留 `expression_timeline` 字段。

```yaml
- type: dialogue
  character: "sakura"
  text: "我本来很开心的...但是听到这个消息之后..."
  voice: "sakura_ch01_042"
  expression_timeline:       # 扩展字段，无此字段时走默认行为
    - { at: 0.0, expression: "smile" }
    - { at: 1.8, expression: "surprised" }
    - { at: 3.2, expression: "cry" }
```

DSL：`#expr:0.0=smile,1.8=surprised,3.2=cry`

**实现模块**：
```
VoiceExpressionSync/
├── VoiceExpressionSyncController.cs  -- 监听 AudioSource.time，到达标记点发布 ChangeExpressionEvent
├── ExpressionTimeline.cs             -- 时间轴数据
├── ExpressionTimelineEditor.cs       -- 编辑器：波形图上拖拽标记点
└── VoiceWaveformPreview.cs           -- 语音波形预览
```

### 6.2 语音收藏系统（Voice Bookmark）

游戏中收藏语音 → 收藏界面浏览/重播 → 可跳转回对应场景继续游玩。

**扩展点**：依赖 `ISnapshotProvider` 机制，收藏时自动捕获状态快照。

```csharp
public class VoiceBookmark
{
    string BookmarkId;
    string VoiceAssetId;
    string CharacterName;
    string DialogueText;
    string ScenarioId, SceneId;
    int    CommandIndex;
    DateTime BookmarkTime;
    SaveData ContextSnapshot;   // 跳转恢复用
}
```

**实现模块**：
```
VoiceBookmark/
├── VoiceBookmarkManager.cs       -- 增删查、持久化（voice_bookmarks.json, global 作用域）
├── VoiceBookmarkPresenter.cs     -- UI：按角色筛选、重播、跳转
├── VoiceBookmarkTrigger.cs       -- 对话框收藏按钮
└── VoiceBookmarkJumper.cs        -- 跳转 = 读取隐藏存档，复用 RestoreSnapshot
```

### 6.3 双端场景跳转（Editor + Runtime）

**扩展点**：`ScenarioEngine.JumpToScene()` + `ContextBuilder` 状态重建。

**编辑器端**：节点右键 → "从此处预览"，自动推断最小上下文。
```
Editor/Preview/
├── SceneJumpHandler.cs
└── ContextInferencer.cs
```

**运行时端**：Debug 面板，支持场景搜索/跳转/断点。
```
DebugTools/
├── ScenarioDebugger.cs / SceneJumper.cs
├── BreakpointManager.cs
├── VariableWatcher.cs / CommandLogger.cs
└── ContextBuilder.cs
```

### 6.4 DSL 脚本系统

轻量 DSL ↔ YAML 双向转译。

```
ScriptParser/
├── DslLexer.cs / DslParser.cs         -- 词法/语法分析
├── DslToYamlCompiler.cs               -- DSL → YAML
├── YamlToDslDecompiler.cs             -- YAML → DSL
└── Editor/DslImporter.cs              -- .novel 文件 Asset Importer
```

### 6.5 本地化系统

对话文本用 `text_key` 引用本地化表，支持导出 CSV 供翻译。

### 6.6 热更新

基于 Addressables Remote Content Catalog，剧本/资源按章节分包。

---

## 七、项目目录结构

```
Assets/
├── Natsume/                          -- 框架（UPM Package）
│   ├── Runtime/
│   │   ├── Core/                     -- 纯 C#
│   │   │   ├── ScriptParser/
│   │   │   ├── ScenarioEngine/
│   │   │   ├── VariableSystem/
│   │   │   ├── SaveSystem/
│   │   │   ├── ResourceAbstraction/
│   │   │   ├── EventBus/
│   │   │   ├── Commands/
│   │   │   └── ServiceLocator/
│   │   ├── Presentation/
│   │   │   ├── Dialogue/
│   │   │   ├── Character/
│   │   │   ├── Background/
│   │   │   ├── Audio/
│   │   │   ├── UI/
│   │   │   ├── Gallery/
│   │   │   ├── Transition/
│   │   │   └── Bootstrap/
│   │   ├── Localization/
│   │   └── DebugTools/
│   ├── Editor/
│   │   ├── ScenarioEditor/
│   │   ├── ResourceBrowser/
│   │   └── Tools/
│   ├── Shaders/
│   └── package.json
├── GameProject/                      -- 游戏内容
│   ├── Scenarios/  (YAML/ + DSL/)
│   ├── Characters/
│   ├── Art/  (Backgrounds/ Characters/ CG/ UI/)
│   ├── Audio/  (BGM/ SE/ Voice/)
│   ├── Localization/
│   ├── Scenes/  (Title/Game/Gallery.unity)
│   ├── Prefabs/
│   ├── Config/  (ScriptableObject)
│   └── Scripts/  (自定义扩展)
└── Tests/  (EditMode/ + PlayMode/)
```

---

## 八、技术选型

| 类别 | 选择 | 理由 |
|------|------|------|
| Unity 版本 | Unity 6 LTS | 稳定，UI Toolkit 成熟 |
| 文本渲染 | TextMeshPro | 内置，富文本+注音 |
| 资源管理 | Addressables | 热更新、按需加载 |
| 缓动动画 | DOTween | 成熟，API 简洁 |
| YAML 解析 | YamlDotNet | 社区标准 |
| 异步控制 | UniTask | async/await，替代协程 |
| 运行时 UI | uGUI | 游戏内 UI |
| 编辑器 UI | UI Toolkit + GraphView | 官方推荐 |
| 可选 | MoonSharp (Lua) | 高级自定义逻辑 |

---

## 九、开发路线图

### P0 — 基础可运行（~4-6 周）

| 阶段 | 内容 | 里程碑 |
|------|------|--------|
| **Phase 0** 基础设施 (~1w) | 项目创建、UPM 结构、Assembly Definition、引入依赖、EventBus + ServiceLocator | 项目可编译 |
| **Phase 1** 核心引擎 (~2-3w) | YAML 加载器、ScenarioEngine 主循环、CommandRegistry、基础 Handler（dialogue/bg/char_show/choice）、变量系统、流程控制 | **YAML 驱动分支剧情** |
| **Phase 2** 基础表现 (~2-3w) | 对话（打字机+名字）、立绘（显示/位置/表情）、背景（fade 转场）、音频（BGM/SE/Voice）、选项 UI | **视觉小说形式演出** |

### P1 — 完整游戏体验（~4-6 周）

| 阶段 | 内容 | 里程碑 |
|------|------|--------|
| **Phase 3** 存档与流程 (~1-2w) | SaveManager + ISnapshotProvider、存读档 UI、标题画面、游戏状态机 | **完整游戏循环** |
| **Phase 4** 游戏设置 (~1-2w) | 柚子社风格设置面板（文字/音量/语音/画面/操作 5 Tab）、角色单独音量、快捷键绑定 | 可配置的游戏体验 |
| **Phase 5** 播放控制 (~1w) | 自动播放、快进（已读/全部）、Backlog（含语音重播）、已读标记 | 成熟的阅读体验 |

### P2 — 创作工具链（~5-8 周）

| 阶段 | 内容 | 里程碑 |
|------|------|--------|
| **Phase 6** 编辑器基础 (~3-4w) | GraphView 节点图、属性面板、Graph ↔ YAML 双向转换、资源选择器 | **编辑器创建可运行剧本** |
| **Phase 7** 表现增强 (~2-3w) | 更多转场 Shader、立绘动画、差分合成、文本内联效果、NVL 模式、屏幕特效 | 丰富的演出效果 |
| **Phase 8** CG/鉴赏系统 (~1w) | CG 鉴赏、音乐鉴赏、场景回放、解锁管理 | 完整的额外内容 |

### P3 — 高级扩展（~6-8 周，可按需取舍）

| 阶段 | 内容 | 里程碑 |
|------|------|--------|
| **Phase 9** 语音差分联动 (~2w) | VoiceExpressionSync、ExpressionTimeline、波形编辑器 | 语音驱动表情切换 |
| **Phase 10** 双端场景跳转 (~2w) | 编辑器预览跳转 + 运行时调试面板（断点/变量监控/指令日志） | 高效调试工作流 |
| **Phase 11** 语音收藏 (~1-2w) | 收藏/重播/跳转恢复、收藏界面 | 语音收藏系统 |
| **Phase 12** DSL + 本地化 (~2w) | DSL 词法/语法/双向转译、本地化导出导入 | 编剧友好工作流 |
| **Phase 13** 开源准备 (~1-2w) | API 文档、使用指南、示例项目、CI | 可发布状态 |

### 前期需预留的扩展点

在 P0-P2 实现时，为 P3 高级功能预留接口：

| 扩展功能 | 需预留的扩展点 |
|----------|---------------|
| 语音差分联动 | `CommandData` 支持 `expression_timeline` 字段解析（忽略即可）；`CharacterPresenter` 支持外部触发表情切换 |
| 语音收藏 | `ISnapshotProvider` 机制（存档系统本身就有）；对话框 UI 预留收藏按钮位 |
| 双端跳转 | `ScenarioEngine` 暴露 `JumpToScene(sceneId)` 方法 |
| DSL | YAML 作为 IR 的设计本身就是扩展点，DSL 只是多一个输入源 |

---

## 十、验证方案

- **P0**：Core 层纯 C#，NUnit 单元测试（解析、变量、流程控制）
- **P1**：Play Mode 测试 + demo 剧本手动验证
- **P2**：编辑器手动验证 + 导出剧本集成测试
- **P3**：各高级功能独立验证
- 每个 Phase 结束用 demo 剧本端到端验证
