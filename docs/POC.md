# Stella — POC 计划

> 目标：用一段 DSL 剧本（`.stl`）驱动一个可交互的视觉小说场景，验证从 Core 到 Presentation 的完整链路。

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
// demo.stl

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

## 实现步骤

POC 覆盖 PLAN.md 的 Sprint 1-4，分为 Core 层（纯 GDScript，无需 Godot 场景）和 Presentation 层（需要 Godot 场景树）。

### Step 0：项目脚手架

**目标**：可运行的 Godot 项目 + GUT 测试框架。

| 任务 | 产出 |
|------|------|
| 创建 Godot 项目（project.godot） | 可在 Godot 编辑器中打开 |
| 搭建 `addons/stella/` 目录结构 | plugin.cfg + 空目录 |
| 安装 GUT 测试框架 | `addons/gut/`，可在编辑器中运行测试 |
| 配置 SignalBus Autoload | `autoload/signal_bus.gd` 注册为 Autoload |

**验收**：
- [ ] `godot --headless` 不报错
- [ ] GUT 可运行空测试

---

### Step 1：核心数据模型

**目标**：定义所有 Core 层共用的数据结构。

**新建文件**：

| 文件 | 说明 |
|------|------|
| `core/data/scenario_data.gd` | ScenarioData：id, title, scenes[] |
| `core/data/scene_data.gd` | SceneData：id, commands[] |
| `core/data/command_data.gd` | CommandData：type, params{}，类型安全访问器 |
| `core/data/choice_data.gd` | ChoiceData：prompt, options[]（ChoiceOption: id, label, jump, set, condition） |
| `tests/unit/test_command_data.gd` | CommandData 参数访问测试 |

```gdscript
# command_data.gd 核心设计
class_name CommandData extends RefCounted

var type: String
var params: Dictionary

func get_string(key: String, default: String = "") -> String:
    return str(params.get(key, default))

func get_float(key: String, default: float = 0.0) -> float:
    return float(params.get(key, default))

func get_int(key: String, default: int = 0) -> int:
    return int(params.get(key, default))

func get_bool(key: String, default: bool = false) -> bool:
    var val = params.get(key, default)
    if val is bool:
        return val
    return str(val).to_lower() == "true"
```

**验收**：
- [ ] CommandData 类型安全访问器测试通过
- [ ] ScenarioData/SceneData 构造和遍历正确

---

### Step 2：命令系统 + 剧情引擎

**目标**：引擎可加载 ScenarioData 并逐条执行命令。

**新建文件**：

| 文件 | 说明 |
|------|------|
| `core/commands/command_handler.gd` | CommandHandler 基类 |
| `core/commands/command_registry.gd` | 命令注册表 |
| `core/scenario_engine/scenario_engine.gd` | 主引擎 |
| `core/scenario_engine/scenario_context.gd` | 运行时上下文 |
| `core/scenario_engine/wait_controller.gd` | 等待控制（TCS 模式） |
| `tests/unit/test_command_registry.gd` | 注册/查找测试 |
| `tests/unit/test_scenario_engine.gd` | 引擎主循环/跳转/自动推进测试 |
| `tests/unit/test_wait_controller.gd` | 等待/完成测试 |

**WaitController 设计**（GDScript 的 TCS 等价实现）：

```gdscript
class_name WaitController extends RefCounted

var _completed: bool = false

func wait() -> void:
    _completed = false
    while not _completed:
        await Engine.get_main_loop().process_frame

func complete() -> void:
    _completed = true
```

**验收**：
- [ ] 引擎可加载 ScenarioData，逐条执行命令
- [ ] jump 跳转正确
- [ ] 多场景自动推进（当前场景执行完进入下一场景）
- [ ] 引擎结束时发出 scenario_ended 信号

---

### Step 3：变量系统 + 基础命令处理器

**目标**：POC 所需的全部 Core 层逻辑就绪。

**新建文件**：

| 文件 | 说明 |
|------|------|
| `core/variable_system/variable_store.gd` | 三作用域变量存储 |
| `core/variable_system/expression_evaluator.gd` | 条件表达式求值 |
| `core/commands/dialogue_handler.gd` | dialogue → 发信号 → 等待推进 |
| `core/commands/bg_handler.gd` | bg → 发信号 |
| `core/commands/char_show_handler.gd` | char_show → 发信号 |
| `core/commands/char_hide_handler.gd` | char_hide → 发信号 |
| `core/commands/char_expr_handler.gd` | char_expr → 发信号 |
| `core/commands/choice_handler.gd` | choice → 发信号 → 等待选择 → jump + set |
| `core/commands/jump_handler.gd` | 设置 pending_jump |
| `core/commands/condition_handler.gd` | 求值表达式 → jump |
| `core/commands/set_handler.gd` | 写入 VariableStore（支持 =, +=, -=） |
| `tests/unit/test_variable_store.gd` | 三作用域/快照/恢复 |
| `tests/unit/test_expression_evaluator.gd` | 比较/逻辑/bool 求值 |
| `tests/unit/test_command_handlers.gd` | 各 handler 信号发布测试 |

