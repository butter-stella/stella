# Unity AVG / Galgame 框架架构设计方案

> 框架名称：**Natsume（夏目）**
> 仓库：`github.com/MadCcc/Natsume`
> 命名空间：`Natsume.*`

## Context

需要设计一个基于 Unity 的视觉小说（Galgame / AVG）游戏框架。定位自用但后期可能开源，因此要求架构质量高、扩展性好。功能范围包括完整 AVG 系统 + 可视化剧本编辑器。当前阶段仅做设计和规划，暂不编码（Mac 无 Unity 环境）。

## 已确认的决策

- **脚本格式**：混合方案 — YAML（存储层/编辑器） + 轻量 DSL（编剧书写），双向转换
- **开发范围**：全部 9 个 Phase 完整规划，分步执行
- **当前阶段**：仅设计规划，不编码

---

## 1. 脚本格式：混合方案（YAML 存储层 + 轻量 DSL 书写层）

**存储层 — YAML**：作为框架的"中间表示"(IR)，编辑器直接读写此格式：

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

**书写层 — 轻量 DSL**：面向编剧的简洁语法，通过转译器转换为 YAML：

```
@scene scene_001
@bg bg_school_gate fade 0.8

sakura「初次见面，我叫樱。」 #voice:sakura_ch01_001

@choice "你该怎么回应？"
  - "你好，我叫..." -> scene_002a {sakura_affection += 5}
  - "......" -> scene_002b
```

**选择理由**：
- YAML 对编辑器友好（结构化数据直接操作）
- DSL 对编剧友好（书写效率高）
- 双向转换：DSL ↔ YAML
- Lua 作为可选的高级扩展点（复杂自定义逻辑）

---

## 2. 整体架构：四层分离

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

**核心原则**：Core Layer 为纯 C#（不依赖 Unity），可独立单元测试；Core 与 Presentation 通过 EventBus 解耦。

---

## 3. 核心层详细设计

### 3.1 剧情引擎（ScenarioEngine）— 框架心脏

主循环：`LoadScenario → SetScene → FetchCommand → Dispatch → WaitForCompletion → Next`

```
ScenarioEngine/
├── ScenarioEngine.cs        -- 主引擎，驱动剧情推进
├── ScenarioContext.cs       -- 运行时上下文（场景、指令指针、调用栈）
├── CommandExecutor.cs       -- 指令执行调度器
├── ICommandHandler.cs       -- 指令处理器接口（命令模式核心）
└── WaitController.cs        -- 等待控制（点击/动画完成/选择）
```

### 3.2 命令模式（Command Pattern）— 最关键的设计模式

```csharp
public interface ICommandHandler
{
    string CommandType { get; }   // 对应 YAML 中的 type
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

新增指令类型只需添加新 Handler 类，符合开闭原则。

### 3.3 事件总线 — 层间通信

```csharp
public class EventBus
{
    public static void Publish<T>(T evt) where T : IEvent;
    public static void Subscribe<T>(Action<T> handler) where T : IEvent;
    public static void Unsubscribe<T>(Action<T> handler) where T : IEvent;
}
```

Core 层发布事件 → Presentation 层订阅并响应，完全解耦。

### 3.4 变量系统

三个作用域：
- `global`：跨存档永久变量（CG 解锁、已读标记）
- `scenario`：当前存档变量（好感度、flag）
- `temp`：临时变量（不入存档）

ExpressionEvaluator 支持：比较、逻辑、算术运算。

### 3.5 存档系统

各子系统实现 `ISnapshotProvider` 接口，存档时统一收集快照，读档时统一恢复。

```csharp
public interface ISnapshotProvider
{
    string ProviderId { get; }
    object CaptureSnapshot();
    void RestoreSnapshot(object snapshot);
}
```

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

`ParallelCommandHandler` 使用 `Task.WhenAll` 并行执行。

---

## 4. 表现层详细设计

### 4.1 对话系统
- 打字机效果：使用 TMP 的 `maxVisibleCharacters`（不破坏富文本标签）
- 内联标签：`{wait:0.5}` 暂停、`{speed:0.5}` 变速、`{shake}` 震动
- Backlog 数据管理

### 4.2 立绘系统
- 两种模式：整张替换 / 分层合成（身体底图 + 表情差分叠加）
- 位置预设（left/center/right + 自定义）
- 动画（入场/退场/呼吸）

### 4.2.1 **[高级] 语音驱动差分切换（Voice-Driven Expression）**

在一句对话中，角色表情随语音播放时间轴自动切换。

**数据格式设计** — dialogue 指令新增 `expression_timeline` 字段：

```yaml
- type: dialogue
  character: "sakura"
  text: "我本来很开心的...但是听到这个消息之后..."
  voice: "sakura_ch01_042"
  expression_timeline:
    - at: 0.0       # 语音开始时
      expression: "smile"
    - at: 1.8       # 1.8 秒时切换
      expression: "surprised"
    - at: 3.2       # 3.2 秒时切换
      expression: "cry"
