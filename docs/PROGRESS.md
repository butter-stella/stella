# Natsume — 开发进度

> 最后更新：2026-03-27

## 总览

Core 层（纯 C#）已全部完成，可独立单元测试。Presentation 层（依赖 Unity）尚未开始。

| 层 | 状态 | 说明 |
|---|---|---|
| **Core 层** | ✅ 完成 | 纯 C#，17 个测试文件，无 Unity 依赖 |
| **Presentation 层** | ⬜ 未开始 | 需要 Unity 环境 |
| **Editor 层** | ⬜ 未开始 | 需要 Unity 环境 |
| **Tool 层** | ⬜ 未开始 | DSL 转译器可无 Unity 开发 |

---

## 已完成的 PR

| PR | 内容 | 测试数 |
|---|---|---|
| [#1](https://github.com/MadCcc/Natsume/pull/1) | 架构设计文档整理 | — |
| [#2](https://github.com/MadCcc/Natsume/pull/2) | Live2D 支持规划 | — |
| [#3](https://github.com/MadCcc/Natsume/pull/3) | Sprint 1 — 核心骨架、接口契约（EventBus、ServiceLocator、8 个核心接口） | 16 |
| [#4](https://github.com/MadCcc/Natsume/pull/4) | Sprint 2 — ScenarioEngine 主循环、VariableStore、ExpressionEvaluator、CommandRegistry、jump/condition/set handler | 37 |
| [#5](https://github.com/MadCcc/Natsume/pull/5) | Sprint 3 — dialogue/bg/char_show/char_hide/choice handler、IScenarioLoader、表现层事件 | 28 |
| [#6](https://github.com/MadCcc/Natsume/pull/6) | Sprint 4 — 对话等待机制（WaitController + AdvanceEvent）、YAML 解析器 + ScenarioLoader | 25 |

**累计测试：106+**

---

## Core 层模块清单

### 基础设施

| 模块 | 文件 | 说明 |
|---|---|---|
| EventBus | `Core/EventBus/EventBus.cs` | 静态事件总线，异常隔离，可替换 Logger |
| ServiceLocator | `Core/ServiceLocator/ServiceLocator.cs` | 全局服务注册，替代单例 |
| 事件定义 | `Core/Events/CoreEvents.cs` | 17 个 readonly struct 事件 |
| 核心接口 | `Core/Interfaces/` | ICommandHandler、IInputProvider、IDialoguePresenter、IChoicePresenter、ICharacterRenderer、ICharacterAnimation、IResourceProvider、ISnapshotProvider |

### 数据模型

| 模块 | 文件 | 说明 |
|---|---|---|
| ScenarioData | `Core/Data/ScenarioData.cs` | 剧本顶层结构（Id, Title, Scenes） |
| SceneData | `Core/Data/SceneData.cs` | 场景（Id, Commands） |
| CommandData | `Core/Data/CommandData.cs` | 指令数据，类型安全访问器 |
| ChoiceData | `Core/Data/ChoiceData.cs` | 选项数据（ChoiceOption: Id, Label, Jump, Set, Condition） |
| VariableScope | `Core/Data/VariableScope.cs` | Global / Scenario / Temp |
| InputAction | `Core/Data/InputAction.cs` | Advance, Cancel, ShowMenu 等语义输入 |

### 剧情引擎

| 模块 | 文件 | 说明 |
|---|---|---|
| ScenarioEngine | `Core/ScenarioEngine/ScenarioEngine.cs` | 主循环：加载 → 推进 → 跳转 → 结束，自动推进到下一场景 |
| ScenarioContext | `Core/ScenarioEngine/ScenarioContext.cs` | 运行时上下文（当前场景、指令指针、PendingJump、IsFinished） |
| WaitController | `Core/ScenarioEngine/WaitController.cs` | TCS 等待玩家推进（AdvanceEvent） |

### 命令处理器（8 个）

| Handler | CommandType | 行为 |
|---|---|---|
| DialogueCommandHandler | `dialogue` | 发布 ShowDialogueEvent → 等待 AdvanceEvent |
| BgCommandHandler | `bg` | 发布 ShowBgEvent（含 asset/transition/duration） |
| CharShowCommandHandler | `char_show` | 发布 CharShowEvent（含 character/expression/position） |
| CharHideCommandHandler | `char_hide` | 发布 CharHideEvent |
| ChoiceCommandHandler | `choice` | 发布 ShowChoiceEvent → 等待 ChoiceSelectedEvent → 设置 PendingJump + 变量 |
| JumpCommandHandler | `jump` | 设置 context.PendingJump |
| ConditionCommandHandler | `condition` | 求值表达式 → 跳转 then_jump 或 else_jump |
| SetCommandHandler | `set` | 写入 VariableStore |

### 变量系统

| 模块 | 文件 | 说明 |
|---|---|---|
| VariableStore | `Core/VariableSystem/VariableStore.cs` | 三作用域（Global/Scenario/Temp），优先级 Temp → Scenario → Global，ISnapshotProvider |
| ExpressionEvaluator | `Core/VariableSystem/ExpressionEvaluator.cs` | 比较（>=, >, <, <=, ==, !=）、逻辑（&&, \|\|, !）、bool/string 字面量 |

### 脚本解析

| 模块 | 文件 | 说明 |
|---|---|---|
| IScenarioLoader | `Core/ScriptParser/IScenarioLoader.cs` | 加载接口，返回 null 表示未找到 |
| InMemoryScenarioLoader | `Core/ScriptParser/InMemoryScenarioLoader.cs` | 内存加载器，用于测试 |
| SimpleYamlParser | `Core/ScriptParser/SimpleYamlParser.cs` | 内置轻量 YAML 解析器（map/list/scalar，无外部依赖） |
| YamlScenarioLoader | `Core/ScriptParser/YamlScenarioLoader.cs` | YAML → ScenarioData，支持文件和字符串加载 |

### 事件清单

```
AdvanceEvent                — 玩家推进对话
ShowDialogueEvent           — 显示对话（character, text, voice, mode）
HideDialogueEvent           — 隐藏对话框
ShowBgEvent                 — 显示背景（asset, transition, duration）
CharShowEvent               — 显示立绘（character, expression, position, transition, duration）
CharHideEvent               — 隐藏立绘
ShowChoiceEvent             — 显示选项（prompt, options: IReadOnlyList）
ChoiceSelectedEvent         — 玩家选择了选项
ScenarioStartedEvent        — 剧本开始
ScenarioEndedEvent          — 剧本结束
SceneChangedEvent           — 场景切换
CommandExecutedEvent        — 指令执行完毕
VariableChangedEvent        — 变量值变更
ChangeExpressionEvent       — 切换表情
VoiceStartedEvent           — 语音开始
VoiceProgressEvent          — 语音播放进度
VoiceFinishedEvent          — 语音结束
SettingsChangedEvent        — 设置变更
```

---

## YAML 剧本格式

```yaml
id: chapter_01
title: 第一章
scenes:
  - id: start
    commands:
      - type: bg
        params:
          asset: bg_school
          transition: fade
          duration: 0.8
      - type: char_show
        params:
          character: sakura
          expression: smile
          position: center
      - type: dialogue
        params:
          character: sakura
          text: 初次见面，我叫樱。
          voice: sakura_001
      - type: choice
        params:
          prompt: 你该怎么回应？
          options:
            - text: 你好
              jump: scene_friendly
              set:
                affection: '+5'
            - text: ......
              jump: scene_silent
      - type: set
        params:
          var: talked_to_sakura
          value: true
      - type: jump
        params:
          target: scene_next
      - type: condition
        params:
          if: affection >= 10
          then_jump: good_ending
          else_jump: normal_ending
```

---

## 测试文件清单（17 个）

```
Tests/EditMode/
├── EventBusTests.cs                    — EventBus 发布/订阅/异常隔离
├── ServiceLocatorTests.cs              — ServiceLocator 注册/获取
├── CommandDataTests.cs                 — CommandData 类型访问器
├── CommandRegistryTests.cs             — CommandRegistry 注册/查找
├── ScenarioEngineTests.cs              — 引擎主循环/跳转/条件/自动推进
├── VariableStoreTests.cs               — 三作用域/快照/恢复
├── ExpressionEvaluatorTests.cs         — 比较/逻辑/bool/string 求值
├── DialogueCommandHandlerTests.cs      — dialogue handler 事件发布
├── DialogueWaitTests.cs                — 对话等待/推进机制
├── BgCommandHandlerTests.cs            — bg handler + null 防护
├── CharShowCommandHandlerTests.cs      — char_show handler + null 防护
├── CharHideCommandHandlerTests.cs      — char_hide handler + null 防护
├── ChoiceCommandHandlerTests.cs        — choice handler + TCS 等待/跳转/变量
├── WaitControllerTests.cs              — WaitController TCS 机制
├── ScenarioLoaderTests.cs              — InMemoryScenarioLoader
├── SimpleYamlParserTests.cs            — YAML 解析器（冒号/tab/嵌套）
└── YamlScenarioLoaderTests.cs          — YAML → ScenarioData 端到端
```
