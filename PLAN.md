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
        style: "text"              # 选项展示风格，由游戏项目注册的 IChoicePresenter 处理
        prompt: "你该怎么回应？"
        options:
          - id: "greet"
            label: "你好，我叫..."
            jump: "scene_002a"
            set: { sakura_affection: "+5" }
          - id: "silent"
            label: "......"
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

### 3.6 选择系统（抽象）

选择的本质是「暂停引擎 → 等待玩家做出选择 → 返回选中的 option id」。具体用什么 UI 展示（文字列表、地图选点、角色头像…）不是引擎关心的事。

```csharp
// 核心层只定义接口
public interface IChoicePresenter
{
    string Style { get; }  // 对应 YAML 中的 style 字段
    Task<string> ShowAndWaitAsync(ChoiceData data);  // 返回选中的 option id
}

// 选择数据（纯数据，不含 UI 逻辑）
public class ChoiceData
{
    public string Style;                    // "text", "map", "character", 自定义...
    public string Prompt;                   // 可选的提示文字
    public List<ChoiceOption> Options;
    public Dictionary<string, object> Extra; // style 特有的扩展参数
}

public class ChoiceOption
{
    public string Id;                       // 选项唯一标识
    public string Label;                    // 显示文本（部分 style 可能不用）
    public string Jump;                     // 跳转目标
    public Dictionary<string, string> Set;  // 变量修改
    public string Condition;                // 可选：显示条件表达式
    public Dictionary<string, object> Extra; // style 特有的扩展参数（坐标、图片等）
}
```

**引擎流程**：`ChoiceCommandHandler` 根据 `style` 字段查找对应的 `IChoicePresenter`，调用 `ShowAndWaitAsync`，拿到 id 后执行 jump/set。

**YAML 示例 — 不同风格**：

```yaml
# 经典文字选项
- type: choice
  style: "text"
  prompt: "你该怎么回应？"
  options:
    - { id: "greet", label: "你好，我叫...", jump: "scene_002a" }
    - { id: "silent", label: "......", jump: "scene_002b" }

# 地图选点
- type: choice
  style: "map"
  extra: { background: "map_school" }
  options:
    - { id: "library", label: "图书馆", extra: { x: 0.3, y: 0.6 }, jump: "scene_library" }
    - { id: "rooftop", label: "天台", extra: { x: 0.7, y: 0.2 }, jump: "scene_rooftop" }

# 角色选择
- type: choice
  style: "character"
  prompt: "今天和谁一起回家？"
  options:
    - { id: "sakura", label: "樱", extra: { avatar: "sakura_icon" }, jump: "scene_sakura" }
    - { id: "kaito", label: "海斗", extra: { avatar: "kaito_icon" }, jump: "scene_kaito" }
```

框架内置 `TextChoicePresenter` 作为默认实现。游戏项目注册自定义 `IChoicePresenter`（如 `MapChoicePresenter`）即可扩展新的选择风格。

### 3.7 指令并行执行

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

### 3.8 设计模式汇总

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

### 4.6 游戏设置系统（框架提供功能，UI 由游戏项目实现）

框架只提供设置数据模型、持久化、事件通知。不提供设置 UI —— 每个游戏的设置界面风格不同，由游戏项目自行实现。

**数据模型** — `GameSettings.cs`：

```csharp
public class GameSettings
{
    // ═══ 文字显示 ═══
    int   CharacterInterval;        // 每个文字的显示间隔（毫秒），0=瞬间显示全部
    int   PunctuationPause;         // 标点符号额外停顿（毫秒），如句号/逗号后多等一拍
    bool  ClickToComplete;          // 打字中点击：true=先显示完整文本，false=直接下一句
    float TextWindowOpacity;        // 文本框透明度（0~1）

    // ═══ 自动播放 ═══
    float AutoPlayDelay;            // 文本显示完后等待时间（秒）
    bool  AutoPlayWaitVoice;        // 等语音播完再推进（语音比 delay 长时以语音为准）
    bool  AutoPlayPauseOnChoice;    // 遇到选项时自动暂停自动播放

    // ═══ 快进 ═══
    int   SkipInterval;             // 快进时每条对话停留时间（毫秒），0=最快
    bool  SkipOnlyRead;             // 仅跳过已读文本
    bool  SkipUnreadConfirm;        // 快进遇到未读时弹确认
    bool  SkipStopOnChoice;         // 遇到选项时停止快进

    // ═══ 音量 ═══
    float MasterVolume;             // 主音量（0~1）
    float BgmVolume;
    float SeVolume;
    float SystemSeVolume;           // 系统音效（UI 点击等）
    float VoiceVolume;              // 语音总音量
    Dictionary<string, float> CharacterVoiceVolume;  // 角色单独音量
    Dictionary<string, bool>  CharacterVoiceEnabled;  // 角色语音开关

    // ═══ 语音行为 ═══
    bool VoiceContinueOnAdvance;    // 推进对话后语音继续播放（不中断）
    bool VoiceReplayOnBacklog;      // Backlog 中点击条目可重播语音

    // ═══ 画面 ═══
    ScreenMode ScreenMode;          // 全屏/窗口/无边框
    Resolution Resolution;
    bool EffectEnabled;             // 转场/屏幕特效开关

    // ═══ 操作 ═══
    Dictionary<string, KeyCode> KeyBindings;  // 快捷键绑定
}
```

