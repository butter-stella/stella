# Stella DSL 详细设计

> **设计理念：脚本即演出。** 编剧写完 DSL 脚本就能完成 90% 的演出效果，程序员只负责特殊定制。
> DSL 与 YAML 双向等价转换，DSL 是编剧的书写层，YAML 是框架的存储层/IR。

## 1. 设计原则

1. **编剧零门槛** — 不需要理解编程概念，看示例即可上手
2. **省略即合理** — 所有参数都有智能默认值，只写需要改变的部分
3. **高频操作最短语法** — 对话、表情切换、场景跳转这些最常用的操作，语法最简洁
4. **渐进式复杂度** — 简单场景一行搞定，复杂演出可以逐步加参数，不用换语法体系

## 2. 文件格式

- 扩展名：`.stla`
- 编码：UTF-8
- 注释：`//` 行注释
- 一个文件 = 一个剧本（scenario），可包含多个场景

## 3. 核心语法

### 3.1 章节与场景

```
@chapter prologue "序章 — 樱花树下"

@scene scene_001 "樱花树下的相遇"
```

**`@chapter`** —— 叙事单元，**作者层面**对剧本的分章。每个章节有一个 ID 和可选的显示名（给玩家看的标题）。章节是流程图功能（issue #97）的基本单位，**每个章节在流程图上对应一个节点**。

**`@scene`** —— 执行单元，**解析器层面**的脚本分段。`@scene` 后跟场景 ID，可选标题（仅用于编辑器显示和 Backlog）。

**两者的关系**：

- 每个 `@scene` 必须属于某个 `@chapter`
- 一个 chapter 拥有它声明之后、直到下一个 `@chapter` 之前的所有 `@scene`
- 第一个 `@scene` 之前必须有至少一个 `@chapter`，否则解析器报错（"强制规范化"）
- 每个 chapter 必须至少包含一个 `@scene`，否则解析器报错
- chapter id 必须显式提供且全文件唯一（不可省略，不可重复）
- `@chapter` 是顶层指令，**不能** 出现在 `@if` / `@else` / `@parallel` / `@combine` 块内部
- chapter 内部可以有任意多个 scene；它们都是该章节的"内部场景"，默认不出现在玩家流程图上（作者模式可下钻查看）

**完整示例**：

```
@chapter prologue "序章"
@scene scene_001 "樱花树下的相遇"
sakura「你好。」
@jump scene_branch_a

@scene scene_branch_a       // 内部场景，没有显示名
@expr sakura smile
sakura「真巧，我们又见面了。」
@jump chapter1_intro

@chapter chapter1 "第一章 入学第一天"
@scene chapter1_intro "教室"
...
```

这个例子里 `prologue` 章节有 2 个 scene（`scene_001` 和 `scene_branch_a`），但只有 `scene_001` 是章节入口；`scene_branch_a` 是内部 scene，玩家流程图不可见。

### 3.2 对话（最高频操作，语法最短）

```
// 基本对话 — 角色名 + 日式括号
sakura「你好，初次见面。」

// 旁白 — 无角色名
「窗外下起了雨。」

// 内心独白
sakura（这个人...好奇怪。）

// 附带语音
sakura「你好，初次见面。」 #voice:sakura_001

// 句内表情切换 — 编剧只需标注语义位置
sakura「我本来很开心的...[surprised]但是听到这个消息...[cry]呜呜...」

// 句内内联效果
sakura「那个人就是..{wait:500}{speed:0.3}你吗？」
```

**默认行为**：
- 打字机速度使用全局设置
- 自动等待玩家点击后推进
- 如有语音，自动播放

### 3.3 对话框模式切换

```
// 切换到全屏文本模式（独白、信件、旁白）
@nvl
「那是一个寒冷的冬天。」
「风呼啸着穿过空旷的街道。」
「没有人知道，一切即将改变。」
@nvl off

// 无框叠字模式
@overlay
「（我到底...在做什么呢）」
@overlay off
```

`@nvl` / `@overlay` 作为模式开关，之后的所有对话都使用该模式，直到 `off` 或切换。不需要每句都写 `mode`。

### 3.4 背景