```

对应 DSL 语法：
```
sakura「我本来很开心的...但是听到这个消息之后...」 #voice:sakura_ch01_042 #expr:0.0=smile,1.8=surprised,3.2=cry
```

**实现架构：**

```
VoiceExpressionSync/
├── VoiceExpressionSyncController.cs  -- 主控制器
├── ExpressionTimeline.cs             -- 时间轴数据结构
├── ExpressionTimelineEditor.cs       -- 编辑器：可视化时间轴编辑（拖拽标记点）
└── VoiceWaveformPreview.cs           -- 编辑器：语音波形预览（方便定位时间点）
```

**核心实现思路：**
1. `DialogueCommandHandler` 解析 `expression_timeline`，传递给 `VoiceExpressionSyncController`
2. `VoiceExpressionSyncController` 监听 `VoiceController` 的播放进度（`AudioSource.time`）
3. 每帧检查是否到达下一个时间标记，到达则通过 EventBus 发布 `ChangeExpressionEvent`
4. `CharacterPresenter` 响应事件切换差分立绘

**编辑器支持：**
- 在节点属性面板中，选择语音文件后显示波形图
- 可在波形图上拖拽添加表情切换标记点
- 点击标记点可选择对应的表情差分，实时预览

### 4.3 背景系统
- 双缓冲方案：front/back 两个 RawImage
- 转场效果基于 Shader（fade/dissolve/wipe/pixelate/blur），可扩展

### 4.4 音频系统
- BGM（淡入淡出、交叉混合）、SE（多通道并行）、Voice（与对话同步）
- 语音未播完时可阻止自动推进

### 4.5 UI 系统
- 标题画面、选项分支、Backlog、设置面板、存读档界面
- 自动播放 / 快进（仅已读/全部）
- 游戏状态机管理宏观流程

### 4.5.1 游戏设置系统（参考柚子社风格）

**设置数据模型** — `GameSettings.cs`（持久化为 JSON，存在 global 作用域）：

```csharp
public class GameSettings
{
    // ═══ 文字设置 ═══
    public float TextSpeed;              // 文字显示速度（0~1，1=瞬间显示）
    public float AutoPlaySpeed;          // 自动播放等待时间（秒）
    public bool AutoPlayWaitVoice;       // 自动播放时等语音播完再推进
    public float SkipSpeed;              // 快进速度
    public bool SkipUnreadConfirm;       // 快进未读文本时确认
    public bool SkipOnlyRead;            // 仅跳过已读文本
    public float TextWindowOpacity;      // 文本框透明度（0~1）

    // ═══ 音量设置 ═══
    public float MasterVolume;           // 主音量
    public float BgmVolume;              // BGM 音量
    public float SeVolume;               // 音效音量
    public float SystemSeVolume;         // 系统音效音量（UI 点击等）
    public float VoiceVolume;            // 语音总音量
    public Dictionary<string, float> CharacterVoiceVolume;  // 各角色语音音量（柚子社特色）
    public Dictionary<string, bool> CharacterVoiceEnabled;  // 各角色语音开关

    // ═══ 语音设置 ═══
    public bool VoiceContinueOnAdvance;  // 推进对话后语音继续播放（不中断）
    public bool VoiceReplayOnBacklog;    // Backlog 中点击可重播语音
    public bool TitleCallVoiceEnabled;   // 标题画面语音开关

    // ═══ 画面设置 ═══
    public ScreenMode ScreenMode;        // 全屏 / 窗口 / 无边框窗口
    public Resolution Resolution;        // 分辨率
    public bool EffectEnabled;           // 特效开关（性能弱时可关闭）
    public int TextWindowStyle;          // 文本框样式选择（可切换多种设计）

    // ═══ 操作设置 ═══
    public MouseWheelBehavior MouseWheelUp;    // 鼠标滚轮上：回看历史 / 上一条
    public MouseWheelBehavior MouseWheelDown;  // 鼠标滚轮下：推进 / 下一条
    public bool RightClickBehavior;      // 右键：隐藏文本框 / 打开菜单
    public bool ConfirmOnExit;           // 退出游戏时确认
    public bool ConfirmOnTitle;          // 返回标题时确认

