# Stella DSL 详细设计

> **设计理念：脚本即演出。** 编剧写完 DSL 脚本就能完成 90% 的演出效果，程序员只负责特殊定制。
> `.stla` 是当前唯一的剧本源格式；解析器直接生成框架运行时数据模型。

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
@stage sakura update asset=character:sakura/smile transition=fade duration=0.15
sakura「真巧，我们又见面了。」
@jump chapter1_intro

@chapter chapter1 "第一章 入学第一天"
@scene chapter1_intro "教室"
...
```

这个例子里 `prologue` 章节有 2 个 scene（`scene_001` 和 `scene_branch_a`），但只有 `scene_001` 是章节入口；`scene_branch_a` 是内部 scene，玩家流程图不可见。

#### 当前章节标题指示器

`@chapter_indicator` 显式控制当前章节标题 UI 的 authored 可见目标：

```stla
@chapter prologue "chapter.prologue"
@scene opening
@chapter_indicator show
@chapter_indicator hide transition=fade
@chapter_indicator show transition=fade duration=0.6
@chapter_indicator hide transition=none
```

精确语法为：

```text
@chapter_indicator show|hide [transition=cut|none|fade] [duration=<seconds>]
```

- 默认转场是 `cut`、时长是 `0.0`；`fade` 省略 `duration` 时默认 `0.25` 秒。
- `none` 只是 `cut` 的 authoring alias，编译后同样保存为 `transition="cut", duration=0.0`，因此两种写法具有相同的内容 identity。
- `duration` 必须是有限、非负的浮点秒数；`cut` / `none` 只接受 `0`。未知、重复、缺少等号或额外参数会让整条指令原子失败，并以 `.stla` 的 `source_path:line` 报错。
- 指令必须写在当前 chapter 的有效 `@scene` 中；可以位于实际执行的 `@if` / `@else` 分支，但不能写在 chapter 与首个 scene 之间，也不能放入 `@parallel` 或 `@combine`。standalone 写法是 blocking JOIN：parser 把它 lowering 为一个单 child `presentation_batch`，和高级组合共用唯一的 typed Director 路径。所有本次验证通过的 Presenter 都完成后剧本才继续；没有 Presenter 的 headless runner 会同步成功。不要用 wall-clock 等待或 `@parallel` 模拟跨演出 composition/join。

可见性不会在 `@jump`、`@call`、顺序换 scene 或换 chapter 时隐式改变。运行时章节 ID/标题来自实际执行 cursor；标题交给 `TranslationServer` 解析。裸 `@chapter id` 以 ID 作为标题，显式空标题不会渲染 UI，但 authored 可见目标仍按命令与存档保留。

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

// 为这一条语音选择有序 DSP preset；没有 #voice_dsp 时保持普通干声
sakura「电话里的声音。」 #voice:sakura_001 #voice_dsp:telephone

// 句内头像表情提示
sakura「我本来很开心的...[expr:surprised]但是听到这个消息...[expr:cry]呜呜...」

// 句内内联效果
sakura「那个人就是..{wait:500}{speed:30}你吗？」
```

**默认行为**：
- 打字机速度使用全局 `character_interval` 设置；固定标点停顿使用
  `punctuation_pause` 设置（均为非负整数毫秒，默认分别为 50 / 200，`0`
  表示不增加对应延迟）
- 自动等待玩家点击后推进
- 如有语音，自动播放

方括号标记（如 `[expr:surprised]`）只更新对话框头像，不会修改舞台图片。人物立绘、身体和脸部差分都由 `@stage` 显式管理；需要让舞台表情与某段语音同步时，在 `@combine` 中把对应 `@stage ... update` 写在该段对话之前。头像标签必须使用显式的 `expr:` 前缀；没有该前缀的未知标签仍按普通文字显示。若项目为正文 `RichTextLabel` 开启 BBCode，Godot 内置标签和已注册的 `RichTextEffect` 仍按引擎语义渲染，但不会被当作 Stella 头像标记；字体与布局由 Dialogue Profile 或 Theme 配置。

`{wait:...}` 与 `{speed:...}` 都使用毫秒：`{wait:500}` 暂停 500ms，
`{speed:30}` 把后续每字间隔设为 30ms。未知标签、非数字或负数会产生
warning，并按普通文本显示。

`#voice_dsp:<preset>` 只能与同一行的 `#voice:<asset>` 一起使用。preset 是
相对于 `[paths] voice_dsp` 的 Stella 逻辑资源 ID，例如 `telephone` 会解析为
`res://audio/voice_dsp/telephone.tres`（或 `.res`）。空值、重复 metadata、未知
metadata、绝对路径、`res://` / `user://` 和包含 `.` / `..` 的路径都会在带
source line 的 parser 边界 fail-close。`@combine` 中每个对话 segment 独立选择
preset；Backlog 重播保留各 segment 的选择和顺序，普通语音不会继承上一条链。

DSP preset 是 `VoiceDspChainDefinition` Resource，`effects` 按数组顺序执行，
`tail_seconds` 声明最后一个有声 sample 后仍需保留物理效果链的最长尾音。当前
通用 primitive 为：

- `VoiceDspBandPassEffect(center_hz, bandwidth_hz, order)`：lower edge
  `center-bandwidth/2` 的 HighPass 后接 upper edge `center+bandwidth/2` 的
  LowPass；order `1..4` 映射 Godot 的 `6/12/18/24 dB/oct`。这里定义的是
  Stella/Godot 的确定性频响，并不宣称与任意外部 Butterworth 实现逐 sample
  等价；不采用 `AudioEffectBandPassFilter`，因为其 resonance 没有文档化的
  bandwidth 映射。
- `VoiceDspDelayEffect(time_ms, feedback, mix)`：`mix` 是线性的湿声 tap gain，
  干声始终为 `1.0`，不是 dry/wet crossfade；`feedback` 也是线性 gain。零值
  关闭对应支路，非零值必须至少为 `0.001`，因为 Godot 的可表达 floor 是
  `-60 dB`。

preset 先完成完整 detached validation，再安装到尚未连接 live player 的 staging
bus；资源缺失、类型错误、非法频率/阶数/gain 或无法安装完整 chain 时拒绝该
voice request，并按 bus identity 释放 staging，不会中断当前有效语音后再降级成
干声。player 固定 unity gain，private bus 是 master/voice/per-character/enabled 的
唯一 post-effect gain authority，因此设置同时约束 active source 和已缓冲 tail。
hide、clear、load/rollback、return-to-title、替换语音和 Presenter 退出都会清理
owned private bus effects 与 tail Timer；不属于对话 UI 的旧 dry programmatic voice
仍保持原物理生命周期，但 processed programmatic voice 会在硬边界整体退休，不会
让同一 token 中途失去所选 chain。

每个可见字符的基础延迟来自该句开始显示时取得的
`character_interval`；字符属于固定集合 `，。！？；：、,.!?;:…—` 时，再加上
同一时刻取得的 `punctuation_pause`。每个标点 codepoint 都会独立累计，因此连续
标点会逐个停顿。设置在当前句打字途中修改或重置，只影响下一条真正开始显示的
对话；尚在队列中的对话也到开始显示时才取值。`{speed:...}` 只修改当前句后续
字符的基础间隔，不取消标点停顿；`{wait:...}` 是字符前的独立停顿，所以三者的
时间相加。点击补全、Skip、隐藏或替换对话会通过同一 generation 边界退休当前句
尚未完成的计时；Auto 则只在同一 active generation 自然完成后继续推进，两条路径
都不会让旧计时影响下一句。

### 3.3 对话框模式切换

```
// 在 STLA 顶部声明一套可复用的 NVL 表现 Profile。
// 同名声明会按书写顺序合并，便于按职责拆行。
@dialogue_profile novel panel_anchors=0,0,1,1 panel_offsets=0,0,0,0
@dialogue_profile novel text_anchors=0.15,0.1,0.85,0.7 text_margins=20,20,20,20
@dialogue_profile novel horizontal_alignment=left vertical_alignment=top line_spacing=8
@dialogue_profile novel background_visible=true background_modulate=#ffffff00
@dialogue_profile novel show=quick_menu hide=adv_chrome
@dialogue_profile novel entry_prefix="・" entry_separator=""
@dialogue_profile novel advance_indicator_texture="res://ui/dialogue/wait.svg"
@dialogue_profile novel advance_indicator_offset=8,-2 advance_indicator_animation=bob

// ADV 也可以选择命名 Profile；未写 @adv 时使用场景原始 ADV。
@dialogue_profile message panel_anchors=0,0.72,1,1
@adv profile=message

// 选择命名 Profile，切换到 NVL 模式。
@nvl profile=novel
「那是一个寒冷的冬天。」
「风呼啸着穿过空旷的街道。」
「没有人知道，一切即将改变。」
@nvl off

// 无框叠字模式
@overlay
「（我到底...在做什么呢）」
@overlay off
```