```
// 基本切换 — 默认 fade 0.5s
@bg bg_school

// 指定转场
@bg bg_school fade 0.8
@bg bg_sunset dissolve 1.0
@bg bg_night wipe 0.6
```

**省略规则**：不写转场类型和时间 = `fade 0.5`。

### 3.5 立绘

```
// 显示 — 默认居中、默认表情、默认 fade 入场
@show sakura

// 指定表情和位置
@show sakura smile left
@show kaito default right

// 隐藏
@hide sakura
@hide all

// 切换表情（立绘已显示时）
@expr sakura surprised
@expr sakura cry
```

**省略规则**：
- 不写表情 = 使用角色配置的 `default`
- 不写位置 = `center`
- 不写过渡 = `fade 0.3`

### 3.6 立绘动画

```
// 移动
@move sakura right          // 移动到预设位置，默认 0.5s
@move sakura right 0.3      // 指定时间
@move sakura 0.7 0.5        // 自定义坐标 (x, y)

// 预设动画 — 一个词搞定
@anim sakura jump
@anim sakura shake
@anim sakura nod
@anim sakura bounce

// 带参数
@anim sakura shake strong    // 预设强度别名
@anim sakura shake 10 0.5    // 自定义 intensity duration
```

**强度别名**：`light` / `normal`（默认）/ `strong`，编剧不需要记数值。

### 3.7 CG 系统

CG 是统一的插画展示系统，通过 `mode` 区分不同展示方式：

```
// 全屏 CG — 替换背景，隐藏立绘，全屏展示
@cg sakura_confession
@cg sakura_confession fade 1.0    // 指定转场

// SD CG — 对话框旁弹出 Q 版小图
@cg sakura_chibi_angry sd
@cg sakura_chibi_laugh sd 1.5s    // 自动消失

// 动态 CG — 带动画/粒子效果
@cg sakura_rain animated

// 差分 CG — 切换同一张 CG 的不同状态
@cg sakura_confession:smile       // asset:variant 语法
@cg sakura_confession:cry

// 关闭 CG（恢复之前的背景/立绘状态）
@cg off
@cg off fade 0.5
```

**CG 模式**：

| 模式 | 关键字 | 行为 |
|------|--------|------|
| 全屏 | （默认） | 替换背景层，自动隐藏立绘，点击推进后恢复 |
| SD | `sd` | 小图弹出在对话框旁，不影响背景和立绘 |
| 动态 | `animated` | 全屏 CG + 附加动画效果（粒子、摇晃等） |

**省略规则**：不写模式 = 全屏 CG，不写转场 = `fade 0.5`，SD 模式不写位置 = `dialogue_right`，不写动画 = `pop`。

### 3.8 音频

```
// BGM — 默认淡入
@bgm bgm_spring
@bgm bgm_spring 1.5        // 指定淡入时间
@bgm off                    // 淡出停止
@bgm off 2.0               // 指定淡出时间

// 音效
@se se_door_open
@se se_rain loop             // 循环音效
@se se_rain off              // 停止指定音效

// 语音（通常不需要手写，跟在对话后面用 #voice: 即可）
@voice sakura_001
```

### 3.9 转场与特效

```
// 屏幕特效
@effect shake               // 屏幕震动
@effect flash                // 白屏闪光
@effect blur 0.5             // 模糊
@effect off                  // 清除所有特效

// 黑屏过渡（常用于时间跳跃）
@fade out 1.0
「第二天——」
@fade in 1.0
```

### 3.10 分支选择

```
// 基本选择
@choice
  - "一起走吧" -> scene_go
  - "今天有点忙..." -> scene_busy

// 带变量修改
@choice
  - "一起走吧" -> scene_go {sakura_affection += 5}
  - "今天有点忙..." -> scene_busy

// 带条件显示（好感不够时隐藏选项）
@choice
  - "一起走吧" -> scene_go {sakura_affection += 5} ?if sakura_affection >= 5
  - "今天有点忙..." -> scene_busy

// 带提示文本
@choice "你该怎么回应？"
  - "一起走吧" -> scene_go
  - "今天有点忙..." -> scene_busy
```

### 3.11 变量与条件