    // ═══ 快捷键设置 ═══
    public Dictionary<string, KeyCode> KeyBindings;  // 可自定义快捷键
}

public enum ScreenMode { Fullscreen, Windowed, BorderlessWindowed }
public enum MouseWheelBehavior { History, Advance, None }
```

**设置界面设计** — 参考柚子社的分 Tab 布局：

```
┌─────────────────────────────────────────────────┐
│  [文字]  [音量]  [语音]  [画面]  [操作]          │
├─────────────────────────────────────────────────┤
│                                                 │
│  ◆ 文字速度      ████████████░░  [80%]          │
│  ◆ 自动播放速度   █████████░░░░░  [60%]          │
│  ◆ 自动播放时等待语音  [✓]                       │
│  ◆ 快进速度      ██████████████  [100%]         │
│  ◆ 仅跳过已读文本  [✓]                          │
│  ◆ 跳过未读时确认  [✓]                          │
│  ◆ 文本框透明度   ██████████░░░░  [70%]          │
│                                                 │
│         [ 恢复默认 ]    [ 确定 ]                 │
└─────────────────────────────────────────────────┘
```

音量 Tab（柚子社特色 — 角色单独控制）：

```
┌─────────────────────────────────────────────────┐
│  ◆ 主音量        ████████████░░  [80%]          │
│  ◆ BGM          ██████████░░░░  [70%]          │
│  ◆ 音效          ████████████░░  [80%]          │
│  ◆ 系统音效      ██████████░░░░  [70%]          │
│  ─── 角色语音 ────────────────────────           │
│  ◆ 樱  [✓]      ████████████░░  [80%] [试听]   │
│  ◆ 海斗 [✓]      ██████████░░░░  [70%] [试听]   │
│  ◆ 凛  [✓]      ████████████░░  [80%] [试听]   │
│  ◆ 语音推进后继续播放  [ ]                       │
└─────────────────────────────────────────────────┘
```

**模块结构：**

```
Settings/
├── GameSettings.cs              -- 设置数据模型
├── GameSettingsManager.cs       -- 设置管理（读取/保存/重置默认/应用）
├── SettingsPresenter.cs         -- 设置界面主控制器
├── Tabs/
│   ├── TextSettingsTab.cs       -- 文字设置 Tab
│   ├── AudioSettingsTab.cs      -- 音量设置 Tab
│   ├── VoiceSettingsTab.cs      -- 语音设置 Tab
│   ├── DisplaySettingsTab.cs    -- 画面设置 Tab
│   └── ControlSettingsTab.cs    -- 操作设置 Tab
├── SettingsSlider.cs            -- 通用滑动条组件（带数值显示）
└── SettingsToggle.cs            -- 通用开关组件
```

**设计要点：**
- 设置变更实时生效（不需要点确认），但提供"恢复默认"
- `GameSettingsManager` 在设置变更时通过 EventBus 发布 `SettingsChangedEvent`
- 各子系统（音频、对话等）订阅设置变更事件并动态调整行为
- 角色语音列表从 `CharacterDatabase` 自动生成

### 4.6 CG 鉴赏 / 回忆模式
- CG 鉴赏、音乐鉴赏、场景回放
- 与 global 变量联动的解锁管理

### 4.7 **[高级] 语音收藏系统（Voice Bookmark）**

玩家可在游戏中收藏喜欢的语音，在专门界面浏览、重播，并可跳转回对应场景继续游玩。

**数据结构：**

```csharp
public class VoiceBookmark
{
    public string BookmarkId;          // 唯一 ID
    public string VoiceAssetId;        // 语音资源 ID
    public string CharacterName;       // 角色名
    public string DialogueText;        // 对应的对话文本
    public string ScenarioId;          // 所在剧本 ID
    public string SceneId;             // 所在场景 ID
    public int CommandIndex;           // 对应指令索引
    public DateTime BookmarkTime;      // 收藏时间
    public SaveData ContextSnapshot;   // 收藏时刻的完整状态快照（用于跳转恢复）
}
```

**模块结构：**

```
VoiceBookmark/
├── VoiceBookmarkManager.cs       -- 收藏管理（增删查、持久化到 global 存储）
├── VoiceBookmarkPresenter.cs     -- 收藏界面 UI（列表/网格、按角色筛选、搜索）
├── VoiceBookmarkTrigger.cs       -- 游戏中的收藏触发（对话框上的收藏按钮）
└── VoiceBookmarkJumper.cs        -- 跳转逻辑（从收藏跳回对应场景）
```

**核心实现思路：**

1. **收藏触发**：对话框 UI 添加"收藏"按钮（心形/星形），点击时 `VoiceBookmarkTrigger` 收集当前上下文：
   - 从 `ScenarioContext` 获取当前 scenarioId / sceneId / commandIndex
   - 从 `SaveManager` 调用各 `ISnapshotProvider` 捕获完整状态快照
   - 构建 `VoiceBookmark` 对象存入 `VoiceBookmarkManager`

2. **收藏界面**：
   - 列表展示所有收藏，显示角色头像、对话文本、语音时长
   - 支持按角色筛选、按时间排序
   - 点击条目 → 重播语音
   - 长按/右键 → "跳转到此场景" 或 "取消收藏"

3. **跳转恢复**：
   - 从 `VoiceBookmark.ContextSnapshot` 恢复完整游戏状态
   - 等同于"读取一个隐藏存档"，复用 `SaveManager` 的 `RestoreSnapshot` 机制
   - 跳转后从该对话的下一条指令继续执行

**存储**：收藏数据存入 global 作用域（跨存档持久化），使用独立的 JSON 文件 `voice_bookmarks.json`。

---

## 5. 编辑器层设计

**方案：Unity Editor 扩展（UI Toolkit + GraphView）**

```
Editor/
├── ScenarioEditor/
│   ├── ScenarioEditorWindow.cs       -- 主窗口
│   ├── ScenarioGraphView.cs          -- 节点图（GraphView）
│   ├── Nodes/                        -- 场景/对话/分支/条件节点
│   ├── Inspectors/                   -- 节点属性面板
│   ├── Serialization/                -- Graph ↔ YAML 双向转换
│   └── Preview/                      -- 实时预览面板
├── ResourceBrowser/                  -- 资源浏览器
└── Tools/                            -- DSL 导入器、剧本验证、批量导出
```

**双粒度视图**：
- 宏观：每个节点 = 一个场景，连线 = 跳转关系
- 微观：选中场景后，侧面板编辑该场景内的指令序列

### 5.1 **[高级] 双端场景跳转（Editor + Runtime）**

**编辑器端 — 节点图快速预览跳转：**
- 在 GraphView 节点上右键菜单 → "从此处预览"
- 调用 `PreviewScenarioRunner`，跳过前面的场景，直接从目标场景开始运行
- 跳转时自动构建最小上下文（推断该场景所需的变量初始值、立绘/背景状态）
- 支持"带条件跳转"：弹窗让用户手动设置关键变量值后再跳入

```
Editor/ScenarioEditor/
├── Preview/
│   ├── LivePreviewPanel.cs           -- 实时预览面板
│   ├── PreviewScenarioRunner.cs      -- 预览用剧情运行器
│   ├── SceneJumpHandler.cs           -- 处理从节点图跳转
│   └── ContextInferencer.cs          -- 推断目标场景所需的最小上下文
```

**运行时端 — 调试面板场景跳转：**
- Debug 面板（仅 Development Build 可用）提供场景列表
- 支持搜索和直接跳转到任意场景
- 跳转时执行 `ScenarioEngine.JumpToScene(sceneId)` 并重建各子系统状态
- 支持设置"断点"：运行到某个场景/指令时自动暂停

```
DebugTools/
├── ScenarioDebugger.cs         -- 运行时调试面板
├── SceneJumper.cs              -- 场景跳转控制
├── BreakpointManager.cs        -- 断点管理
├── VariableWatcher.cs          -- 变量实时监控
├── CommandLogger.cs            -- 指令执行日志
└── ContextBuilder.cs           -- 跳转时重建子系统状态
```

**共享核心**：两端都依赖 `ScenarioEngine.JumpToScene()` + `ISnapshotProvider.RestoreSnapshot()` 机制，编辑器和运行时复用同一套跳转逻辑。

---

## 6. 项目目录结构

```
Assets/
├── Natsume/                   -- 框架核心（UPM Package）
│   ├── Runtime/
│   │   ├── Core/                     -- 纯 C# 核心
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
│   ├── Shaders/                      -- 转场效果 Shader
│   └── package.json                  -- UPM 包描述
├── GameProject/                      -- 具体游戏内容
│   ├── Scenarios/  (YAML/ + DSL/)
│   ├── Characters/
│   ├── Art/  (Backgrounds/ Characters/ CG/ UI/)
│   ├── Audio/  (BGM/ SE/ Voice/)
│   ├── Localization/
│   ├── Scenes/  (Title/Game/Gallery.unity)
│   ├── Prefabs/
│   ├── Config/  (ScriptableObject 配置)
│   └── Scripts/  (自定义扩展)
└── Tests/  (EditMode/ + PlayMode/)
```

---

## 7. 技术选型

| 类别 | 选择 | 理由 |
|------|------|------|
| Unity 版本 | Unity 6 LTS | 稳定，UI Toolkit 成熟，社区接受度高 |
| 文本渲染 | TextMeshPro | 内置，支持富文本、注音 |
| 资源管理 | Addressables | 热更新、按需加载 |
| 动画缓动 | DOTween | 成熟稳定，API 简洁 |
| YAML 解析 | YamlDotNet | NuGet 社区标准 |
| 异步控制 | UniTask | 替代协程，支持 async/await |
| 运行时 UI | uGUI | 游戏内 UI |
| 编辑器 UI | UI Toolkit + GraphView | 官方推荐，节点图天然适合 |
| 可选：Lua | MoonSharp | 高级自定义逻辑扩展 |

---

## 8. 核心设计模式汇总

| 模式 | 应用 |
|------|------|
| **命令模式** | 剧本指令抽象与执行 |
| **事件总线/观察者** | Core ↔ Presentation 层间通信 |
| **状态机** | 游戏宏观流程控制（标题/游戏中/暂停/存档） |
| **策略模式** | 转场效果、文字动画可插拔 |
| **快照/备忘录** | 存档系统各子系统状态捕获与恢复 |
| **服务定位器** | 全局服务注册与访问，替代单例 |

---

## 9. 开发路线图

### Phase 0：基础设施（~1 周）
- 创建项目、UPM 包结构、Assembly Definition 分离
- 引入依赖、实现 EventBus + ServiceLocator

### Phase 1：核心引擎 MVP（~2-3 周）
- YAML 加载器 + 数据模型
- ScenarioEngine 主循环 + CommandRegistry
- 基础指令 Handler（dialogue/bg/char_show/choice）
- 变量系统 + 流程控制（jump/条件分支）
- **里程碑：YAML 脚本驱动一段分支剧情**

### Phase 2：基础表现层（~2-3 周）
- 对话系统（文本框 + 打字机 + 名字）
- 立绘系统 + 背景系统（含 fade 转场）
- 音频系统 + 选项 UI
- **里程碑：视觉小说形式完整演出**

### Phase 3：存档与游戏流程（~1-2 周）
- 存档/读档 + 状态机 + 标题画面
- 自动播放/快进/Backlog/设置面板
- **里程碑：完整游戏循环**

### Phase 4：编辑器基础版（~3-4 周）
- GraphView 节点图 + 属性面板
- Graph ↔ YAML 双向转换
- **里程碑：编辑器创建并导出可运行剧本**

### Phase 5：表现增强 + 语音差分联动（~3-4 周）
- 更多转场 Shader、立绘动画、差分合成
- 文本内联效果、NVL 模式、屏幕特效
- **语音驱动差分切换**：VoiceExpressionSyncController + ExpressionTimeline
- 编辑器：语音波形预览 + 表情时间轴标记编辑器

### Phase 6：DSL + 本地化（~2 周）
- DSL 词法/语法分析 + 双向转译
- 本地化系统 + 文本导出导入

### Phase 7：编辑器增强 + 调试 + 双端跳转（~3-4 周）
- 实时预览、剧本验证（死路检测）
- **编辑器端场景跳转**：节点右键 → 从此处预览，含上下文推断
- **运行时调试面板**：场景跳转、断点、变量监控、指令日志
- 跳转核心：`ScenarioEngine.JumpToScene()` + `ContextBuilder` 状态重建

### Phase 8：高级功能（~3-4 周）
- CG/音乐鉴赏、场景回放、热更新、性能优化
- **语音收藏系统**：收藏按钮 + 收藏界面 + 语音重播 + 跳转恢复（复用存档快照机制）

### Phase 9：开源准备（~1-2 周）
- API 文档、使用指南、示例项目、CI 配置

**总计：约 18-28 周（单人全职）**

---

## 10. 验证方案

由于当前无 Unity 环境，验证将在后续分阶段进行：
- **Phase 0-1**：Core 层为纯 C#，可用 NUnit 单元测试验证（脚本解析、变量求值、流程控制）
- **Phase 2-3**：Play Mode 测试 + 手动验证视觉效果
- **Phase 4+**：编辑器功能手动验证 + 导出剧本的集成测试
- 每个 Phase 结束时用一段 demo 剧本端到端验证