**Handler → SignalBus 参数对照**：

| Handler | SignalBus 信号 | 参数 |
|---------|---------------|------|
| dialogue_handler | `show_dialogue` | character, text, voice, mode |
| bg_handler | `bg_changed` | asset, transition, duration |
| char_show_handler | `char_show` | character, expression, position |
| char_hide_handler | `char_hide` | character |
| char_expr_handler | `char_expression_changed` | character, expression |
| choice_handler | `choice_show` | prompt, options |
| set_handler | `variable_changed` | var_name, value |

**验收**：
- [ ] 所有 handler 发出正确信号
- [ ] dialogue_handler 等待 `advance_requested` 信号后才返回
- [ ] choice_handler 等待 `choice_selected` 信号后 jump + set
- [ ] 变量存储三作用域优先级正确
- [ ] 表达式求值 `affection >= 5` 等正确

---

### Step 4：DSL 解析器

**目标**：将 `.stl` 文本解析为 ScenarioData。

**新建文件**：

| 文件 | 说明 |
|------|------|
| `core/script_parser/dsl_token.gd` | DslTokenType 枚举 + DslToken |
| `core/script_parser/dsl_lexer.gd` | `tokenize(source: String) -> Array[DslToken]` |
| `core/script_parser/dsl_parser.gd` | `parse(tokens: Array, scenario_id: String) -> ScenarioData` |
| `core/script_parser/dsl_parse_error.gd` | 解析错误（携带行号） |
| `tests/unit/test_dsl_lexer.gd` | 词法分析测试（~15 个） |
| `tests/unit/test_dsl_parser.gd` | 语法解析测试（~25 个） |
| `tests/integration/test_dsl_to_engine.gd` | DSL → Engine 端到端测试 |

**Token 类型**：

```gdscript
enum DslTokenType {
    SCENE_DIRECTIVE,   # @scene id ["title"]
    AT_COMMAND,        # @bg, @show, @hide, @expr, @set, @if, @else, @end, @jump, ...
    DIALOGUE,          # sakura「text」 [#voice:id]
    NARRATION,         # 「text」
    MONOLOGUE,         # sakura（text）
    CHOICE_OPTION,     # - "text" -> target [{var op val}] [?if expr]
}
```

**Parser 生成的 CommandData 对照**（必须与 Handler 预期 key 完全匹配）：

| DSL 语法 | CommandData type | params |
|----------|-----------------|--------|
| `sakura「text」#voice:id` | `dialogue` | character, text, voice?, mode |
| `「text」` | `dialogue` | text, mode |
| `@bg asset fade 0.8` | `bg` | asset, transition?, duration? |
| `@show char expr pos` | `char_show` | character, expression?, position? |
| `@hide char` | `char_hide` | character |
| `@expr char expr` | `char_expr` | character, expression |
| `@choice "prompt"` + options | `choice` | prompt?, options |
| `@set var = value` | `set` | var, value, op? |
| `@if expr` / `@else` / `@end` | `condition` | if, then_jump, else_jump |
| `@jump target` | `jump` | target |

**@if/@else/@end 展平算法**：

Parser 维护 `if_stack`。遇到 `@if` 压栈，后续指令收集到 then_commands；遇到 `@else` 切换到 else_commands；遇到 `@end` 出栈，生成合成场景，在原场景插入 condition 命令。

合成场景 ID 格式：`__if_{scene_id}_{line_num}_{then|else|cont}`。

**验收**：
- [ ] Lexer 正确分词（注释跳过、空行跳过、各 token 类型识别）
- [ ] Parser 正确生成 ScenarioData（含默认值填充）
- [ ] DSL → Engine 端到端：加载 POC 剧本 → 引擎执行 → 验证信号发布序列
- [ ] @if/@else/@end 展平生成正确的合成场景和 condition 命令

---

### Step 5：Presentation 层 — 基础 UI

**目标**：Godot 场景中显示对话、背景、立绘、选项。

**新建文件**：

| 文件 | 说明 |
|------|------|
| `autoload/stella_runtime.gd` | Autoload 入口：注册 handler、初始化引擎、加载剧本 |
| `presentation/dialogue/dialogue_presenter.gd` | 订阅 `show_dialogue` → 打字机效果 → 等待点击 |
| `presentation/dialogue/dialogue_presenter.tscn` | 对话框场景（Panel + RichTextLabel + NameLabel） |
| `presentation/dialogue/text_animator.gd` | 打字机效果（visible_characters 递增 + Timer） |
| `presentation/background/background_presenter.gd` | 订阅 `bg_changed` → 加载背景 → fade 转场 |
| `presentation/background/background_presenter.tscn` | 双缓冲场景（2x TextureRect） |
| `presentation/character/character_presenter.gd` | 订阅 char_show/hide/expr → 管理立绘 |
| `presentation/choice/text_choice_presenter.gd` | 订阅 `choice_show` → 动态生成按钮 → 发射 `choice_selected` |
| `presentation/choice/text_choice_presenter.tscn` | 选项面板（VBoxContainer + Button 模板） |
| `presentation/input/input_handler.gd` | 鼠标点击/空格 → `advance_requested` 信号 |