```
// 赋值
@set talked_to_sakura = true
@set sakura_affection += 5

// 条件跳转
@if sakura_affection >= 10
  @jump good_ending
@elif sakura_affection >= 5
  @jump normal_ending
@else
  @jump bad_ending

// 条件段落（控制一段内容是否显示）
@if has_key
  sakura「你有钥匙！太好了。」
@else
  sakura「没有钥匙的话...怎么办呢。」
@end
```

### 3.12 流程控制

```
// 跳转场景
@jump scene_002

// 调用子场景（执行完后返回）
@call flashback_001

// 结束当前剧本
@end
```

### 3.13 并行指令

```
// 同时执行多个操作
@parallel
  @bg bg_sunset dissolve 1.0
  @move sakura center 0.5
  @anim kaito shake
@end
```

编剧只有在需要"多件事同时发生"时才用 `@parallel`，日常演出不需要。

### 3.14 合并对话（@combine）

一句台词在演出上是一整句，但声优录音被拆成了多段，每段之间还要切表情：

```
@combine
@expr sakura sad
sakura「我本来很开心的...」 #voice:sakura_013
@expr sakura surprised
sakura「但是听说下周要期中考...」 #voice:sakura_018
@expr sakura sad
sakura「我数学肯定完蛋了。」 #voice:sakura_019
@end
```

**语义：**

- 块内所有 dialogue 行合并为**一句对话**，玩家视角上打字机从头连续打到尾
- 块内 `@expr` 绑定到紧随其后的 segment，在该段语音开始播放时触发
- 语音按顺序排队：第 1 段播完 → 第 2 段立即接上 + 切立绘/头像 → ...
- 左键点击：整句结束（文本全显、立绘定格在最后一段表情）
- 快进模式：整段作为一句跳过
- Backlog：记为一条

**限制：**

- 块内只允许 `@expr` 和 dialogue 行（角色名必须一致，或全为旁白）
- 其它指令（`@bg`、`@anim` 等）不允许出现在块内
- 不支持 NVL / overlay 模式下的特殊行为（按普通合并处理）

### 3.15 等待

```
@wait 1.5                   // 等待 1.5 秒
@wait click                  // 等待玩家点击
```

大部分情况不需要手写 `@wait` — 对话自动等待点击，动画自动等待完成。

## 4. 完整示例

```
// demo.stla
@scene start "序章"

// 背景和角色登场
@bg bg_school_gate
@show sakura smile left
@show kaito default right

// 日常对话
sakura「今天天气真好呢。」 #voice:sakura_001
kaito「是啊。」

// 演出：sakura 开心地跳了一下
@anim sakura jump
sakura「对了！放学后一起去新开的咖啡店吧！」 #voice:sakura_002

// 选择分支
@choice
  - "好啊，走吧" -> scene_cafe {sakura_affection += 5}
  - "今天有点忙..." -> scene_reject

//========================================
@scene scene_cafe "咖啡店"

@bg bg_cafe fade 1.0
@show sakura smile center

sakura「你看你看，这个蛋糕好可爱！」 #voice:sakura_010
@cg sakura_chibi_excited sd 2s
@anim sakura bounce
sakura「我要点这个！」 #voice:sakura_011

// 回忆闪回
@fade out 0.5
@overlay
「（她的笑容...让我想起了小时候的事。）」
@overlay off
@fade in 0.5

// 表情变化的长台词
sakura「我一直很喜欢这种店呢。[default]不过...[sad]自从那件事之后就没怎么来过了。」 #voice:sakura_012

@if sakura_affection >= 10
  @jump good_ending
@else
  @jump normal_ending

//========================================
@scene scene_reject "拒绝"

@expr sakura sad
sakura「这样啊...那没关系。」 #voice:sakura_020
@anim sakura nod

@jump normal_ending

//========================================
@scene good_ending "Good End"

@nvl
「那天之后，我们的关系发生了变化。」
「不知不觉间，放学后一起回家成了习惯。」
「那个春天的相遇，改变了一切。」
@nvl off

// END
@bg bg_sakura dissolve 2.0
@hide all
「—— Good End ——」
@end

//========================================
@scene normal_ending "Normal End"

@nvl
「日子一天天过去，一切都没有改变。」
「但是那个春天的记忆，我一直没有忘记。」
@nvl off

「—— Normal End ——」
@end
```