`@adv` / `@nvl` / `@overlay` 作为模式开关，之后的所有对话都使用该模式，直到 `off` 或切换。不需要每句都写 `mode`。不带 `profile` 时使用内置兼容表现；`profile=<name>` 从当前 STLA 文件的 `@dialogue_profile` 声明中选择一套表现。Profile 声明会在编译时进入当前 scenario 的 registry，因此可以写在引用之后，但建议统一放在文件顶部。若先用 `@adv profile=message` 配置 ADV，`@nvl off` / `@overlay off` 会沿实际运行路径恢复 `message`；否则恢复场景编排的 ADV 基线。

模式开关按实际运行路径生效：经过 `@nvl off` 或切到其他模式后，再通过顺序执行、`@jump`、`@call` 或条件分支进入 `@nvl`，都会开始新的 NVL 页面；没有离开 NVL 时重复写 `@nvl` 则继续当前页面。不同条件分支可以选择不同 mode/Profile；汇合后的对话会继承玩家真正走过的分支。只有在作者希望所有路径从汇合点开始使用同一布局时，才需要在汇合后显式重新选择。

同一个 Profile 可以拆成多行声明，后写属性覆盖同名旧属性。每个属性都独立生效；未写的属性保留场景编排值，不会因为只修改行距而顺带重置对齐、区域或滚动策略：

| 属性 | 值 | 作用 |
|------|----|------|
| `panel_anchors` / `panel_offsets` | `left,top,right,bottom` | 对话面板锚点（0..1）与像素偏移 |
| `panel_modulate` | `#RRGGBBAA` | 整个对话面板的颜色调制 |
| `text_anchors` / `text_offsets` | `left,top,right,bottom` | 文字区域锚点与像素偏移 |
| `text_margins` | `left,top,right,bottom` | 文字区域四边内缩，必须非负 |
| `horizontal_alignment` | `left/center/right/fill` | 水平对齐 |
| `vertical_alignment` | `top/center/bottom/fill` | 垂直对齐 |
| `line_spacing` | 整数 | 行距像素值 |
| `fit_content` | `true/false` | 文字控件是否跟随内容高度 |
| `scroll_active` / `scroll_following` | `true/false` | 是否允许滚动、是否跟随新增文字 |
| `autowrap_mode` | `off/arbitrary/word/word_smart` | 自动换行策略 |
| `clip_contents` | `true/false` | 是否裁剪超出文字区域的内容 |
| `background_visible` | `true/false` | 对话背景是否可见 |
| `background_modulate` | `#RRGGBBAA` | 对话背景颜色；alpha `00` 为透明 |
| `show` / `hide` | 逗号分隔的分组名 | 显示或隐藏附属 UI 分组 |
| `entry_prefix` | 引号纯文本字符串 | 每条 NVL 记录的前缀；默认 `""` |
| `entry_separator` | 引号纯文本字符串 | 相邻 NVL 记录之间的分隔符；默认 `"\n"` |
| `advance_indicator_texture` | 引号 `res://` / `uid://` 路径 | 文本完成后显示的 `Texture2D` 等待标记 |
| `advance_indicator_scene` | 引号 `res://` / `uid://` 路径 | 文本完成后实例化的 `PackedScene` 等待标记 |
| `advance_indicator_offset` | `x,y` | 标记相对最终文字端点的像素偏移；默认 `0,0` |
| `advance_indicator_animation` | `none/pulse/bob` | 标记的内置循环动画；默认 `none` |

`entry_prefix` 和 `entry_separator` 只影响 NVL 的屏幕累积文本。每条记录按“前缀 → 角色名（若有）→ 正文”的顺序显示，分隔符只插入相邻记录之间；例如 `entry_prefix="・" entry_separator=""` 会把两句旁白显示为 `・第一句。・第二句。`。显式的空字符串表示不插入内容，与省略属性时采用兼容默认值不同。`@combine` 块在 NVL 中仍是一条记录，因此只添加一次前缀。Backlog 不混入这些屏幕装饰；它保存正文的玩家可见纯文本，剥离 BBCode 格式、expression marker 与 typewriter effect marker，并把段落和列表转换成普通文本布局。

这两个属性支持带引号的纯文本字符串及常用转义：`\\`、`\"`、`\n`、`\r`、`\t`。例如 `entry_separator="\n\n"` 会在记录间留出一个空行。这里不支持 BBCode 标签，方括号会产生解析诊断；样式仍应通过 Profile 的文字属性或场景 theme 配置。未配置时前缀为空、记录之间换行。

Advance indicator 是可选的、按 Profile 独立配置的表现节点。`advance_indicator_texture` 和 `advance_indicator_scene` 二选一：前者适合普通箭头、菱形等图片，后者适合项目自带粒子或状态脚本的复杂标记；同时配置会让整个 Profile 声明原子失败，不会采用隐式优先级或部分视觉降级。场景根节点必须是 `CanvasItem`；`Control` 根必须使用左上角锚点（四个 anchor 都为 `0`），并用 offset 或 minimum size 明确尺寸，`Node2D` 根则会被归一化为非 top-level。根节点原点会放在最终渲染行的文字端点；若实现 `set_advance_ready(ready: bool)`，Presenter 会在显示/隐藏时同步通知状态。`advance_indicator_offset` 中正 x 向右、正 y 向下，`pulse` 改变透明度，`bob` 做轻微上下浮动；自定义场景也可以选择 `none` 并自行表现。Indicator 只通过 `.stla` Profile 创作；高级 `DialoguePresentationProfile` Resource 继续兼容既有布局字段，但不会形成第二套 indicator schema。

内置端点定位复用一个透明、隔离的 `RichTextLabel` 排版镜像，并从 Godot 实际绘制的 glyph transform 读取逻辑末端。因此控件级/BBCode 段落对齐、`[indent]`、`[ul]` / `[ol]` 列表、混合 LTR/RTL 与滚动条占宽都使用与正文相同的引擎排版结果，不要求项目提供自定义 Presenter；镜像不会改写正文标签的 text、可见字符、选择或滚动状态。

标记只在当前对话完整显示、可以推进时出现。新记录开始打字、推进、快进、`hide_dialogue`、对话式 overlay 结束、场景或剧本生命周期切换时会立即隐藏；右键临时隐藏以及打开 Backlog/设置等系统 overlay 会保留同一句的 ready 状态。ADV、overlay 和累积 NVL 都按 `RichTextLabel` 实际换行后的最新端点重新定位，最后一个段落的 left/center/right/fill 对齐也会计入；若最终行被滚动或裁剪到可见区域外，标记保持隐藏，并在滚动到端点后重新出现。标记是独立节点，不会追加到 `RichTextLabel.text`、正文、Backlog 或存档数据。完全不配置 source 时不会创建节点，旧项目视觉保持不变。

内置场景已提供 `quick_menu` 分组，并将默认文字布局根作为可定位区域，所以常见 NVL/overlay 版式只需要写 STLA。只有项目新增了特殊 frame、logo 或其他自定义 UI 时，才需要在 Godot 场景里给这些节点分组，例如 `adv_chrome`。

