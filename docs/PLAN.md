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

**对话框模式**：通过 `IDialoguePresenter` 接口抽象，`dialogue` 指令通过 `mode` 字段切换：

| 模式 | 说明 |
|------|------|
| `adv`（默认） | 底部对话框，标准 Galgame 模式 |
| `nvl` | 全屏文本，文字逐行累积，适合独白、旁白、信件 |
| `overlay` | 无对话框，文字直接叠在画面上（内心独白、回忆闪回） |

```yaml
# 切换到全屏对话模式
- { type: dialogue, mode: "nvl", character: "narrator", text: "那是一个寒冷的冬天..." }
- { type: dialogue, mode: "nvl", text: "风呼啸着穿过空旷的街道。" }

# 切回普通模式
- { type: dialogue, mode: "adv", character: "sakura", text: "你来了。" }
```

游戏项目可注册自定义 `IDialoguePresenter` 实现更多风格。

### 4.1.1 SD 插画（Chibi / 演出用小图）

SD 插画用于对话中插入 Q 版角色小图、表情包、反应图等演出效果，通过 `sd` 指令控制：

```yaml
# 对话框内嵌入 SD 小图
- { type: sd, asset: "sakura_chibi_angry", position: "dialogue_right" }

# 屏幕指定位置弹出 SD 图
- { type: sd, asset: "sakura_chibi_shock", position: { x: 0.7, y: 0.6 }, anim: "pop", duration: 1.5 }

# 清除 SD 插画
- { type: sd_clear }
```

| 参数 | 说明 |
|------|------|
| `position` | 预设位置（`dialogue_left`/`dialogue_right`/`center`/`top`）或自定义坐标 |
| `anim` | 弹出动画（`pop`/`slide`/`bounce`/`fade`） |
| `duration` | 自动消失时间（秒），省略则手动清除 |
| `scale` | 缩放比例，默认 1.0 |

### 4.2 立绘系统
- 通过 `ICharacterRenderer` 接口抽象渲染方式，前期实现静态图片，后续可扩展 Live2D 等
- 内置两种静态模式：整张替换 / 分层合成（身体底图 + 表情差分叠加）
- 位置预设（left/center/right + 自定义）
- 动画（入场/退场/呼吸）
- 表情切换统一为 `SetExpression(string id)`，各 Renderer 内部决定具体行为

**立绘动画指令**：

通过 `char_move` 和 `char_anim` 指令控制立绘运行时动画，基于 DOTween 实现：

```yaml
# 移动到指定位置
- { type: char_move, character: "sakura", position: right, duration: 0.5, ease: OutQuad }

# 播放预设动画
- { type: char_anim, character: "sakura", anim: "jump" }
- { type: char_anim, character: "sakura", anim: "shake", intensity: 8, duration: 0.3 }
- { type: char_anim, character: "sakura", anim: "nod" }

# 可与其他指令并行
- type: parallel
  commands:
    - { type: char_move, character: "sakura", position: center, duration: 0.5 }
    - { type: char_anim, character: "kaito", anim: "shake" }
```

内置动画预设：

| 预设 | 效果 | 典型用途 |
|------|------|---------|
| `jump` | 上下弹跳 | 惊讶、开心 |
| `shake` | 左右震动 | 受惊、愤怒 |
| `nod` | 小幅下移回弹 | 点头 |
| `bounce` | 缩放弹跳 | 兴奋 |
| `fade_in` / `fade_out` | 透明度渐变 | 入场/退场 |
| `slide_in` / `slide_out` | 从屏幕外滑入/滑出 | 入场/退场 |

支持自定义动画：通过注册 `ICharacterAnimation` 实现扩展。

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

一句对话中，角色表情随语音/文字进度自动切换。

#### DSL 中的表达

编剧在文本中用 `[expr:xxx]` 内联标记切换点，标注的是**语义位置**（"说到这里表情该变了"）：