**文字显示控制的具体行为**：
- `CharacterInterval=50` 表示每 50ms 显示一个字（约 20 字/秒）
- `PunctuationPause=200` 表示遇到 `。、！？…` 等标点后额外等 200ms
- 内联标签 `{wait:500}` 可在脚本中覆盖，插入指定毫秒的停顿
- 内联标签 `{speed:30}` 可临时改变当前句的字符间隔
- 这些设置项最终由 `TextAnimator` 在逐字显示时读取并应用

**框架提供的能力**：
```
Settings/
├── GameSettings.cs              -- 数据模型
├── GameSettingsManager.cs       -- 读取/保存/重置默认值/JSON 持久化
└── SettingsChangedEvent.cs      -- 设置变更事件，各子系统订阅后动态调整
```

游戏项目自行实现 `SettingsPresenter` 绑定到自己的 UI。

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

## 九、开发路线图（Agent Team 模式）

> 全程由 AI agent team 实现。时间评估基于：agent 可多模块并行开发、模式化代码产出极快，但需要人工 review 和集成调试。每个 Sprint 结束需要人工验收。

### 执行原则

- **串行的**：Phase 之间有依赖的必须串行（如 Core 先于 Presentation）
- **并行的**：同一 Phase 内独立模块由不同 agent 并行实现
- **人工卡点**：每个 Sprint 结束后人工 review + 集成测试，通过后进入下一 Sprint
- **Agent 分工**：按模块边界分配，每个 agent 负责一个独立模块，通过接口对接

---

### Sprint 1 — 核心骨架（~2-3 天）

串行：必须先完成，后续所有工作依赖此阶段产出。

| Agent | 任务 | 产出 |
|-------|------|------|
| **Agent A** | 项目脚手架：UPM 结构、Assembly Definition、引入依赖 | 可编译的空项目 |
| **Agent B**（A 完成后） | EventBus + ServiceLocator + 核心接口定义（ICommandHandler、IChoicePresenter、ISnapshotProvider、IResourceProvider） | 所有模块的对接契约 |

**人工卡点**：review 接口设计，确认契约合理后开放并行开发。

---

### Sprint 2 — 核心引擎 + 基础表现（~3-4 天，并行）

接口已定义，以下 agent 可完全并行：

| Agent | 任务 | 依赖 |
|-------|------|------|
| **Agent C** — 引擎核心 | ScenarioEngine 主循环、CommandExecutor、WaitController、FlowControl（jump/条件分支） | Sprint 1 接口 |
| **Agent D** — 数据层 | YAML 加载器（YamlDotNet）、ScenarioData/SceneData/CommandData 数据模型、VariableStore + ExpressionEvaluator | Sprint 1 接口 |
| **Agent E** — 对话 + 文字 | DialoguePresenter、TextAnimator（打字机效果 + 内联标签）、NameBoxController、DialogueCommandHandler | Sprint 1 接口 |
| **Agent F** — 立绘 + 背景 | CharacterPresenter（整张/差分两种模式）、BackgroundPresenter（双缓冲）、基础转场 Shader（fade） | Sprint 1 接口 |
| **Agent G** — 音频 | BgmController、SeController、VoiceController、AudioCommandHandler | Sprint 1 接口 |

**人工卡点**：集成测试 — 用一段 YAML demo 剧本跑通完整流程。

**里程碑：视觉小说形式可演出。**

---

### Sprint 3 — 游戏体验完善（~2-3 天，并行）

| Agent | 任务 | 依赖 |
|-------|------|------|
| **Agent H** — 存档系统 | SaveManager、FileSaveStorage、SaveSerializer、各子系统 ISnapshotProvider 实现 | Sprint 2 各子系统 |
| **Agent I** — 设置系统 | GameSettings 数据模型、GameSettingsManager、SettingsChangedEvent、各子系统订阅响应 | Sprint 2 各子系统 |
| **Agent J** — 播放控制 | AutoPlayController、SkipController、ReadFlagManager、BacklogManager（含语音重播） | Sprint 2 对话+音频 |
| **Agent K** — 选择系统 | ChoiceCommandHandler、TextChoicePresenter（默认实现）、IChoicePresenter 注册机制 | Sprint 2 引擎 |
| **Agent L** — 游戏流程 | GameStateMachine（标题/游戏中/暂停）、标题画面逻辑、存读档 UI 逻辑 | Sprint 2 引擎 |

**人工卡点**：完整游戏循环验收 — 标题 → 新游戏 → 存档 → 读档 → 设置 → 快进/自动。

**里程碑：完整游戏循环。**

---

### Sprint 4 — 编辑器（~4-5 天，并行）

