# Natsume — POC 计划

> 目标：用一段 DSL 剧本（`.ntm`）驱动一个可交互的视觉小说场景，验证从 Core 到 Presentation 的完整链路。

## POC 目标场景

玩家看到：
1. 背景图切换（带 fade 转场）
2. 立绘显示在指定位置
3. 对话框显示角色名 + 文字（打字机效果）
4. 玩家点击推进对话
5. 出现选项分支，玩家选择后跳转到不同场景
6. 循环直到剧本结束

## POC 演示剧本

```ntm
// poc_demo.ntm

@scene start "初次相遇"

@bg bg_school_gate fade 0.8
@show sakura smile center

sakura「你好，初次见面！我叫樱。」
sakura「你是新转来的同学吧？」

@choice "你该怎么回应？"
  - "你好，请多关照！" -> friendly {affection += 5}
  - "……嗯。" -> cold

//========================================
@scene friendly

@expr sakura happy
sakura「太好了，感觉我们能成为好朋友！」
@jump ending

//========================================
@scene cold

@expr sakura sad
sakura「啊……这样啊。那、那我先走了。」
@jump ending

//========================================
@scene ending

「（第一天就这样结束了。）」
@hide sakura
@bg bg_black fade 1.0
@end
```

---

## 已完成（Core 层）

Core 层全部就绪，无需额外工作：

- ScenarioEngine 主循环 + 自动推进 + 跳转
- 8 个 Command Handler（dialogue/bg/char_show/char_hide/choice/jump/condition/set）
- 对话等待机制（WaitController + AdvanceEvent）
- 变量系统 + 表达式求值
- EventBus 事件体系（Core 发事件 → Presentation 订阅响应）

---

## 待实现（Core 层，纯 C#，无需 Unity）

### Step 0：DSL 解析器（Sprint 1-3）

详见 [DSL_IMPL_PLAN.md](DSL_IMPL_PLAN.md)。

```
Sprint 1: DslLexer — 词法分析（.ntm → Token 流）
Sprint 2: DslParser — 语法解析（Token 流 → ScenarioData）
Sprint 3: DslScenarioLoader + 集成测试
```

完成后 Core 层具备直接加载 `.ntm` 剧本的能力，POC 演示剧本可被引擎执行。

---

## 待实现（Presentation 层，需要 Unity）

### Step 1：Bootstrap 初始化

**文件**：`Presentation/Bootstrap/NatsumeRuntime.cs`

```
职责：
- MonoBehaviour，挂在场景 GameObject 上
- Awake 中注册所有 CommandHandler 到 CommandRegistry
- 注册 DslScenarioLoader，配置 .ntm 文件路径
- 注册所有 Presenter 到 ServiceLocator
- 替换 EventBus.Logger 为 UnityEngine.Debug.LogWarning
- 提供 StartScenario(string scenarioId) 方法启动剧情
```

### Step 2：InputProvider — 输入 → AdvanceEvent

**文件**：`Presentation/Input/UnityInputProvider.cs`

```
职责：
- MonoBehaviour，每帧检测输入
- 鼠标左键 / 空格键 / 触屏 → EventBus.Publish(new AdvanceEvent())
- 实现 IInputProvider 接口
```

### Step 3：DialoguePresenter — 对话框 UI

**文件**：`Presentation/Dialogue/DialoguePresenter.cs`

```
职责：
- 订阅 ShowDialogueEvent → 显示对话框
- 订阅 HideDialogueEvent → 隐藏对话框
- 左侧角色头像（face icon）：
  - 有 character 时显示头像 + 角色名
  - 无 character 时（旁白）隐藏头像区域，文本区域扩展到全宽
  - 头像表情来源（优先级从高到低）：
    1. dialogue 指令的 face 参数（显式覆盖，用于 CG/SD CG 等无立绘场景）
    2. 当前立绘状态（CharacterPresenter 追踪的 expression，立绘在场时自动同步）
    3. face_default.png（兜底）
- 角色名显示（NameBox）
- 打字机效果（TMP maxVisibleCharacters 逐字递增）
- 打字机完成后等待玩家点击（配合 AdvanceEvent）

UI 结构：
- Canvas
  - DialoguePanel (底部对话框, HorizontalLayout)
    - FaceIcon (Image, 左侧固定宽度) — 角色头像/半身像
    - TextArea (VerticalLayout, 右侧自适应)
      - NameText (TMP) — 角色名
      - ContentText (TMP) — 对话内容

头像素材约定：
- 路径：Characters/{character}/face_{expression}.png（或 face_default.png）

头像同步机制：
- 常规立绘模式：CharacterPresenter 维护每个角色当前的 expression 状态，
  DialoguePresenter 查询该状态来显示对应头像，立绘切换表情时头像自动同步
- CG / SD CG 模式：场景中无立绘（char_hide 或未 char_show），头像无法从
  立绘状态获取，此时通过 dialogue 指令的 face 参数独立控制：
    sakura「太好了！」 #face:happy     ← CG 场景中独立指定头像表情
```