无效数字、越界/倒置 anchors、负 margin、非法枚举、未知属性、不完整的引号字符串、非法字符串转义、entry format 中的 BBCode 方括号、不存在/类型不符的 indicator 资源、同时配置 texture 与 scene，或不存在的 Profile，都会生成包含 STLA 行号的解析诊断，并让对应 Profile 声明整体失效。无法实例化、根节点不是 `CanvasItem`，或 `Control` 根使用非左上角锚点的 indicator scene，会在运行时给出一次性警告并仅禁用标记。该 warning 会列出准确的 Profile 名、`.stla` 来源路径、当前 indicator 字段及资源路径、该字段的声明行和可执行修复动作；多个 Profile 即使使用同一模式和同一错误场景也会分别报告。编译器把 Profile 与 provenance 分开保存在当前 `ScenarioData`，运行时 sidecar 只携带 mode、Profile 名和 ADV 恢复动作；存档保存当前/ADV 的 Profile 名与声明式状态，并为当前 NVL 页的每条 authored entry 单独保存当时的 Profile 名。恢复时从当前 scenario registry 逐条解析，因此一页中途换 Profile、分支、存读档、Backlog 回退、`@jump` 与 `@call` 都遵循实际执行路径；resolved Profile、provenance 和渲染字符串不进入存档。`off` 会恢复该路径配置的 ADV 场景基线。

### 3.4 背景

```
// 基本切换 — 默认 fade 0.5s
@bg bg_school

// 指定转场
@bg bg_school fade 0.8
@bg bg_sunset dissolve 1.0
@bg bg_night wipe 0.6

// 滑动进入（带方向，方向名即 "旧图离开的方向"）
@bg bg_cafe slide_left 0.6      // 旧图向左滑出，新图从右进入
@bg bg_hallway slide_right 0.6
@bg bg_outside slide_up 0.6
@bg bg_school_gate slide_down 0.6
```

**可用转场类型**：`fade`、`dissolve`、`wipe`、`slide_left`、`slide_right`、`slide_up`、`slide_down`。

**省略规则**：不写转场类型和时间 = `fade 0.5`。

### 3.5 动态命名舞台层（@stage）

`@stage` 是人物立绘、身体/脸部差分、事件图、SD 与前景图片的统一舞台接口。它通过稳定 ID 管理任意数量的动态层，不预建位置槽，也不限制同时显示的人物数量。ID 区分大小写且必须非空；`clear` 是无 ID 的全舞台动作。

### 3.5A Dialogue visibility

```stla
@dialogue_visibility hide
@dialogue_visibility show
```

这两条最短写法控制整个对话 surface；普通剧本不需要 `@presentation_batch`。
需要动画或单独控制 quick menu 时，再写可选参数：

```stla
@dialogue_visibility hide transition=fade duration=0.3
@dialogue_visibility quick_menu show transition=fade duration=0.25
```

精确语法只有一套：

- `@dialogue_visibility [surface|quick_menu] show|hide [transition=cut|fade] [duration=<seconds>]`
- 省略可选 `target` 时规范化为 `surface`；显式 `surface` 属于同一 grammar，并生成完全相同的 canonical payload
- `action` 只接受严格小写的 `show` 或 `hide`
- `transition` 省略时为 `cut`
- `fade` 省略 `duration` 时为 `0.25`
- `cut` 只接受 `duration=0`
- 重复或未知参数、非有限值、`NaN` 及负 duration 都会让整条命令 fail-close，并保留精确的 source path 与行号

每条 standalone command 都是 blocking JOIN；无 Presenter 的 headless runner 同步完成。

### 3.5B Addressable dialogue avatar

```stla
@dialogue_avatar show asset=character:portraits/hero.png
@dialogue_avatar hide
```

`@dialogue_avatar` controls one stable avatar projection owned by the dialogue surface. It is
independent from line-local `[expr:]` markers and from named Stage layers. The shortest
`show`/`hide` forms are sufficient for ordinary use; `set` can prepare a hidden stable state
without waiting for a later dialogue line:

```stla
@dialogue_avatar set character=hero expression=neutral visible=false position=-280,-140 origin=-480,320 scale=0.45,0.45
@dialogue_avatar show transition=fade duration=0.3
@dialogue_avatar set expression=smile opacity=0.85
@dialogue_avatar remove transition=fade duration=0.25
```

The exact grammar is:

- `@dialogue_avatar set <properties...> [transition=cut|fade] [duration=<seconds>]`
- `@dialogue_avatar show [<properties...>] [transition=cut|fade] [duration=<seconds>]`
- `@dialogue_avatar hide [transition=cut|fade] [duration=<seconds>]`
- `@dialogue_avatar remove [transition=cut|fade] [duration=<seconds>]`
- source is either `asset=<logical-id>` or the pair `character=<id> expression=<id>`; the two forms are mutually exclusive
- canonical properties are `visible` (only with `set`), `position=x,y`, `origin=x,y`, `scale=x,y`, `rotation`, `z_index`, and `opacity`
- `position` and `origin` are signed pixel coordinates in the avatar container local canvas; `position` places the Sprite, while `origin` is the pivot measured from the source texture top-left and projects as `Sprite2D.offset=-origin`
- `scale` is a unitless positive pair and `rotation` is in radians; source fixed-point, unsigned, degree, or packed encodings must be decoded by the importer before constructing Stella DSL
- `cut` is the default and requires `duration=0`; `fade` defaults to `duration=0.25` and crossfades old/new projections

Source-format fields such as `xpos`, `ypos`, `zoom`, `showmode`, `visvalue`, `leveloffset`,
`order`, and `zpos` are not Stella aliases. An importer must prove and translate them into the
canonical properties above, or reject the source at its original line. Unknown, duplicate,
non-finite, out-of-range, incomplete source, and unsupported current-state updates all
fail-close before Presenter mutation.

Standalone avatar commands lower to a one-child JOIN and always traverse the Runtime-owned
typed Director/DialoguePresenter preflight. Click and Skip may make the effective transition a
cut, but cannot bypass logical-resource validation. Save/load records only the sealed stable
avatar target; Tween, receipt, generation, and line-local avatar state do not enter the snapshot.
Backlog replay restores text and never re-dispatches avatar operations.
The CI-compiled public reference scenario is
[`examples/demo/scenarios/dialogue_avatar.stla`](../examples/demo/scenarios/dialogue_avatar.stla).

### 3.5C Dialogue page clear

```stla
@dialogue_clear
```

`@dialogue_clear` 只有这一种零参数写法。它立即清空当前 live dialogue page：ADV/overlay
清除当前文本、姓名、头像与表情，NVL 清除本页全部累计 entry，并让下一行从新的 page epoch
开始。当前 ADV/NVL/overlay mode、已选择的 dialogue profile、dialogue surface/quick-menu
显隐、Stage、音频与 durable backlog 都保持不变；因此它既不是 `hide`，也不会隐式执行
`@nvl off`。重复、未知或任何参数都会在原 source path/line fail-close。

clear 会退休当前 dialogue-content 生命周期拥有的 typewriter、voice、toolbar replay 和
inline stage-cue callback；独立 `@stage` 或 `@presentation_batch` 已拥有的 Stage transition
不属于它，绝不会被 clear finish 或 cancel。即使页面已经为空，命令仍会取得 positive
batch id 并经过 typed Presenter validate/accept/apply；同步 cut 不产生 transition receipt、
token、Tween 或 wall-clock wait。存档显式记录 cleared 状态，不能通过
`text == ""` 推断；load、rollback、restart 与 scene replacement 都使用 generation 边界拒绝
旧 callback。

#### 高级：mixed presentation batch

只有需要把 chapter indicator、dialogue visibility、dialogue clear、addressable dialogue avatar 与 Stage 操作组成同一 JOIN/FNF 边界时，才使用
`@presentation_batch`：

```stla
@presentation_batch policy=join
  @dialogue_visibility hide transition=fade duration=0.3
  @dialogue_clear
  @dialogue_avatar set character=sakura expression=happy visible=false
  @chapter_indicator show transition=fade duration=0.3
  @stage sakura update asset=character:sakura/happy transition=move duration=0.3
  @dialogue_visibility quick_menu hide transition=fade duration=0.3
@end
```