```
sakura「我本来很开心的...[expr:surprised]但是听到这个消息之后...[expr:cry]呜呜...」 #voice:sakura_ch01_042
```

#### 转译为 YAML

转译器自动计算字符位置，生成 `at_char`：

```yaml
- type: dialogue
  character: "sakura"
  text: "我本来很开心的...但是听到这个消息之后...呜呜..."   # [expr:] 标记已移除
  voice: "sakura_ch01_042"
  expression_timeline:
    - { at_char: 0, expression: "smile" }       # 默认表情（角色配置）
    - { at_char: 9, expression: "surprised" }    # 第 9 个字符处
    - { at_char: 21, expression: "cry" }         # 第 21 个字符处
```

#### 双定位模式：at_char vs at

| 字段 | 来源 | 用途 |
|------|------|------|
| `at_char` | DSL 转译自动生成 | 无语音时：打字机到达该字符位置触发切换 |
| `at` | 编辑器波形工具手动标注 | 有语音时：精确秒数，优先级高于 at_char |

**文字位置 ≠ 语音时长**（同样的字说话快慢差异很大），所以有语音时 `at` 必须由编辑器波形工具来标。

#### 工作流

```
编剧 DSL 标记 [expr:xxx]
        ↓
转译器 → YAML（at_char）        ← 无语音到此即可用
        ↓
编辑器波形工具 → 补充 at（秒）    ← 有语音时精确对齐
        ↓
运行时：有 at 用 at，否则 fallback 到 at_char
```

#### 实现模块

```
VoiceExpressionSync/
├── VoiceExpressionSyncController.cs  -- 双模式：监听 AudioSource.time（at）或 TextAnimator 字符进度（at_char）
├── ExpressionTimeline.cs             -- 时间轴数据（at_char + at 并存）
├── ExpressionTimelineEditor.cs       -- 编辑器：波形图上拖拽标记，自动生成 at 秒数
└── VoiceWaveformPreview.cs           -- 语音波形预览
```

### 6.2 语音播放进度条（Voice Progress）

框架提供语音播放状态的实时数据，游戏项目可据此实现进度条 UI。

**框架提供的能力（API，不含 UI）**：

```csharp
public class VoicePlaybackInfo
{
    public bool   IsPlaying;        // 是否正在播放
    public float  CurrentTime;      // 当前播放位置（秒）
    public float  TotalDuration;    // 语音总时长（秒）
    public float  Progress;         // 0~1 归一化进度
    public string CharacterName;    // 当前说话角色
    public string VoiceAssetId;     // 当前语音资源 ID
}

// VoiceController 暴露
public VoicePlaybackInfo GetPlaybackInfo();

// 事件
public struct VoiceStartedEvent : IEvent { ... }
public struct VoiceProgressEvent : IEvent { float Progress; float CurrentTime; }
public struct VoiceFinishedEvent : IEvent { ... }
```

**游戏项目对接示例**：

```csharp
// 游戏项目自己实现进度条 UI
public class VoiceProgressBar : MonoBehaviour
{
    [SerializeField] Slider progressSlider;

    void Update()
    {
        var info = ServiceLocator.Get<VoiceController>().GetPlaybackInfo();
        progressSlider.gameObject.SetActive(info.IsPlaying);
        progressSlider.value = info.Progress;
    }
}
```

**与差分切换联动**：进度条上可叠加显示 expression_timeline 的标记点，让玩家看到表情切换时刻。这是游戏项目的 UI 层行为，框架只提供数据。

**扩展点**：`VoiceController` 已有 `AudioSource.time` / `AudioClip.length`，只需封装为 `VoicePlaybackInfo` 并定时发布 `VoiceProgressEvent`。

### 6.3 语音收藏系统（Voice Bookmark）

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

### 6.4 双端场景跳转（Editor + Runtime）

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

### 6.5 DSL 脚本系统

轻量 DSL ↔ YAML 双向转译。