| Agent | 任务 | 依赖 |
|-------|------|------|
| **Agent M** — 节点图 | ScenarioGraphView、SceneNode/ChoiceNode/ConditionNode、连线逻辑 | Sprint 1 数据模型 |
| **Agent N** — 序列化 | GraphToYamlConverter、YamlToGraphConverter（双向转换） | Sprint 1 数据模型 + Agent M 节点定义 |
| **Agent O** — 属性面板 | NodeInspectorPanel、资源选择器（背景/立绘/音频）、指令列表编辑器 | Agent M 节点定义 |

**人工卡点**：在编辑器中创建一个完整剧本 → 导出 YAML → 运行验证。

**里程碑：编辑器可创建可运行剧本。**

---

### Sprint 5 — 表现增强 + 鉴赏（~3-4 天，并行）

| Agent | 任务 | 依赖 |
|-------|------|------|
| **Agent P** — 转场/特效 | 更多转场 Shader（dissolve/wipe/pixelate/blur）、屏幕特效（闪白/震动/滤镜） | Sprint 2 背景系统 |
| **Agent Q** — 立绘增强 | 差分合成系统、入场/退场动画、呼吸效果、NVL 模式 | Sprint 2 立绘系统 |
| **Agent R** — 鉴赏系统 | CG 鉴赏、音乐鉴赏、场景回放、UnlockManager | Sprint 3 存档系统（global 变量） |

**里程碑：丰富演出效果 + 完整额外内容。**

---

### Sprint 6 — 高级扩展（~3-5 天，并行，可按需取舍）

| Agent | 任务 | 依赖 |
|-------|------|------|
| **Agent S** — 语音差分联动 | VoiceExpressionSyncController、ExpressionTimeline、ExpressionTimelineEditor（波形标记） | Sprint 2 音频+立绘 |
| **Agent T** — 双端跳转 | 编辑器 SceneJumpHandler + ContextInferencer、运行时 ScenarioDebugger + BreakpointManager | Sprint 4 编辑器 + Sprint 2 引擎 |
| **Agent U** — 语音收藏 | VoiceBookmarkManager/Trigger/Jumper、收藏 UI 逻辑 | Sprint 3 存档系统 |
| **Agent V** — DSL + 本地化 | DslLexer/DslParser、双向转译、LocalizationManager、CSV 导出导入 | Sprint 1 数据模型 |

**里程碑：全部高级功能可用。**

---

### Sprint 7 — 开源准备（~1-2 天）

| Agent | 任务 |
|-------|------|
| **Agent W** | API 文档（XML 注释 + DocFX）、README |
| **Agent X** | 示例项目（含完整短篇 demo 剧本）、CI 配置（GitHub Actions） |

---

### 时间总结

| Sprint | 内容 | 耗时 | 并行 Agent 数 |
|--------|------|------|---------------|
| Sprint 1 | 核心骨架 + 接口契约 | 2-3 天 | 2（串行） |
| Sprint 2 | 引擎 + 表现层 | 3-4 天 | 5 并行 |
| Sprint 3 | 存档/设置/播放/选择/流程 | 2-3 天 | 5 并行 |
| Sprint 4 | 编辑器 | 4-5 天 | 3 并行 |
| Sprint 5 | 表现增强 + 鉴赏 | 3-4 天 | 3 并行 |
| Sprint 6 | 高级扩展 | 3-5 天 | 4 并行 |
| Sprint 7 | 开源准备 | 1-2 天 | 2 并行 |
| **总计** | | **18-26 天** | 峰值 5 agent |

**对比人工：18-28 周 → agent team：18-26 天**，约 5-7 倍加速。

瓶颈不在编码速度，而在：
1. **Sprint 1 的接口设计** — 决定了后续所有并行是否顺畅，需要人工仔细 review
2. **每个 Sprint 的集成调试** — agent 各自模块能跑，组合起来可能有问题
3. **Unity 编辑器开发** — GraphView API 文档不充分，agent 可能需要更多迭代

### 前期需预留的扩展点

在 Sprint 1-5 实现时，为 Sprint 6 高级功能预留接口：

| 扩展功能 | 需预留的扩展点 |
|----------|---------------|
| 语音差分联动 | `CommandData` 支持 `expression_timeline` 字段解析（忽略即可）；`CharacterPresenter` 支持外部触发表情切换 |
| 语音收藏 | `ISnapshotProvider` 机制（存档系统本身就有）；对话系统预留收藏触发点 |
| 双端跳转 | `ScenarioEngine` 暴露 `JumpToScene(sceneId)` 方法 |
| DSL | YAML 作为 IR 的设计本身就是扩展点，DSL 只是多一个输入源 |

---

## 十、验证方案

- **Sprint 1**：接口编译通过 + 人工 review 契约设计
- **Sprint 2**：demo YAML 剧本端到端跑通（NUnit 单测 + Play Mode）
- **Sprint 3**：完整游戏循环手动验收
- **Sprint 4**：编辑器创建 → 导出 → 运行的闭环测试
- **Sprint 5-6**：各功能独立验证 + 集成回归
- **Sprint 7**：示例项目从零跑通作为最终验收