`@presentation_batch` header 只接受一个严格小写的 `policy=join|fire_and_forget`。block 不能为空，合法 child 只有 canonical `@stage`、canonical `@dialogue_avatar`、canonical `@dialogue_visibility`、canonical `@dialogue_clear`、canonical `@chapter_indicator`、canonical `@loop_se` 与 canonical `@bgm`；child 与 standalone 共用各自唯一的 parser/canonicalization。每批最多一个 dialogue-avatar、dialogue-clear、chapter-indicator child 和一个 BGM child，因为它们分别共享固定 `dialogue:avatar`、`dialogue:content`、`chapter:indicator` / `bgm:main` channel；每个 loop-SE channel 也最多出现一次。解析器保留跨 kind 的 authored child 顺序，且 `operation_lines` 与 child 一一对应；duplicate Stage layer、duplicate avatar/visibility target（省略 visibility target 的 surface 与显式 surface 也视为重复）、duplicate clear/chapter/BGM/loop-SE target、nested batch/if/parallel/combine、scene gap、非法 child 与缺失 `@end` 都会令整块 fail-close。既有 `@stage_batch` 继续保持 Stage-only public contract，不会静默扩成 mixed alias。

Director 在任何 child apply 之前完成整批 typed schema/context preflight，并把 chapter Presenter binding registry 与唯一 AudioPresenter 完整 validate、seal 与 accept；任何 child 的 preflight 在其 source line 失败时都不会留下 Stage、dialogue、chapter 或 audio 的部分 mutation。apply 按 authored child 顺序跨 kind 派发，JOIN 等待 seal 后的 exact receipt union，FNF 则在 seal 后继续。普通 `@chapter_indicator`、`@dialogue_visibility` 和 `@dialogue_clear` 仍应使用简短 standalone 写法；只有真正需要这个原子边界时才使用 batch。

```
@stage <layer-id> show key=value ...
@stage <layer-id> update key=value ...
@stage <layer-id> hide [transition=...] [duration=...]
@stage <layer-id> remove [transition=...] [duration=...]
@stage clear [transition=...] [duration=...]
```

```stla
@stage base show kind=background asset=background:bg_room fit=cover z=-1000
@stage hero show kind=character body=stage:hero/body face=stage:hero/smile x=960 y=1050 origin=500,1000 redraw=color_overlay(#355c7d80,soft_light) redraw=brightness_contrast(12,-20)
@stage hero update face=stage:hero/sad transition=fade duration=0.3
@stage hero hide transition=fade duration=0.2
@stage hero show transition=fade duration=0.2
@stage hero remove
@stage clear
```

| 动作 | 语义 |
|------|------|
| `show` | 不存在时创建层；存在时按补丁更新；最后令 `visible=true` |
| `update` | 只更新已存在层；未给出的属性保持不变，未知 ID 不会隐式创建 |
| `hide` | 隐藏但保留层节点、纹理和规范化状态，后续 `show` 可复用 |
| `remove` | 删除该 ID 的状态和节点 |
| `clear` | 删除全部命名舞台层 |

属性 schema：

| 属性 | 值与含义 | 默认值 |
|------|----------|--------|
| `kind` | 层用途标记，如 `image/background/character/event/sd` | `image` |
| `asset` | 通用单图通道 | 空 |
| `body` / `face` | 独立身体与表情通道；更新 face 不会重建 body | 空 |
| `asset_offset` / `body_offset` / `face_offset` | 对应素材的 `x,y` 偏移，也可拆成 `*_x/y` | `0,0` |
| `position` | 画布位置，也可写 `x/y` | `0,0` |
| `origin` | 变换原点，也可写 `origin_x/y` | `0,0` |
| `scale` / `zoom` / `depth_scale` | 二维缩放、额外缩放和正数景深缩放 | `1` |
| `rotation` | 顺时针角度（度） | `0` |
| `z_index` | 舞台内绘制顺序，别名 `z`，范围 `-4096..4096` | `0` |
| `visible` / `opacity` | 可见性和 `0..1` 透明度 | `true` / `1` |
| `fit` | `native`、`contain`、`cover` 或 `stretch` | `native` |
| `redraw` | 可重复书写的有序像素操作；见下表 | `[]` |
| `flip_x` / `flip_y` | 围绕 authored origin 翻转 | `false` |

成对数值写成 `x,y`；`scale=0.75` 这样的标量会同时作用于两轴。布尔值只接受 `true` / `false`；`asset=none`、`body=none` 或 `face=none` 是唯一的显式清空写法。`depth_scale` 与 `rotation` 是各自唯一的属性名，不接受 `depth`、`rotation_degrees` 或其他兼容别名。任一属性、`transition` 或 `duration` 非法时，Parser 会生成带 STLA 行号的诊断并拒绝整条 `@stage`，不会保留同一行中的其他合法字段，也不会把错误值改写成默认值。

`redraw=` 可在同一条命令中重复，执行顺序就是书写顺序，每层最多 16 个操作，其中最多 4 个 `blur`、1 个 `clip`。每次 `blur` 都读取前一操作输出并形成独立 pass。只要给出任意 `redraw=`，该命令就会原子替换该层的完整重绘管线；省略它会保留原管线，`redraw=clear` 则清空。函数参数内不能包含空格。

| 重绘操作 | 语义 |
|----------|------|
| `redraw=color_overlay(#RRGGBBAA,blend)` | 以 `normal` 或 `soft_light` 模式叠色；blend 省略时为 `normal` |
| `redraw=brightness_contrast(brightness,contrast)` | 8-bit 明度/对比度；范围分别为 `-255..255`、`-100..100` |
| `redraw=grayscale(amount)` | 灰度混合量 `0..1`；8-bit 目标灰度严格为 `(54 * R + 183 * G + 19 * B) >> 8` |
| `redraw=tint(#RRGGBBAA)` | 逐通道乘色 |
| `redraw=blur(x,y)` | 完整矩形 box average；对 `[-x,+x] × [-y,+y]` 内所有像素作等权 RGBA 平均，`x,y` 为 `0..32` 整数 |
| `redraw=clip(asset,x,y,fit)` | 以图片 alpha 裁剪整层；遮罩矩形外 alpha 为 0 |

`clip` 的 `x,y` 是层合成空间中的左上角偏移；`fit` 可省略，默认 `native`，也可为 `contain`、`cover` 或 `stretch`。遮罩和普通舞台素材使用完全相同的资源前缀与缓存规则；遮罩缺失时该层会 fail-closed 为透明，并输出资源警告。连续的 `blur` 不会合并：第二次必须对第一次的完整结果再次取矩形平均。`blur(0,0)` 会保留在规范状态和 JSON 中，但其像素语义是真正的 no-op，不建立额外量化 pass。重绘数组会原样进入 JSON 存档，所以顺序、重复操作、有符号 brightness/contrast 参数和逻辑遮罩 ID 都会被精确恢复。

```stla
@stage dusk show asset=stage:portrait redraw=color_overlay(#355c7d80,soft_light) redraw=brightness_contrast(12,-20) redraw=grayscale(0.2) redraw=blur(1,1) redraw=blur(2,0) redraw=clip(stage:soft_edge_mask,0,0,native)
@stage dusk update redraw=clear
```

`transition` / `duration` 属于 operation，不进入持久层状态。最短写法仍是 `transition=cut|fade|move|slide_left|slide_right|slide_up|slide_down`；`none` 是既有的 `cut` authoring spelling，canonical payload 中保存为 `cut`。投影型转场使用同一个无空格表达式 `transition=<kind>(key=value,...)`：

```stla
@stage event update asset=stage:event/night transition=rule(mask=stage:masks/diagonal) duration=0.8
@stage event update asset=stage:event/dawn transition=rule(mask=stage:masks/cloud,softness=0.12,invert=true) duration=1.0
@stage event update asset=stage:event/noon transition=mosaic duration=0.6
@stage event hide transition=mosaic(cell=48) duration=0.4
```

- `rule(mask=<logical-id>, softness=0..1, invert=true|false)`：`mask` 必填，必须是 `background:` / `character:` / `stage:` 或裸 stage logical ID，不能是 `res://`、`user://`、绝对路径或 `..` 路径；`softness` 默认 `0`，`invert` 默认 `false`。
- `mosaic(cell=2..256)`：先把 source 像素块放大，到中点切换 target，再缩小像素块；`cell` 默认 `32`，因此最短作者写法只是 `transition=mosaic`。

参数顺序不影响 canonical payload；重复、未知、非有限或类型错误的参数会整条 fail-close。普通转场不接受括号参数。`duration` 必须是有限的非负秒数，`cut` / `none` 只接受 `0`。每条 operation canonicalize 为 `action / id / properties / transition / transition_params / duration` 六字段，`transition_params` 是 primitive-only 的 defensive typed Dictionary。