```
ScriptParser/
├── DslLexer.cs / DslParser.cs         -- 词法/语法分析
├── DslToYamlCompiler.cs               -- DSL → YAML
├── YamlToDslDecompiler.cs             -- YAML → DSL
└── Editor/DslImporter.cs              -- .novel 文件 Asset Importer
```

### 6.6 本地化系统

对话文本用 `text_key` 引用本地化表，支持导出 CSV 供翻译。

### 6.7 热更新

基于 Addressables Remote Content Catalog，剧本/资源按章节分包。

### 6.8 跨端支持（iOS / Android）

目标平台：PC（优先） + iOS + Android。

**输入抽象** — 将具体输入映射为语义动作：

```csharp
public enum InputAction
{
    Advance,        // 推进对话（点击/触摸/手柄A）
    Cancel,         // 取消/返回（右键/返回键/手柄B）
    ShowMenu,       // 打开菜单
    HistoryPrev,    // 回看上一条（滚轮上/上滑）
    HistoryNext,    // 回看下一条（滚轮下/下滑）
    ToggleAuto,     // 切换自动播放
    ToggleSkip,     // 切换快进
    HideUI,         // 隐藏文本框
    QuickSave,      // 快速存档
    QuickLoad,      // 快速读档
}

public interface IInputProvider
{
    bool IsActionTriggered(InputAction action);
    Vector2 GetPointerPosition();  // 鼠标/触摸位置
}
```

框架内置 `DesktopInputProvider`（鼠标+键盘），游戏项目可注册 `MobileInputProvider`（触摸+手势）。

**其他跨端注意事项**（前期架构预留，后期实现）：

| 问题 | 方案 |
|------|------|
| 存档路径 | `ISaveStorage` 已抽象，移动端用 `Application.persistentDataPath` |
| 屏幕适配 | UI 用 Canvas Scaler（Scale With Screen Size），立绘/背景基于安全区适配 |
| 刘海屏/挖孔屏 | `Screen.safeArea` 控制文本框和 UI 不超出安全区 |
| 性能 | `GameSettings.EffectEnabled` 可关闭特效；资源按平台出包（低分辨率立绘） |
| 触摸手势 | 单指点击=推进、双指=隐藏 UI、上滑=Backlog（可在 MobileInputProvider 中配置） |

**扩展点**：`IInputProvider` 接口在 Sprint 1 定义，`DesktopInputProvider` 在 Sprint 2 实现，移动端实现放在 P3。

### 6.9 Live2D 立绘支持

通过 `ICharacterRenderer` 接口扩展，新增 `Live2DCharacterRenderer` 实现。

**角色配置**：
```yaml
id: "sakura"
render_mode: "live2d"   # sprite / layered / live2d
model: "sakura/sakura.model3.json"
expressions:
  smile: "expr_smile"     # Live2D Expression ID
  cry: "expr_cry"
motions:
  idle: "motion_idle"     # Live2D Motion ID
  talk: "motion_talk"
```

**依赖**：Live2D Cubism SDK for Unity（免费，商用需授权）。

**扩展点**：`ICharacterRenderer` 接口在 Sprint 2 定义，`SpriteCharacterRenderer` 和 `LayeredCharacterRenderer` 先行实现；`Live2DCharacterRenderer` 后续作为独立模块接入，不影响核心代码。表情切换统一走 `SetExpression(string id)`，Live2D 内部映射为 Cubism Expression/Motion。

---

## 七、使用指南

详见 [USAGE.md](USAGE.md) — 包含安装、快速上手、剧本编写、角色配置、自定义扩展、API 总览及各模块验收标准。

---

## 八、项目目录结构

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

## 九、技术选型

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

## 十、开发路线图（Agent Team 模式）

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
| Live2D | `ICharacterRenderer` 接口抽象渲染方式；角色配置支持 `render_mode` 字段；`SetExpression` 统一表情切换入口 |

---

## 十一、测试策略

### 测试基础设施