**Godot 场景树**：

```
Main (Node2D)
├── BackgroundLayer (CanvasLayer, layer 0)
│   ├── BgFront (TextureRect, 全屏)
│   └── BgBack (TextureRect, 全屏)
├── CharacterLayer (CanvasLayer, layer 1)
│   ├── SlotLeft (TextureRect)
│   ├── SlotCenter (TextureRect)
│   └── SlotRight (TextureRect)
├── UILayer (CanvasLayer, layer 2)
│   ├── DialoguePanel (PanelContainer, 底部)
│   │   ├── FaceIcon (TextureRect, 左侧)
│   │   ├── NameLabel (Label)
│   │   └── ContentLabel (RichTextLabel)
│   └── ChoicePanel (VBoxContainer, 居中, 默认隐藏)
│       └── PromptLabel (Label)
├── InputHandler (Node)
└── StellaRuntime (Node)  -- 或通过 Autoload 初始化
```

**DialoguePresenter 核心流程**：

```gdscript
func _ready():
    SignalBus.show_dialogue.connect(_on_show_dialogue)

func _on_show_dialogue(character: String, text: String, voice: String, mode: String):
    name_label.text = character
    content_label.text = text
    content_label.visible_characters = 0
    _is_typing = true
    # 打字机效果由 text_animator 驱动
    await text_animator.animate(content_label)
    _is_typing = false
    # 等待玩家点击
    await SignalBus.advance_requested
```

**BackgroundPresenter fade 转场**：

```gdscript
func _on_bg_changed(asset: String, transition: String, duration: float):
    var texture = load("res://game/art/backgrounds/%s.png" % asset)
    bg_back.texture = texture
    var tween = create_tween()
    tween.tween_property(bg_back, "modulate:a", 1.0, duration)
    tween.parallel().tween_property(bg_front, "modulate:a", 0.0, duration)
    await tween.finished
    bg_front.texture = texture
    bg_front.modulate.a = 1.0
    bg_back.modulate.a = 0.0
```

**验收**：
- [ ] 运行 POC 剧本，背景正确显示并 fade 切换
- [ ] 立绘在指定位置显示，表情切换正确
- [ ] 对话文字逐字显示（打字机效果），点击推进
- [ ] 选项正确显示，选择后跳转到正确场景
- [ ] 旁白（无角色名）正确显示
- [ ] 整个剧本可从头到尾完整跑通

---

### Step 6：测试素材

POC 不需要正式美术，用占位素材即可：

```
game/
├── art/
│   ├── backgrounds/
│   │   ├── bg_school_gate.png    — 任意风景图（1920×1080）
│   │   └── bg_black.png          — 纯黑图
│   └── characters/
│       └── sakura/
│           ├── smile.png         — 任意立绘（带透明背景）
│           ├── happy.png
│           ├── sad.png
│           └── default.png
└── scenarios/
    └── demo.stl              — POC 演示剧本
```

可用纯色矩形 + 文字标注作为临时素材，先跑通流程。

---

## 数据流总览

```
.stl 文件
  ↓ DslLexer.tokenize()
Token[]
  ↓ DslParser.parse()
ScenarioData
  ↓ ScenarioEngine.load_scenario() + run()
CommandData（逐条执行）
  ↓ CommandRegistry.get_handler(type)
CommandHandler.execute()
  ↓ SignalBus.signal.emit()
Presentation Presenter（连接信号 → 更新 UI）
  ↓ 玩家操作
SignalBus.advance_requested / choice_selected
  ↓ WaitController.complete()
引擎继续执行下一条指令
```

---

## 实施顺序总结

```
Step 0: 项目脚手架 + GUT            — 空项目可运行
Step 1: 核心数据模型                 — 数据结构就绪
Step 2: 命令系统 + 引擎              — 引擎可执行指令序列
Step 3: 变量 + 基础命令处理器         — Core 层完整
Step 4: DSL 解析器                   — .stl 驱动引擎
Step 5: Presentation 层              — 可看到完整演出
Step 6: 测试素材 + 组装运行           — POC 完成
```

Step 0-4 为纯 GDScript 逻辑，可通过 GUT 单元测试验证，不需要 Godot 场景。
Step 5-6 需要在 Godot 编辑器中搭建场景并运行。

---

## POC 完成标准

- [ ] `demo.stl` 可从头到尾完整运行
- [ ] 背景 fade 切换正确
- [ ] 立绘显示/隐藏/表情切换正确
- [ ] 对话打字机效果正常，点击推进
- [ ] 选择分支跳转正确，变量 affection 正确修改
- [ ] 旁白正确显示（无角色名）
- [ ] 剧本结束后引擎正确停止
- [ ] GUT 单元测试全部通过（Core 层 ≥ 90% 覆盖）