Rule 遮罩以 normalized viewport UV 拉伸到整个视口、nearest sample，不做 aspect-fit；存储的 RGB bytes 作为数据，以 `(54R + 183G + 19B) / 256` 计算 luminance。`softness=0` 使用 hard threshold；非零 softness 使用 `1 - smoothstep(progress-softness/2, progress+softness/2, luminance)`，`invert=true` 只反转 luminance。`progress=0/1` 直接选择 source/target endpoint，完成后释放 shader/snapshot 并恢复 live canonical target。

内置 provider 和项目注册的扩展 provider 都只负责同步 schema/resource validation 与 `ShaderMaterial`；Tween、JOIN/FNF receipt、Skip/click exact completion、abort/cancel 和 stale generation 仍由唯一 Runtime-owned Director/StagePresenter 生命周期拥有。资源、Shader、viewport/budget 与 source/target projection snapshot 必须在任何舞台 mutation 或 receipt claim 前通过 typed participant preflight；缺失 mask、未注册 provider 或超预算会以 child 的 `source_path:line` fail-close。每个 Presenter 的 mask/resource LRU 上限为 16，active transition snapshot 预算为 256 MiB，单轴还受设备 2D texture limit 与 8192 上限约束。

每层拥有独立 Tween。快进、点击补全和读档会以强制 cut 一次投影已封存的最终 canonical state；存档不保存 Tween/progress/snapshot，读档、回滚、重启和 scene replacement 会先退休旧 token/generation，再 cut 恢复 target，旧 callback 不能覆盖新投影。

资源引用可使用 `background:`、`character:`、`stage:` 或完整 `res://` 前缀。没有前缀的相对路径从 `[paths] stage` / `StellaRuntime.stage_assets_path` 解析；扩展名可省略。层 ID 应是稳定业务名称，而不是资源路径或场景节点路径。

`@bg` 仍是独立的基础背景功能，由 `BackgroundPresenter` 管理；`@stage` 不会隐式修改背景。需要多块背景、前景遮罩或可单独变换的场景碎片时，再把它们作为命名舞台层创建。

### 3.6 音频

```
// BGM — lifecycle 动画必须由作者显式声明
@bgm play bgm_spring
@bgm play bgm_cafe volume=0.7 fade=1.5
@bgm play bgm_battle_stems mix=rhythm,bass:0.7
@bgm mix rhythm:0.4,bass,melody fade=0.8
@bgm pause fade=0.2
@bgm resume fade=0.2
@bgm stop fade=1.0

// 一次性音效
@se se_door_open

// 持续循环音效：以稳定 channel 寻址
@loop_se ambience play se_rain
@loop_se ambience play se_storm volume=0.7 fade=1.0
@loop_se ambience stop
@loop_se ambience stop fade=1.0

// 语音（通常不需要手写，跟在对话后面用 #voice: 即可）
@voice sakura_001
```

`@se <asset>` 只播放一次，不可寻址；它没有 `loop` / `off` 参数，也没有按素材名停止的 API。

BGM 是单一固定 channel，唯一 public grammar 是：

```stla
@bgm play <asset> [cue=<name>] [mix=<stem>[,<stem>[:<gain>]...]] [volume=0..1] [fade=<seconds>]
@bgm mix <stem>[,<stem>[:<gain>]...] [fade=<seconds>]
@bgm pause [fade=<seconds>]
@bgm resume [fade=<seconds>]
@bgm stop [fade=<seconds>]
```

`volume` 默认 `1`，所有 action 的 `fade` 都默认 `0`；最短 `@bgm play asset` 没有增加任何参数负担。`mix=` 只用于 play 时设定 multi-stem 初始配比，`@bgm mix` 只改变当前 multi-stem 配比。mix spec 以逗号分隔 stem；裸 stem 的 gain 为 `1`，显式 gain 必须是有限的 `0..1`，资源中存在但未列出的 stem 规范化为 `0`。重复/未知 stem、空项、全零 mix 和非法 gain 都 fail-close。gain `0` 在物理 mixer 中是 exact silence，不会被映射为有限 dB floor。`fade` 是整个 replacement crossfade 或 stem mix 的总时长，不是先淡出再淡入的两段时长。standalone BGM 默认 fire-and-forget；需要等待淡变或与 Stage 等 child 共用原子边界时，只使用现有 `@presentation_batch`：

```stla
@presentation_batch policy=join
  @bgm play bgm_cafe cue=evening fade=0.8
  @stage cafe show asset=stage:cafe transition=fade duration=0.8
@end
```

同一 playing asset+cue 且 volume/stem mix 相同仍会通过 AudioPresenter/resource positive preflight，物理投影稳定时不重播、不 seek、也不创建 receipt；只改 volume 或 stem mix 会复用同一个 player/stream/cursor。`@bgm mix` 直接淡变同一 `AudioStreamSynchronized` 的子流 gain，不创建 stem player、第二 scheduler 或 guessed wait。若相同 play/mix/pause/resume/stop target 仍由上一条 fire-and-forget fade 持有，新的同 action 会先把旧 exact receipt 完成到唯一 authored endpoint，再以零新 Tween 同步确认；旧 token 的迟到 callback 无效。paused 状态下 `play` 从 cue 的 authored start marker 重播，只有 `resume` 从保留 cursor 继续；显式重启写成 `stop` 后再 `play`，不存在 `restart` option。对空 channel 执行 `mix`/`pause`/`resume` 会在该行 fail-close；single-stream BGM 也拒绝 `mix`；`stop` 为空时同步 no-op。

原始 OGG/MP3/WAV 默认 `loop=true`、start=0，并保留格式自身合法的 loop marker。需要 authored start/loop marker 或 named cue 时，asset 指向 `BgmTrackDefinition` `.tres`；default 与每个 `BgmCueDefinition` 都是完整定义，cue 不继承 track 字段：

```gdscript
# BgmTrackDefinition
stream = <AudioStream>
stems = []
loop = true
start_position = 0.0
loop_position = 4.2
loop_end_position = 12.8 # -1.0 (default) means physical stream end
cues = [<BgmCueDefinition cue_name="evening" ...>]
```

`BgmTrackDefinition` 是严格 sum schema：`stream` 与 `stems` 必须且只能设置一个。single-stream 继续使用上面的 `stream`。multi-stem 则把 `stream` 留空，并提供 2..32 个 `BgmStemDefinition {stem_name, stream, default_gain}`；名称必须唯一，`default_gain` 为有限 `0..1`，且默认 mix 至少一个 gain 大于 0。所有 stem 必须同为 OGG、MP3 或 WAV，报告相同有限正长度；WAV 还必须具有相同 `mix_rate`、`stereo` 和 sample `format`。Presenter 预检成功后把它们装入一个 `AudioStreamSynchronized`，因此相位对齐并只占一个 `bgm:main` player。正在播放的 same asset+cue 只有在 ordered stem names、default gains、源流内容/格式与选中 marker 组成的 resource signature 完全一致时才允许原地 play/mix；合法 hot reload 若改变该 signature，会在 mixed batch 的任何 child mutation 前 fail-close。

每个 default/cue 都完整声明 `loop`、`start_position`、`loop_position` 与 `loop_end_position`；cue 不继承 track。`loop_end_position=-1.0` 是唯一 sentinel，解析为 physical stream end，其他负数非法。resolved region 必须对每个 stem 满足有限的 `0 <= start_position <= loop_position < loop_end_position <= stream length`；即使 `loop=false` 也验证同一完整 region，但 duplicate stream 会禁用循环并继续播放 physical tail，不会被 end marker 截断。

显式 end 只写入 definition duplicate 的 Godot 4.6 native mixer primitive：WAV 使用 sample `loop_begin` / `loop_end`，OGG/MP3 使用 `loop_offset` 与单 beat boundary（`beat_count=1`、`bpm=60/loop_end_position`）。压缩格式设置后必须读回 boundary，并证明误差小于一个 source sample，否则 fail-close；没有 importer trim/transcode、时长猜测、polling、timer 或 frame wait。natural sentinel 会清除 definition duplicate 上的 beat end marker，使其在 physical end 循环；直接引用的 raw stream 则保留自己的合法 native marker。multi-stem 的同一 resolved end 应用于每个 synchronized child，mix 仍只改 gain，不 seek 或替换 stream。这个 resource 字段不会增加 DSL option 或 save 字段。stream 无法报告有限正长度、stem metadata 不一致、cue/stem 重名/非法/缺失、region 越界、boundary 不可精确表示、资源缺失/歧义或格式不支持时，Director 会在 mixed batch 的任何 child mutation 前按 BGM child 的 `source_path:line` 拒绝整批。