**CI 配置**：GitHub Actions + Unity `-batchmode -runTests`，每次 PR 自动运行全部测试。

**测试分类**：

| 类型 | 框架 | 运行环境 | 用途 |
|------|------|---------|------|
| **Edit Mode Test** | NUnit | 不需要 Unity 运行时 | 纯 C# 逻辑（Core 层全部） |
| **Play Mode Test** | NUnit + UnityTest | 需要 Unity 运行时，无需 GUI 交互 | 表现层行为、系统集成 |
| **集成测试剧本** | 自定义 YAML 测试场景 | Play Mode | 端到端流程验证 |
| **截图回归测试** | Play Mode + ImageAssert | Play Mode | 视觉效果变更检测 |

### 测试规范

每个 agent 提交的模块必须附带对应测试，**测试通过是合入条件**。

---

### Sprint 1 — 核心骨架

全部 Edit Mode Test，100% 自动化。

```
Tests/EditMode/
├── EventBusTests.cs              -- 发布/订阅/取消订阅、多订阅者、事件隔离
├── ServiceLocatorTests.cs        -- 注册/获取/覆盖注册/未注册异常
└── InterfaceContractTests.cs     -- 反射扫描：确保所有 ICommandHandler 实现都有 CommandType
```

### Sprint 2 — 引擎 + 表现层

**Edit Mode（Core 逻辑）**：
```
Tests/EditMode/
├── ScriptParser/
│   ├── YamlScenarioLoaderTests.cs     -- YAML 解析正确性、畸形数据容错、嵌套结构
│   └── CommandDataTests.cs            -- 参数提取、类型转换、缺省值
├── ScenarioEngine/
│   ├── ScenarioEngineTests.cs         -- 指令顺序执行、场景跳转、空场景处理
│   ├── CommandExecutorTests.cs        -- Handler 查找、未注册类型报错
│   ├── WaitControllerTests.cs         -- 等待/完成回调
│   └── FlowControlTests.cs           -- jump、条件分支（true/false 路径）、子程序调用栈
├── VariableSystem/
│   ├── VariableStoreTests.cs          -- 三个作用域读写、类型转换、不存在的变量
│   └── ExpressionEvaluatorTests.cs    -- 算术、比较、逻辑组合、嵌套括号、语法错误
└── Commands/
    └── CommandRegistryTests.cs        -- 注册、重复注册、按 type 查找
```

**Play Mode（表现层行为）**：
```
Tests/PlayMode/
├── Dialogue/
│   ├── TextAnimatorTests.cs           -- 打字机效果：逐字显示计时、内联标签（wait/speed）、完成回调
│   └── DialoguePresenterTests.cs      -- 显示对话 → 文本内容正确、角色名正确、语音触发
├── Character/
│   ├── CharacterPresenterTests.cs     -- 显示/隐藏/切换位置/表情切换
│   └── ExpressionControllerTests.cs   -- 差分合成：底图+面部图层叠正确
├── Background/
│   └── BackgroundPresenterTests.cs    -- 切换背景、转场完成回调、双缓冲交换
├── Audio/
│   ├── BgmControllerTests.cs          -- 播放/暂停/淡入淡出/交叉混合
│   ├── SeControllerTests.cs           -- 多通道并行播放
│   └── VoiceControllerTests.cs        -- 播放/停止/播放完成事件
└── Integration/
    └── ScenarioIntegrationTests.cs    -- 加载测试 YAML → 自动推进 → 断言最终状态
```

**集成测试剧本** — `Tests/Fixtures/test_all_commands.yaml`：