## 5. 语法速查表

| 操作 | 语法 | 最短形式 |
|------|------|---------|
| 对话 | `角色「台词」 #voice:id` | `角色「台词」` |
| 旁白 | `「文本」` | `「文本」` |
| 独白 | `角色（文本）` | `角色（文本）` |
| 背景 | `@bg asset transition duration` | `@bg asset` |
| 显示立绘 | `@show char expr pos` | `@show char` |
| 隐藏立绘 | `@hide char` | `@hide all` |
| 表情 | `@expr char expression` | — |
| 句内表情 | `[expression]` | — |
| 移动 | `@move char pos duration` | `@move char pos` |
| 动画 | `@anim char type intensity` | `@anim char type` |
| CG | `@cg asset [mode] [transition] [duration]` | `@cg asset` |
| BGM | `@bgm asset fadein` | `@bgm asset` |
| 音效 | `@se asset` | `@se asset` |
| 全屏对话 | `@nvl ... @nvl off` | — |
| 无框叠字 | `@overlay ... @overlay off` | — |
| 特效 | `@effect type` | — |
| 黑屏 | `@fade out/in duration` | `@fade out/in` |
| 选择 | `@choice` + 选项列表 | — |
| 变量 | `@set var = value` | — |
| 条件 | `@if ... @elif ... @else ... @end` | — |
| 跳转 | `@jump scene_id` | — |
| 并行 | `@parallel ... @end` | — |
| 合并 | `@combine ... @end` | 多段语音+表情合并为一句对话 |
| 等待 | `@wait duration/click` | — |
| 场景 | `@scene id "title"` | `@scene id` |

## 6. 智能默认值总表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 转场类型 | `fade` | 背景/立绘切换 |
| 转场时长 | `0.5s`（背景）/ `0.3s`（立绘） | 可在项目配置中全局修改 |
| 立绘位置 | `center` | 第一个角色默认居中 |
| 立绘表情 | `default` | 取角色配置中的 default |
| 动画强度 | `normal` | light / normal / strong |
| 动画时长 | 预设自带 | jump=0.4s, shake=0.3s, nod=0.3s, bounce=0.35s |
| CG 模式 | 全屏 | 不写 mode 时为全屏 CG |
| CG 转场 | `fade 0.5` | 全屏 CG 默认转场 |
| SD CG 位置 | `dialogue_right` | 对话框右侧 |
| SD CG 动画 | `pop` | 弹出效果 |
| BGM 淡入 | `1.0s` | — |
| BGM 淡出 | `1.0s` | — |
| 对话推进 | 等待点击 | 有语音时可配置等语音播完 |

## 7. 解析器架构

DSL 是唯一的脚本格式，引擎直接解析 `.stla` 为内部数据结构（ScenarioData）。

```
ScriptParser/
├── DslLexer.cs                -- 词法分析：将 .stla 文本分割为 Token 流
├── DslParser.cs               -- 语法分析：Token 流 → ScenarioData（填充默认值、展开简写）
├── DslScenarioLoader.cs       -- IScenarioLoader 实现：读取 .stla 文件
├── DslParseException.cs       -- 解析错误（携带行号信息）
├── DslValidator.cs            -- 静态检查：未定义的角色/场景引用、死路检测
└── DslToken.cs                -- Token 类型定义
```

### 解析示例

DSL（3 行）：
```
@show sakura
sakura「你好。」
@anim sakura jump
```

解析器自动填充默认值，生成等价的 CommandData 序列（12 个参数）：
```
CommandData("char_show",  { character: "sakura", expression: "default", position: "center" })
CommandData("dialogue",   { character: "sakura", text: "你好。", mode: "adv" })
CommandData("char_anim",  { character: "sakura", anim: "jump", intensity: "normal" })
```

### 静态检查

`DslValidator` 在解析时自动检查：
- 引用了未定义的角色 → 警告
- `@jump` 指向不存在的场景 → 错误
- 场景无出口（无 jump/choice/end）→ 死路警告
- 变量在 `@if` 中使用但从未 `@set` → 警告