旧 `@bgm asset [fade]` / `@bgm off [fade]` grammar 已删除，不作为 alias 接受；迁移为 `@bgm play asset fade=...` / `@bgm stop fade=...`。

持续环境声使用唯一 canonical grammar：

```stla
@loop_se <channel> play <asset> [volume=0..1] [fade=<seconds>]
@loop_se <channel> stop [fade=<seconds>]
```

channel 是区分大小写的稳定业务 ID，必须匹配 `[A-Za-z_][A-Za-z0-9_-]*`，最长 64 字符；寻址永远不依赖素材文件名。`volume` 默认 `1`，`fade` 默认 `0`，都必须是有限非负数（volume 还必须不超过 1）。stop 一个不存在的 channel 是同步 no-op。同 channel 的 asset 与 volume 都相同时不会 seek、重播或建立新 receipt；只改 volume 会保留同一个 player 和播放位置，并在需要时淡变音量；asset 改变才会用最多两个 player 交叉淡变。新的 generation 抢占未完成 crossfade 时会立即切掉更老的 outgoing，只保留 canonical incoming 作为下一次 outgoing。

loop-SE 只接受 OGG / WAV。Presenter 会 duplicate stream 后开启真正的格式循环，因此不会修改同一资源作为普通 `@se` 播放时的 metadata；OGG `loop_offset` 与 WAV `loop_begin` / `loop_end` 等已有 marker 会保留。本语法不暴露 start/loop marker 参数；缺失或不支持的资源会在任何 mixed batch child apply 前以该 child 的 `source_path:line` fail-close，绝不会降级成 one-shot。

standalone `@loop_se` 默认 fire-and-forget。需要等待淡变，或与 Stage、对话显隐、章节指示器在同一原子 authored boundary 组合时，把同一 canonical child 放入唯一的 `@presentation_batch`：

```stla
@presentation_batch policy=join
  @loop_se ambience play se_rain fade=0.5
  @stage rain_overlay show asset=stage:rain transition=fade duration=0.5
@end
```

完整的可运行公开示例见 `examples/demo/scenarios/loop_se.stla`。

JOIN 只等待该 batch 的 exact receipts；点击或持续 Skip 会 exact-finish 当前 JOIN，Skip 已开启时新操作直接 cut，Auto 本身不结束音频 JOIN。FNF 在 dispatch seal 后继续剧情，但 receipt 会保留到自己的 terminal 后清理。

### 3.7 转场与特效

```
// 屏幕特效
// 震动，默认 intensity=10 duration=0.3
@effect shake
// 指定强度和时长
@effect shake 20 0.5
// 闪光，默认 white 0.2s
@effect flash
// 指定颜色和时长
@effect flash red 0.25
// 也支持十六进制颜色
@effect flash #ff0000 0.25
// 清除所有特效
@effect off

// 黑屏过渡（常用于时间跳跃）
@fade out 1.0
「第二天——」
@fade in 1.0
```

**shake 参数**：`intensity` 是每次采样 ± 偏移像素的幅度（默认 10），`duration` 是总时长秒（默认 0.3）。数值必须有限，时长不能为负；错误参数会产生带行号的解析诊断并安全地跳过该特效，不会中断已经播放中的效果。负强度会取绝对值并产生警告；运行时还会按 `ScreenEffects.max_shake_intensity`（默认 4096）以及框架固定的 4096 绝对安全上限限制极端强度。

**flash 参数**：`color` 接受 Godot 命名颜色（`white`/`red`/`black`/`blue`/...）或十六进制字符串（`#ff0000`），未知名会 fallback 到白色。`duration` 是淡出总时长秒（默认 0.2），必须是非负有限数值。flash 的实际绘制层由游戏场景中的 `ScreenEffects` 配置决定；自定义场景的 shake 根节点与 flash 层级规范见[使用指南](USAGE.md)。

当前内置效果只有 `shake`、`flash` 和 `off`。其它 effect type 会产生 warning，并连同原始位置参数数组 `args` 转发给 `SignalBus.effect_requested`，供项目自定义监听器处理；拼写错误因此不会再静默消失。内置效果如果参数过多会产生 error 并跳过。

`GameSettings.effect_enabled`（默认 `true`）只控制内置 `ScreenEffects` 的 `shake` 与
`flash` 渲染。设为 `false` 后，新请求仍按 fire-and-forget 语义完成并发布
`SignalBus.effect_requested`，因此自定义监听器照常收到事件，但内置 Presenter 不修改
画面、也不缓存请求供以后重放；活动 shake/flash 会被同步恢复为中性状态。重新开启后
只有新请求会生效。`@effect off` 无论该设置为何值都执行清理；`@fade`、舞台、对话、
音频和项目自定义 effect 不受此开关影响。

### 3.8 分支选择

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

Choice 是 hard blocking command，始终需要玩家显式选择，不会因 Auto 或 Skip 开启而
默认选中第一项。`auto_play_pause_on_choice` 与 `skip_stop_on_choice`（均默认 `true`）
在每次 choice 显示前分别快照：前者暂停 Auto 的 effective progression 但保留用户
active intent，并在有效选项 effects 提交后恢复；后者同步停止 Skip，选择后也不自动
恢复。设置为 `false` 时对应 intent 可以保持，但菜单仍阻断所有自动/普通推进。

只有当前菜单中匹配 id 或 label 的首个选择会提交 jump/set；未知、重复或迟到的
`choice_selected` payload 不会关闭菜单或污染后续 choice。读档、回退、restart、abort
与返回标题会先退休旧执行 owner，再取消当前菜单并停止 Auto/Skip；同步取消尾不能提交
旧 effects、继续旧 command tail 或隐藏替换 context 新建的 choice。普通存档不会取消它。

### 3.9 变量与条件

```
// 赋值
@set talked_to_sakura = true
@set sakura_affection += 5

// 条件跳转
@if sakura_affection >= 5
  @jump good_ending
@elif sakura_affection >= 5
  @jump normal_ending
@else
  @jump bad_ending
@end

// 条件段落（控制一段内容是否显示）
@if has_key
  sakura「你有钥匙！太好了。」
@else
  sakura「没有钥匙的话...怎么办呢。」
@end
```

条件块可以嵌套；内层 `@end` 会回到当前外层分支继续执行，外层各分支最后再汇合到同一个 continuation。每个 `@if`（包括带 `@elif` / `@else` 的条件链）都必须用自己的 `@end` 闭合。

条件支持比较运算 `>=`、`>`、`<`、`<=`、`==`、`!=`，以及逻辑运算 `&&`、`||`、`!`。运行时求值与剧本内容指纹使用同一份规范化表达式表示，因此 `score==1`、`score  ==  1.0` 等仅空白或数值拼写不同的表达式语义相同，也不会让既有台词突然变回未读；修改运算符、变量或实际数值仍会生成新的内容版本并 fail-closed 为未读。

### 3.10 流程控制

```
// 跳转场景
@jump scene_002

// 调用子场景（执行完后返回）
@call flashback_001

// 场景命令耗尽后按声明顺序进入下一 scene；需要改变流程时显式跳转
@jump scene_002
```

`@end` 只用于闭合 `@if`、`@parallel`、`@stage_batch` 和 `@combine` 块，不是终止指令。
最后一个 scene 的命令执行完毕后，剧本自然结束。

### 3.11 并行指令

```
// 同时执行多个操作
@parallel
  @bg bg_sunset dissolve 1.0
  @stage sakura update position=960,80 transition=move duration=0.5
  @stage kaito update opacity=0.5 transition=fade duration=0.5
@end
```

编剧只有在需要"多件事同时发生"时才用 `@parallel`，日常演出不需要。

`@parallel` 只接受不会等待玩家或剧情结果的演出命令。对话（含旁白、独白）、
`@choice` 与 `@wait` 都是 blocking command，Parser 遇到其中任意一项会把整个
block 作为错误拒绝，不会只执行剩余兄弟命令。合法的背景、舞台、音频与特效
子命令会在同一调用栈中依次发起，因此各自的 Tween/播放可同时进行；block
本身不等待这些表现动画结束。