```yaml
# 覆盖所有指令类型的测试剧本
scenes:
  - id: "test_dialogue"
    commands:
      - { type: bg, asset: "test_bg", transition: { type: fade, duration: 0.1 } }
      - { type: char_show, character: "test_char", expression: "default", position: center }
      - { type: dialogue, character: "test_char", text: "测试文本" }
      - { type: set, var: "flag_a", value: 1 }
      - { type: condition, if: "flag_a == 1", then: { jump: "test_choice" }, else: { jump: "test_fail" } }
  - id: "test_choice"
    commands:
      - { type: choice, style: "text", options: [{ id: "a", label: "A", jump: "test_parallel" }] }
  - id: "test_parallel"
    commands:
      - type: parallel
        commands:
          - { type: bg, asset: "test_bg_2", transition: { type: fade, duration: 0.1 } }
          - { type: char_show, character: "test_char", expression: "smile" }
      - { type: dialogue, character: "test_char", text: "并行指令测试通过" }
      - { type: jump, target: "test_end" }
  - id: "test_end"
    commands:
      - { type: set, var: "test_completed", value: true }
  - id: "test_fail"
    commands:
      - { type: set, var: "test_completed", value: false }
```

```csharp
[UnityTest]
public IEnumerator AllCommands_ExecuteCorrectly()
{
    var engine = SetupTestEngine("test_all_commands");
    engine.Start();

    // 自动推进所有对话（模拟点击）
    while (!engine.IsFinished)
    {
        if (engine.IsWaitingForClick) engine.AdvanceClick();
        if (engine.IsWaitingForChoice) engine.SelectChoice("a");
        yield return null;
    }

    Assert.IsTrue(engine.Context.Variables.GetBool("test_completed"));
}
```

### Sprint 3 — 游戏体验完善

**Edit Mode**：
```
Tests/EditMode/
├── SaveSystem/
│   ├── SaveSerializerTests.cs         -- 序列化/反序列化一致性、版本迁移
│   ├── SaveManagerTests.cs            -- 存档/读档/删除/列表、存档槽位上限
│   └── SnapshotTests.cs              -- 各 Provider 快照捕获/恢复数据一致
├── Settings/
│   ├── GameSettingsTests.cs           -- 默认值、修改后持久化、重置
│   └── GameSettingsManagerTests.cs    -- JSON 读写、事件发布
└── PlaybackControl/
    ├── ReadFlagManagerTests.cs        -- 已读标记：标记/查询/持久化
    └── BacklogManagerTests.cs         -- 记录添加、容量限制、按索引查询
```

**Play Mode**：
```
Tests/PlayMode/
├── SaveLoad/
│   └── SaveLoadIntegrationTests.cs    -- 运行剧本到中间 → 存档 → 修改状态 → 读档 → 断言状态恢复
├── Settings/
│   └── SettingsApplyTests.cs          -- 修改 CharacterInterval → 断言打字速度变化
│                                          修改 BgmVolume → 断言 AudioSource.volume 变化
├── PlaybackControl/
│   ├── AutoPlayTests.cs              -- 开启自动 → 断言对话按设定间隔自动推进
│   ├── SkipTests.cs                  -- 快进已读 → 跳过；快进未读 → 停止（SkipOnlyRead=true）
│   └── BacklogReplayTests.cs         -- 打开 Backlog → 点击条目 → 断言语音重播触发
└── Choice/
    └── ChoicePresenterTests.cs        -- 显示选项 → 模拟选择 → 断言返回正确 id + 跳转
```

### Sprint 4 — 编辑器

Editor 测试用 Edit Mode，通过代码操作 GraphView 对象：

```
Tests/EditMode/
└── Editor/
    ├── GraphSerializationTests.cs     -- 构建 Graph → 转 YAML → 转回 Graph → 断言节点/连线一致
    ├── NodeCreationTests.cs           -- 代码创建各类节点 → 断言端口数量、属性默认值
    └── YamlRoundTripTests.cs          -- YAML → Graph → YAML → 断言两份 YAML 内容等价
```

### Sprint 5 — 表现增强 + 鉴赏

