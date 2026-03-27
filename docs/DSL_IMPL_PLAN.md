# DSL 解析器实现计划

## Context

Natsume 框架决定从「DSL + YAML 双层」改为「DSL Only」方案。DSL (`.ntm` 文件) 成为唯一脚本格式，Core 层直接解析 DSL 为 ScenarioData。

**动机**：行业主流 VN 引擎（Ren'Py、KiriKiri/KAG、Naninovel）都用 DSL 作为唯一格式。双层方案增加了维护成本和双向转译复杂度，没有实际收益。

**新管线**：`.ntm` text → DslLexer → Token[] → DslParser → ScenarioData → ScenarioEngine（不变）

**约束**：输出的 ScenarioData/SceneData/CommandData 结构不变，下游引擎和所有 Handler 无感知。

---

## 关键设计决策

### 1. @if/@else/@end → 合成场景展平

引擎是线性执行模型（顺序遍历 Commands，检查 PendingJump）。条件块通过生成合成场景实现：

```
@if has_key                        condition { if: "has_key", then_jump: "__if_start_3_then", else_jump: "__if_start_3_else" }
  sakura「有钥匙！」     →         合成场景 __if_start_3_then: [dialogue, jump → __if_start_3_cont]
@else                              合成场景 __if_start_3_else: [dialogue, jump → __if_start_3_cont]
  sakura「没钥匙...」              合成场景 __if_start_3_cont: [后续指令...]
@end
```

合成场景 ID 格式：`__if_{sceneId}_{lineNum}_{then|else|cont}`，双下划线前缀避免与用户场景冲突。

### 2. @expr → 发布 ChangeExpressionEvent

`ChangeExpressionEvent` 已存在于 CoreEvents.cs。新增 `CharExprCommandHandler`（type: `"char_expr"`），发布该事件。不复用 `char_show`，语义更清晰。

### 3. @set var += 5 → 修改 SetCommandHandler

Parser 输出 `CommandData("set", { var, value, op: "+=" })`。SetCommandHandler 增加 `op` 参数检查，支持 `+=` 和 `-=`。

### 4. @hide all → 直传 "all"

Parser 输出 `CommandData("char_hide", { character: "all" })`。CharHideEvent.Character 为 "all"，由 Presentation 层处理。无需改 Core 层 handler。

### 5. @nvl / @overlay → 纯 Parser 状态

Parser 维护 `currentMode` 变量。遇到 `@nvl` 设为 `"nvl"`，`@nvl off` 重置为 `"adv"`。后续 dialogue 命令自动携带 `mode` 参数。不产生独立命令。

### 6. 句内标签 [expression] / {wait:500} → 透传给 Presentation

Core 层不解析这些标签，原样保留在 text 中。Presentation 层的打字机效果在渲染时解释处理。

---

## Sprint 计划

### Sprint 1：DslLexer — 词法分析

**目标**：将 `.ntm` 文本按行分词为 Token 流。

**新建文件**：
| 文件 | 说明 |
|------|------|
| `Core/ScriptParser/DslToken.cs` | DslTokenType 枚举 + DslToken 结构体 |
| `Core/ScriptParser/DslLexer.cs` | 静态类，`Tokenize(string source) → List<DslToken>` |
| `Tests/EditMode/DslLexerTests.cs` | 词法分析测试 |

**Token 类型**：
```csharp
public enum DslTokenType
{
    SceneDirective,   // @scene id ["title"]
    AtCommand,        // @bg, @show, @hide, @expr, @set, @if, @else, @end, @jump, ...
    Dialogue,         // sakura「text」 [#voice:id]
    Narration,        // 「text」
    Monologue,        // sakura（text）
    ChoiceOption,     // - "text" -> target [{var op val}] [?if expr]
}
```

**DslToken 结构**：
```csharp
public struct DslToken
{
    public DslTokenType Type;
    public string RawText;    // 原始行文本（去除首尾空白）
    public int Line;          // 行号（1-based，用于错误提示）
    public int Indent;        // 缩进层级（空格数）
}
```

**分词规则**（按优先级）：
1. `//` 开头 → 跳过（注释）
2. 空行 → 跳过
3. `@scene ` 开头 → SceneDirective
4. `@` 开头 → AtCommand
5. `- "` 或 `- "` 开头（去缩进后）→ ChoiceOption
6. 包含 `「...」` 且有角色前缀 → Dialogue
7. `「` 开头 → Narration
8. 包含 `（...）` 且有角色前缀 → Monologue