### Step 4：BackgroundPresenter — 背景显示

**文件**：`Presentation/Background/BackgroundPresenter.cs`

```
职责：
- 订阅 ShowBgEvent → 加载并显示背景图
- 双缓冲：front/back 两个 RawImage
- 转场效果：fade（alpha 渐变，POC 只需 fade）
- 无转场时直接替换

UI 结构：
- Canvas
  - BackgroundLayer
    - BgFront (RawImage)
    - BgBack (RawImage)
```

### Step 5：CharacterPresenter — 立绘显示

**文件**：`Presentation/Character/CharacterPresenter.cs`

```
职责：
- 订阅 CharShowEvent → 加载立绘图片，放到指定位置
- 订阅 CharHideEvent → 隐藏立绘（带转场）
- 订阅 ChangeExpressionEvent → 切换已显示角色的表情
- 位置预设：left / center / right → 对应 x 坐标
- POC 阶段用整张立绘替换，不做差分合成

UI 结构：
- Canvas
  - CharacterLayer
    - CharSlot_Left (Image)
    - CharSlot_Center (Image)
    - CharSlot_Right (Image)
```

### Step 6：ChoicePresenter — 选项 UI

**文件**：`Presentation/Choice/ChoicePresenter.cs`

```
职责：
- 订阅 ShowChoiceEvent → 动态生成选项按钮
- 玩家点击按钮 → EventBus.Publish(new ChoiceSelectedEvent(optionId))
- 选择后销毁按钮

UI 结构：
- Canvas
  - ChoicePanel (居中)
    - PromptText (TMP) — 提示文本
    - OptionButtonPrefab × N — 动态实例化
```

### Step 7：Unity Scene 搭建

```
POC Scene 层级：

Main Camera
EventSystem
NatsumeRuntime (Bootstrap)
UnityInputProvider

Canvas (Screen Space - Overlay)
├── BackgroundLayer (Order 0)
│   ├── BgFront (RawImage, 全屏)
│   └── BgBack (RawImage, 全屏)
├── CharacterLayer (Order 1)
│   ├── CharSlot_Left (Image)
│   ├── CharSlot_Center (Image)
│   └── CharSlot_Right (Image)
├── DialoguePanel (Order 2, 底部)
│   ├── FaceIcon (Image, 左侧)
│   ├── NameText (TMP)
│   └── ContentText (TMP)
└── ChoicePanel (Order 3, 居中, 默认隐藏)
    └── PromptText (TMP)
```

### Step 8：测试资源

POC 不需要正式美术，用占位素材即可：

```
GameProject/
├── Art/
│   ├── Backgrounds/
│   │   ├── bg_school_gate.png    — 任意风景图（1920x1080）
│   │   └── bg_black.png          — 纯黑图
│   └── Characters/
│       └── sakura/
│           ├── smile.png         — 任意立绘（带透明背景）
│           ├── happy.png
│           ├── sad.png
│           ├── face_default.png  — 头像（默认）
│           ├── face_smile.png    — 头像（微笑）
│           ├── face_happy.png    — 头像（开心）
│           └── face_sad.png      — 头像（伤心）
└── Scenarios/
    └── poc_demo.ntm              — POC 演示剧本
```

---

## 数据流总览

```
.ntm 文件
  ↓ DslScenarioLoader.LoadAsync()
      ↓ DslLexer.Tokenize() → Token[]
      ↓ DslParser.Parse() → ScenarioData
ScenarioData
  ↓ ScenarioEngine.LoadScenario() + RunAsync()
CommandData（逐条执行）
  ↓ CommandRegistry.GetHandler(type)
ICommandHandler.ExecuteAsync()
  ↓ EventBus.Publish(Event)
Presentation Presenter（订阅事件 → 更新 UI）
  ↓ 玩家操作
EventBus.Publish(AdvanceEvent / ChoiceSelectedEvent)
  ↓ WaitController / ChoiceCommandHandler TCS resolve
引擎继续执行下一条指令
```

---

## 实现顺序建议

```
Step 0: DSL 解析器（纯 C#）        — 让引擎能读懂 .ntm 剧本
  ↓ 有 Unity 环境后
Step 1: NatsumeRuntime (Bootstrap) — 接线，让引擎能跑起来
Step 2: UnityInputProvider         — 最基本的交互
Step 3: DialoguePresenter          — 能看到文字就算 POC 跑通了
Step 4: BackgroundPresenter        — 背景切换
Step 5: CharacterPresenter         — 立绘显示
Step 6: ChoicePresenter            — 分支选择
Step 7: Scene 搭建 + 测试资源      — 组装运行
```

Step 0 完成后 Core 层可端到端验证（DSL → Engine）。Step 1-3 完成后可看到文字对话跑起来。Step 4-7 补全完整演出。

---

## 环境要求

- Unity 6 LTS（6000.x）
- TextMeshPro（Unity 内置）
- 推荐 Windows + Unity Editor，代码可在 WSL 中用 Claude Code 编写，通过 `/mnt/` 访问项目目录