**Play Mode**：
```
Tests/PlayMode/
├── Transition/
│   └── TransitionEffectTests.cs       -- 每种转场效果执行 → 断言完成回调触发、front/back 交换
├── Character/
│   └── CharacterAnimationTests.cs     -- 入场/退场动画 → 断言位置/透明度变化
├── Gallery/
│   ├── UnlockManagerTests.cs          -- 设置 global 变量 → 断言解锁状态
│   └── CgGalleryTests.cs             -- 解锁 CG → 鉴赏列表包含该 CG
```

**截图回归测试**（可选，用于视觉变更检测）：
```csharp
[UnityTest]
public IEnumerator FadeTransition_MatchesBaseline()
{
    SetupBackground("test_bg_1");
    yield return ExecuteTransition("fade", "test_bg_2", 0.5f);

    var screenshot = CaptureScreenshot();
    ImageAssert.AreEqual(LoadBaseline("fade_transition"), screenshot, tolerance: 0.01f);
}
```

### Sprint 6 — 高级扩展

**Edit Mode**：
```
Tests/EditMode/
├── DSL/
│   ├── DslLexerTests.cs               -- 词法分析：各 token 类型识别、错误行号报告
│   ├── DslParserTests.cs              -- 语法分析：各语法结构解析正确
│   └── DslRoundTripTests.cs           -- DSL → YAML → DSL → 断言等价
├── Localization/
│   └── LocalizationManagerTests.cs    -- 多语言加载、key 查找、缺失 key 回退
└── VoiceBookmark/
    └── VoiceBookmarkManagerTests.cs   -- 添加/删除/查询/持久化
```

**Play Mode**：
```
Tests/PlayMode/
├── VoiceExpressionSync/
│   └── ExpressionTimelineTests.cs     -- 播放语音 → 到达时间标记 → 断言表情切换事件触发
├── Debug/
│   └── SceneJumpTests.cs             -- JumpToScene → 断言各子系统状态正确重建
└── VoiceBookmark/
    └── BookmarkJumpTests.cs          -- 收藏 → 跳转 → 断言完整状态恢复
```

### Sprint 7 — CI + 最终验收

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: game-ci/unity-test-runner@v4
        with:
          testMode: all          # EditMode + PlayMode
          unityVersion: 6000.x
          coverageOptions: generateBadges
      - uses: actions/upload-artifact@v4
        with:
          name: coverage-report
          path: CodeCoverage/
```

最终验收：完整示例项目自动测试跑通 = 全部功能可用。

---

### 测试覆盖目标

| 层 | 目标覆盖率 | 测试类型 | 说明 |
|----|-----------|---------|------|
| **Core 层** | ≥90% | Edit Mode | 纯逻辑，必须高覆盖 |
| **Presentation 层** | ≥70% | Play Mode | 行为逻辑可测，视觉效果靠截图回归 |
| **Editor 层** | ≥60% | Edit Mode | 序列化/反序列化必测，GUI 交互难自动化 |
| **集成** | 关键路径 100% | Play Mode | 测试剧本覆盖所有指令类型和流程分支 |

### 每个 Sprint 的验证方式

| Sprint | 自动化测试 | 人工验证 |
|--------|-----------|---------|
| Sprint 1 | Edit Mode：接口契约、EventBus、ServiceLocator | review 接口设计 |
| Sprint 2 | Edit Mode：解析/变量/引擎逻辑；Play Mode：表现层行为 + 集成剧本 | 视觉效果确认（首次搭建场景） |
| Sprint 3 | Edit Mode：存档序列化/设置持久化；Play Mode：存读档一致性、设置生效、播放控制 | 完整游戏循环体验 |
| Sprint 4 | Edit Mode：Graph ↔ YAML 往返一致性 | 编辑器 GUI 交互体验 |
| Sprint 5 | Play Mode：转场完成/动画行为 + 截图回归 | 视觉效果审美确认 |
| Sprint 6 | Edit Mode：DSL 往返/本地化/收藏管理；Play Mode：语音同步/跳转恢复 | 高级功能体验 |
| Sprint 7 | CI 全量测试 + 示例项目自动跑通 | 最终整体体验 |