**测试用例**（~15 个）：
- 空字符串/纯注释 → 空列表
- @scene 带标题/不带标题
- 基本对话/旁白/独白
- 对话带 #voice 标签
- 各种 @command（bg/show/hide/set/if/jump）
- 选项行（基本/带变量/带条件）
- 完整场景混合行 → 验证 token 序列和行号
- 缩进保留

---

### Sprint 2：DslParser P0 — 核心语法解析

**目标**：将 Token 流解析为 ScenarioData，覆盖 POC 所需的全部指令。

**新建文件**：
| 文件 | 说明 |
|------|------|
| `Core/ScriptParser/DslParser.cs` | `Parse(List<DslToken> tokens, string scenarioId) → ScenarioData` |
| `Core/ScriptParser/DslParseException.cs` | 解析错误，携带行号信息 |
| `Core/Commands/CharExprCommandHandler.cs` | @expr 命令处理器 → 发布 ChangeExpressionEvent |
| `Tests/EditMode/DslParserTests.cs` | 解析器测试 |
| `Tests/EditMode/CharExprCommandHandlerTests.cs` | @expr handler 测试 |

**修改文件**：
| 文件 | 变更 |
|------|------|
| `Core/Commands/SetCommandHandler.cs` | 增加 `op` 参数支持 (`+=`, `-=`) |
| `Tests/EditMode/SetCommandHandlerTests.cs` | 新增 += / -= 测试 |

**Parser 生成的 CommandData 参数对照**（必须与 Handler 期望的 key 完全匹配）：

| DSL 语法 | CommandData Type | Parameters |
|----------|-----------------|------------|
| `sakura「text」#voice:id` | `dialogue` | character, text, voice?, mode |
| `「text」` | `dialogue` | text, mode |
| `@bg asset fade 0.8` | `bg` | asset, transition?, duration? |
| `@show char expr pos` | `char_show` | character, expression?, position? |
| `@hide char` | `char_hide` | character |
| `@expr char expr` | `char_expr` | character, expression |
| `@choice "prompt"` + options | `choice` | prompt?, options: List\<Dict\> |
| `@set var = value` | `set` | var, value, op? |
| `@if expr` / `@else` / `@end` | `condition` | if, then_jump, else_jump |
| `@jump target` | `jump` | target |
| `@end`（场景末尾） | — | 标记场景结束 |

**@if/@else/@end 展平算法**：

Parser 维护 `ifStack: Stack<IfContext>`。IfContext 记录：
- `sceneId` + `lineNum`（用于合成场景命名）
- `thenCommands: List<CommandData>`
- `elseCommands: List<CommandData>`
- `currentBranch`（then/else）
- `commandsAfterEnd`（@end 之后的指令，放入 continuation 场景）

遇到 `@if`：压栈，后续指令收集到 thenCommands。
遇到 `@else`：切换到 elseCommands。
遇到 `@end`：出栈，生成合成场景，在原场景插入 condition 命令。

**选项解析**：`- "text" -> target {var += 5} ?if expr`
- 提取 `text`（引号内）
- 提取 `target`（-> 之后的词）
- 提取 `set`（{} 内，解析为 Dict）
- 提取 `condition`（?if 之后的表达式）
- 构建 Dict：`{ "text", "jump", "set"?, "condition"? }`

**测试用例**（~25 个）：
- 空 token → 空 ScenarioData
- 单场景/多场景
- 各类型对话（基本/带语音/旁白）
- @bg 全参数/默认参数
- @show 全参数/仅角色名
- @hide 单角色 / all
- @expr
- @choice 基本/带 prompt/带 set
- @set 赋值 / += / -=
- @if/@else/@end 展平（有 else / 无 else / 分支带 jump）
- @jump
- 多场景完整剧本（DSL.md 示例）
- 参数 key 验证（确保与 handler 预期一致）

---

### Sprint 3：DslScenarioLoader + 集成测试

**目标**：实现 IScenarioLoader，完成端到端验证。

**新建文件**：
| 文件 | 说明 |
|------|------|
| `Core/ScriptParser/DslScenarioLoader.cs` | 实现 IScenarioLoader，读取 .ntm 文件 |
| `Tests/EditMode/DslScenarioLoaderTests.cs` | Loader 测试 |
| `Tests/EditMode/DslIntegrationTests.cs` | DSL → Engine 端到端测试 |