### 3.12 舞台批次组合（@stage_batch）

`@stage_batch` 把同一 authored boundary 中的多个命名 Stage 操作原子提交，并由必填 policy 决定是否等待转场：

```stla
@stage_batch policy=join
  @stage sky show asset=stage:sky transition=fade duration=0.3
  @stage hero update x=900 transition=move duration=0.3
  @stage haze hide transition=fade duration=0.3
@end

@stage_batch policy=fire_and_forget
  @stage hero update x=1100 transition=move duration=0.3
@end
```

header 只接受唯一的 `policy` option。它必须出现一次，且值严格区分大小写，只允许 `join` 或 `fire_and_forget`；未知 option、裸 `join`、`JOIN`、`Fire_And_Forget`、重复或空值都会拒绝整块。block 不能为空。

child 只能是经现有 `@stage` parser 完整规范化的 canonical Stage 操作。同一 batch 内每个非 clear layer ID 最多出现一次；`@stage clear` 若出现，必须是唯一 child。dialogue、audio、`@wait`、`@chapter_indicator`、嵌套 `@stage_batch`、`@parallel`、`@combine`、块内 `@if` 或其他 command 都不允许。`@stage_batch` 本身可以位于 active scene，也可以位于实际执行的 `@if` / `@else` 分支；不能出现在 scene 外、chapter 与首个 scene 之间，或 `@parallel` / `@combine` 内。

header、空 block、scene 边界或缺失 `@end` 的错误定位 opening line；duplicate/clear-conflicting canonical `@stage`、其他非法 child 或 nested block 定位 offending child line。canonical child 原本产生 warning 并拒绝命令时，batch 边界会把同一 message/source path/line 升级为 fatal error。缺失 `@end` 在 opening line 报错，且不会吞掉后续 `@scene` 或 `@chapter`。任意错误都使整块 fail-close：不生成 `stage_batch` command，child 不泄漏为 standalone command，runtime 也不发生部分 mutation。

`join` 在本批 dispatch tail 封存 exact receipt set 后，等待全部 receipt 成功 terminal；零 token 同步完成。不含 live projection exception 的 semantic no-work 会在任何 request/batch ID、Bus、receipt、token 或 Tween 分配前同步完成。每条 Stage 即使 canonical state 相等或 remove 的层不存在也必须取得 positive batch，让 Presenter quorum 重验 provider、资源与 viewport/budget；稳定对齐时零 receipt/Tween 同步完成。每条 loop-SE 即使 canonical state 相等也必须取得 positive batch，经 AudioPresenter 重新验证资源与真实 player；完全稳定对齐时才在 Presenter 内以零 receipt 同步完成，仍在 fade 的同 target 则先 exact-complete 旧 owner。当前 owner 的任一 superseded 或 cancelled receipt 都使 JOIN fail-close。普通左键、Space 或 Enter 只 finish 当前 sealed JOIN，不会跨越到下一命令。`fire_and_forget` 在 dispatch seal 后立即继续，不占用输入，此时 Tween 可仍在运行。连续 batch 按 SignalBus 顺序派发；后来的同层 generation 拥有最终状态，旧 terminal 不能完成新 batch。不得使用计时等待或 `@parallel` 伪造 JOIN。

既有作者语义保持不变：standalone `@stage` 仍是 nonblocking；`@parallel` 仍只是同栈启动 child，不 join；`@combine` 仍是 dialogue segment cue，不是 batch barrier。每条 combine Stage cue 的 authored line 会随 canonical 六字段 payload进入唯一 typed Director；rule/mosaic/custom 即使因点击或 Skip 以 force-cut 完成，也仍先验证 provider、mask、viewport 与预算，不会改写 authored transition 或走 raw Stage backdoor。公开 reference scenario 见 [`examples/demo/scenarios/stage_batch.stla`](../examples/demo/scenarios/stage_batch.stla)；它用于文档链接，不是默认 Start Game 入口。

### 3.13 合并对话（@combine）

一句台词在演出上是一整句，但声优录音被拆成了多段，每段之间还要切换舞台差分或对话框头像：

```
@combine
@stage sakura update face=stage:sakura/sad transition=fade duration=0.2
@dialogue_avatar set character=sakura expression=sad visible=true transition=fade duration=0.2
sakura「[expr:sad]我本来很开心的...」 #voice:sakura_013
@stage rain update opacity=0.6 transition=fade duration=0.2
@stage sakura update face=stage:sakura/surprised transition=fade duration=0.2
sakura「[expr:surprised]但是听说下周要期中考...」 #voice:sakura_018
@stage sakura update face=stage:sakura/sad transition=fade duration=0.2
sakura「[expr:sad]我数学肯定完蛋了。」 #voice:sakura_019
@end
```

**语义：**

- 块内所有 dialogue 行合并为**一句对话**，玩家视角上打字机从头连续打到尾
- 块内一个或多个 `@stage` / `@dialogue_avatar` 按 authored 顺序绑定到紧随其后的 segment
- 每个 segment 的统一 typed presentation batch 先提交，再播放该段语音
- 方括号表情标记随打字机更新对话框头像，不会写入舞台层
- 语音按顺序排队：第 1 段播完 → 应用下一段舞台批次 → 第 2 段立即接上 → ...
- 左键点击：整句结束，所有 segment 的 Stage/avatar 操作按原顺序归约后一次 typed force-cut 到最终态；资源 preflight 仍不可跳过
- 快进模式：整段作为一句跳过
- Backlog：记为一条

**限制：**

- 块内只允许 `@stage`、`@dialogue_avatar` 和 dialogue 行（角色名必须一致，或全为旁白）
- presentation operation 后必须有 dialogue segment 承接
- 其它指令（如 `@bg`、`@effect`）不允许出现在块内
- 跟随当前 NVL / overlay 模式及其命名 Profile
- 在 NVL 中整个块算一条记录，`entry_prefix` 只添加一次

每个 segment 内部只有一个 `presentation_ops` 列表和一个等长、全为正整数的
`presentation_operation_lines` sidecar；Stage 与 avatar 不使用各自的平行字段。Presenter
在对应 voice 之前把每项构造成 source-located typed operation，提交给唯一 Runtime-owned
Director。sidecar 缺失、长度不符、行号非法、资源不可解析或后续操作对当前稳定状态无效，
都会在 authored line 原子失败，不会先应用 earlier child 或卡住 voice queue。

### 3.14 等待

```stla
@wait 1.5                         // 固定等待 1.5 秒（默认）
@wait 1.5 skippable=true          // 玩家推进或 Skip 可提前结束
@wait click                       // 只等待一次玩家推进
```

精确语法为：

```text
@wait <seconds> [skippable=true|false]
@wait click
```

- timed wait 的 `skippable` 默认是 `false`，因此既有 `@wait 1.5` 仍完整等待计时器；需要玩家可提前结束时才显式写 `skippable=true`。
- duration 必须是有限、非负的秒数。`skippable` 是 timed wait 唯一可选项，只接受严格小写的 `true` / `false`；未知、重复、裸参数、`canskip` 等遗留别名都会带 `source_path:line` fail-close。
- `@wait click` 是独立模式，不接受 `skippable` 或其他 option。
- 可跳过 timed wait 接受与对话相同的普通推进输入：左键、Space、Enter 和手柄 A；Skip 激活时也会立即结束，已处于 Skip 时不会创建 timer。Auto 不是玩家推进，不会擅自截短 authored duration。
- timer、玩家推进和 engine/context cancellation 只允许一个结果获胜。一次输入最多结束当前 wait；迟到 timer、旧 signal tail、读档、Backlog/流程图回退、重启、返回标题或 scenario replacement 的旧 listener 都不能推进下一条命令。
- non-skippable timed wait 只忽略玩家推进和 Skip；它仍必须响应 engine abort/context cancellation。这与 authored player skip 是两套边界。

大部分情况不需要手写 `@wait`；对话会自动等待点击。

可运行的公开示例见 [`examples/demo/scenarios/skippable_wait.stla`](../examples/demo/scenarios/skippable_wait.stla)。

## 4. 完整示例

```
// demo.stla
@chapter prologue "序章"
@scene start "序章"

// 背景和角色登场
@bg bg_school_gate
@stage sakura show kind=character asset=character:sakura/smile position=480,80 origin=720,0 scale=0.8 z=10 transition=fade duration=0.3
@stage kaito show kind=character asset=character:kaito/default position=1440,80 origin=720,0 scale=0.8 z=11 transition=fade duration=0.3

// 日常对话
sakura「今天天气真好呢。」 #voice:sakura_001
kaito「是啊。」

// 继续对话
sakura「对了！放学后一起去新开的咖啡店吧！」 #voice:sakura_002

// 选择分支
@choice
  - "好啊，走吧" -> scene_cafe {sakura_affection += 5}
  - "今天有点忙..." -> scene_reject

//========================================
@scene scene_cafe "咖啡店"

@bg bg_cafe fade 1.0
@stage kaito remove transition=fade duration=0.2
@stage sakura update asset=character:sakura/smile position=960,80 transition=move duration=0.5

sakura「你看你看，这个蛋糕好可爱！」 #voice:sakura_010
@stage cafe_sd show kind=sd asset=stage:sakura_chibi_excited position=1450,700 z=30 transition=fade duration=0.2
sakura「我要点这个！」 #voice:sakura_011
@stage cafe_sd remove transition=fade duration=0.2

// 回忆闪回
@fade out 0.5
@overlay
「（她的笑容...让我想起了小时候的事。）」
@overlay off
@fade in 0.5

// 舞台差分和头像提示同步到分段语音
@combine
@stage sakura update asset=character:sakura/default transition=fade duration=0.15
sakura「[expr:default]我一直很喜欢这种店呢。」 #voice:sakura_012a
@stage sakura update asset=character:sakura/sad transition=fade duration=0.15
sakura「[expr:sad]不过...自从那件事之后就没怎么来过了。」 #voice:sakura_012b
@end

@if sakura_affection >= 10
  @jump good_ending
@else
  @jump normal_ending
@end

//========================================
@scene scene_reject "拒绝"

@stage sakura update asset=character:sakura/sad transition=fade duration=0.15
sakura「这样啊...那没关系。」 #voice:sakura_020

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
@stage clear transition=fade duration=0.3
「—— Good End ——」
@jump scenario_done

//========================================
@scene normal_ending "Normal End"

@stage clear transition=fade duration=0.3
@nvl
「日子一天天过去，一切都没有改变。」
「但是那个春天的记忆，我一直没有忘记。」
@nvl off

「—— Normal End ——」
@jump scenario_done

//========================================
@scene scenario_done
@fade out 0.5
```

## 5. 语法速查表

| 操作 | 语法 | 最短形式 |
|------|------|---------|
| 对话 | `角色「台词」 #voice:id` | `角色「台词」` |
| 旁白 | `「文本」` | `「文本」` |
| 独白 | `角色（文本）` | `角色（文本）` |
| 章节标题指示器 | `@chapter_indicator show|hide transition=... duration=...` | `@chapter_indicator show` |
| 背景 | `@bg asset transition duration` | `@bg asset` |
| 显示舞台层 | `@stage id show key=value...` | `@stage id show` |
| 更新舞台层 | `@stage id update key=value...` | — |
| 隐藏舞台层 | `@stage id hide transition=... duration=...` | `@stage id hide` |
| 删除舞台层 | `@stage id remove transition=... duration=...` | `@stage id remove` |
| 清空舞台层 | `@stage clear` | `@stage clear` |
| 句内头像表情 | `[expr:expression]` | — |
| BGM 播放 | `@bgm play asset cue=... volume=... fade=...` | `@bgm play asset` |
| BGM stem mix | `@bgm play asset mix=rhythm,bass:0.7` / `@bgm mix rhythm:0.4,bass fade=...` | 仅 multi-stem resource |
| BGM 暂停/继续/停止 | `@bgm pause\|resume\|stop fade=...` | `@bgm pause` / `@bgm resume` / `@bgm stop` |
| 音效 | `@se asset` | `@se asset` |
| 循环音效播放 | `@loop_se channel play asset volume=... fade=...` | `@loop_se channel play asset` |
| 循环音效停止 | `@loop_se channel stop fade=...` | `@loop_se channel stop` |
| 对话 Profile | `@dialogue_profile name key=value...` | — |
| ADV 对话 | `@adv profile=name` | `@adv` |
| 全屏对话 | `@nvl profile=name ... @nvl off` | `@nvl` |
| 无框叠字 | `@overlay profile=name ... @overlay off` | `@overlay` |
| 特效 | `@effect shake/flash/off ...` | — |
| 黑屏 | `@fade out/in duration` | `@fade out/in` |
| 选择 | `@choice` + 选项列表 | — |
| 变量 | `@set var = value` | — |
| 条件 | `@if ... @elif ... @else ... @end` | — |
| 跳转 | `@jump scene_id` | — |
| 并行 | `@parallel ... @end` | — |
| Stage 批次 | `@stage_batch policy=join|fire_and_forget ... @end` | — |
| 合并 | `@combine ... @end` | 多段语音、头像提示与舞台操作合并为一句对话 |
| 等待 | `@wait seconds [skippable=true\|false]` / `@wait click` | `@wait 1.5` |
| 场景 | `@scene id "title"` | `@scene id` |

## 6. 智能默认值总表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 背景转场 | `fade 0.5s` | `@bg` 的默认切换方式 |
| 舞台层动作 | `show` | `@stage id key=value` 等价于 `@stage id show key=value` |
| 舞台层转场 | `cut 0s` | 通过 `transition` / `duration` 显式启用动画 |
| 章节标题指示器 | `cut 0s`；`fade` 为 `0.25s` | `none` 规范化为 `cut 0s` |
| BGM 音量 / 淡变 | `1` / `0s` | standalone 默认 fire-and-forget；所有动画显式写 `fade=` |
| loop-SE 音量 / 淡变 | `1` / `0s` | standalone 默认 fire-and-forget；JOIN 只通过 `@presentation_batch` 选择 |
| timed wait 可跳过 | `false` | 显式 `skippable=true` 才接受普通推进或 Skip |
| 对话推进 | 等待点击 | 有语音时可配置等语音播完 |

## 7. 解析器架构

DSL 是唯一的脚本格式，引擎直接解析 `.stla` 为内部数据结构（ScenarioData）。

整个 `@stage_batch` block 编译为一个 `stage_batch` command，并保留每个 child source line 供 runtime fail-close；内部 IR 的唯一主说明见 [Architecture 的 PresentationDirector 与 exact Stage composition](ARCHITECTURE.md#presentationdirector-与-exact-stage-composition)。

```
ScriptParser/
├── dsl_lexer.gd               -- 词法分析：将 .stla 文本分割为 Token 流
├── dsl_parser.gd              -- 语法分析：Token 流 → ScenarioData
├── dsl_token.gd               -- Token 类型定义
├── dialogue_profile_parser.gd -- 对话 Profile 解析与校验
└── scenario_graph_builder.gd  -- 从 ScenarioData 构建流程图
```

### 解析示例

完整 DSL（2 行容器声明 + 3 行场景正文）：
```
@chapter demo
@scene intro
@stage sakura show kind=character asset=character:sakura/default position=960,80 origin=720,0 scale=0.8
sakura「你好。」
@stage sakura update asset=character:sakura/smile transition=fade duration=0.15
```

解析器填充省略值并生成等价的 `CommandData` 序列：
```
CommandData("stage_layer", { action: "show", id: "sakura", properties: { asset: "character:sakura/default", ... } })
CommandData("dialogue",   { character: "sakura", text: "你好。", mode: "adv" })
CommandData("stage_layer", { action: "update", id: "sakura", properties: { asset: "character:sakura/smile" }, transition: "fade", duration: 0.15 })
```

### 诊断

`DslParser` 会把缺失章节、重复 ID、未闭合块、非法参数和未知指令等问题
写入带源码行号的 diagnostics。`ScenarioGraphBuilder` 随后检查未知跳转目标、
跨章节跳到非入口场景，以及没有出口的章节内部循环。运行时加载剧本时会统一
输出这些 diagnostics；解析与图校验直接作用于同一份 `ScenarioData`。