**DslScenarioLoader 接口**（参照 YamlScenarioLoader）：
```csharp
public class DslScenarioLoader : IScenarioLoader
{
    public void RegisterPath(string scenarioId, string filePath);
    public Task<ScenarioData> LoadAsync(string scenarioId);
    public Task<ScenarioData> LoadFromStringAsync(string dslText, string scenarioId = "unnamed");
}
```

**集成测试**（与 ScenarioEngine 配合）：
- 加载 DSL → 引擎执行 → 验证事件发布序列
- 选项分支 → 验证 PendingJump
- @if/@else 条件 → 验证正确跳转
- 多场景自动推进

---

### Sprint 4：P1 — 完整演出能力

**目标**：BGM/SE/Fade/Wait/NVL/Overlay/Voice/Monologue。

**新建文件**：
| 文件 | 说明 |
|------|------|
| `Core/Commands/BgmCommandHandler.cs` | BGM 控制（play/stop） |
| `Core/Commands/SeCommandHandler.cs` | 音效控制 |
| `Core/Commands/FadeCommandHandler.cs` | 屏幕淡入淡出 |
| `Core/Commands/WaitCommandHandler.cs` | 等待（时间/点击） |
| 对应的 Tests 文件 | 每个 handler 的测试 |

**新增事件**（CoreEvents.cs）：
- `PlayBgmEvent(asset, fadeDuration)`
- `StopBgmEvent(fadeDuration)`
- `PlaySeEvent(asset, loop)`
- `StopSeEvent(asset)`
- `FadeEvent(direction, duration)` — direction: "in"/"out"

**Parser 扩展**：
| DSL | CommandData |
|-----|------------|
| `@bgm asset [fadein]` | `bgm` { asset, fade_duration? } |
| `@bgm off [fadeout]` | `bgm` { off: true, fade_duration? } |
| `@se asset [loop]` | `se` { asset, loop? } |
| `@se asset off` | `se` { asset, off: true } |
| `@fade out/in [dur]` | `fade` { direction, duration? } |
| `@wait 1.5 / click` | `wait` { duration? / mode: "click" } |
| `sakura（text）` | `dialogue` { character, text, mode: "monologue" } |
| `@nvl` / `@nvl off` | 无命令，切换 parser 的 currentMode |

---

### Sprint 5：P2 — 高级功能

**目标**：@anim/@move/@sd/@parallel/@call/@elif/条件选项/句内标签。

**新建文件**：
| 文件 | 说明 |
|------|------|
| `Core/Commands/CharAnimCommandHandler.cs` | 角色动画 |
| `Core/Commands/CharMoveCommandHandler.cs` | 角色移动 |
| `Core/Commands/SdCommandHandler.cs` | SD 插画 |
| `Core/Commands/ParallelCommandHandler.cs` | 并行执行（需注入 CommandRegistry） |
| `Core/Commands/CallCommandHandler.cs` | 调用子场景（需 ReturnStack） |

**修改文件**：
| 文件 | 变更 |
|------|------|
| `ScenarioContext.cs` | 增加 `ReturnStack` 支持 @call |
| `ScenarioEngine.cs` | RunAsync 循环检查 ReturnStack（当场景结束时弹出返回点） |
| `ChoiceCommandHandler.cs` | 过滤带 condition 的选项 |

---

## 关于 YAML 的处理

SimpleYamlParser 和 YamlScenarioLoader **保留不删除**。理由：
- 现有 106+ 测试用例依赖 YAML loader
- 作为备选格式保留兼容性（第三方工具可能输出 YAML）
- 不增加维护成本（已完成，无需改动）

---

## 验证方式

每个 Sprint：
1. 所有新增测试通过（TDD：先写测试 → 再实现）
2. 现有 106+ 测试不破坏
3. Sprint 3 的集成测试验证 DSL → Engine 完整链路
4. 最终用 DSL.md 中的完整示例（demo.ntm）做端到端验证

---

## 实施建议

先做 Sprint 1-3（一个 PR），覆盖 P0 全部功能。这是最小可用集，可以用 DSL 驱动 POC 演示。Sprint 4-5 后续按需推进。
