# Stella — 使用指南

## 安装

### 方法 1：从 GitHub 安装

1. 下载 [最新 Release](https://github.com/butter-stella/stella/releases) 中的 `stella-plugin.zip`
2. 解压到你的 Godot 项目的 `addons/` 目录下
3. 在 Godot 编辑器中：**Project → Project Settings → Plugins** → 启用 **Stella**

### 方法 2：从源码安装

1. 将 `addons/stella/` 目录复制到你的项目的 `addons/` 下
2. 启用插件（同上）

插件激活后会自动注册 `SignalBus` 和 `StellaRuntime` 两个 Autoload，并将空白项目或旧版内置标题入口迁移到无 UI 的启动场景。启动场景会在分层配置解析完成后进入最终的 `title_scene`；已有项目自己设置的主场景不会被覆盖。

---

## 快速开始（5 分钟跑通）

### Step 1 — 创建目录结构

在你的项目中创建以下目录：

```
your_project/
├── addons/stella/        ← 框架插件
├── art/
│   ├── backgrounds/       ← 背景图 PNG
│   ├── characters/        ← 人物图片与头像资源（按角色分文件夹）
│   │   └── sakura/
│   │       ├── default.png
│   │       └── smile.png
│   └── stage/             ← 命名舞台层资源（人物差分、前景、特效等）
├── audio/
│   ├── bgm/               ← BGM (ogg/mp3)
│   └── se/                ← 音效 (ogg/wav)
├── scenarios/             ← .stla 剧本
└── stella.cfg            ← 配置文件
```

### Step 2 — 写一段剧本

创建 `scenarios/demo.stla`：

```
@chapter prologue "序章"
@scene start "开始"

@bg bg_school
@stage sakura show kind=character asset=character:sakura/smile position=960,80 origin=720,0 scale=0.8 transition=fade duration=0.3

sakura「你好，欢迎使用 Stella！」
sakura「这是一个最小的示例。」

@stage sakura remove transition=fade duration=0.3
@bg bg_black fade 1.0
```

### Step 3 — 创建配置文件

创建 `stella.cfg`：

```ini
[game]
title = "我的视觉小说"
scenario = "res://scenarios/demo.stla"
```

如果你的目录结构遵循默认约定（`art/backgrounds/`、`art/characters/` 等），只需要这两行配置。

完整配置示例：

```ini
[game]
title = "我的视觉小说"
scenario = "res://scenarios/main.stla"

[paths]
backgrounds = "res://art/backgrounds/"
characters = "res://art/characters/"
stage = "res://art/stage/"
bgm = "res://audio/bgm/"
se = "res://audio/se/"
voice = "res://audio/voice/"
voice_dsp = "res://audio/voice_dsp/"
presentation_clips = "res://presentation/clips/"
movies = "res://video/movies/"

[presentation_clips]
resource_budget_bytes = 536870912
max_viewport_pixels = 8294400
audio_choice_seed = 0

[features]
cg_gallery = false
backlog = true
save_slots = 8

[settings]
schema = "res://settings/project_settings.json"

[overrides]
title_scene = "res://scenes/my_title.tscn"
game_scene = "res://scenes/my_game.tscn"
settings_scene = ""
save_load_scene = ""
backlog_scene = ""
```

`save_slots` 的合法范围是 `1..100`，超出范围会和其他 schema 错误一样原子拒绝整个来源。`backlog` 会控制内置对话工具栏和 Backlog overlay；`cg_gallery` 控制 `StellaRuntime` 的 CG 解锁/查询 Facade：关闭时不记录新 CG，查询也不暴露已有进度，但底层存档 provider 仍保留旧进度，重新启用后可继续使用。框架尚未提供内置 Gallery UI，宿主项目可用下文的 Facade 构建界面。

#### 分层配置与本地覆盖

将可公开、可复现的项目配置提交到受版本控制的 `stella.cfg`（tracked），只把当前开发者或当前机器需要的覆盖写入已被 Git 忽略的 `stella.local.cfg`（ignored）。

Stella 插件或 Release zip 不会修改宿主仓库的 `.gitignore`；每个宿主项目必须自行加入根目录规则 `/stella.local.cfg`。提交前可用下面的命令同时验证 ignore 已生效且文件未被跟踪：

```bash
git check-ignore --quiet -- stella.local.cfg && \
  ! git ls-files --error-unmatch stella.local.cfg >/dev/null 2>&1
```

例如，仓库中提交的基础配置可以是：

```ini
; stella.cfg（提交到仓库）
[game]
title = "Starfall"
scenario = "res://scenarios/main.stla"

[paths]
voice = "res://audio/voice/"
voice_dsp = "res://audio/voice_dsp/"

[overrides]
game_scene = "res://scenes/game.tscn"
```

本机覆盖可以使用相同结构；以下 synthetic 路径仅作示例，不对应任何私有内容：

```ini
; stella.local.cfg（不要提交）
[game]
scenario = "res://private_preview/scenarios/preview.stla"

[paths]
voice = "res://private_preview/audio/voice/"
voice_dsp = "res://private_preview/audio/voice_dsp/"

[overrides]
game_scene = "res://private_preview/ui/preview_game.tscn"
```

配置按 key 独立解析，优先级为“内置默认值 < `stella.cfg` < `stella.local.cfg`”。这套规则一致覆盖 `[game]`、`[paths]`、`[features]`、`[settings]`、`[system_se]` 和 `[overrides]`；后一个文件只覆盖其中明确写出的 key，例如上面的本地文件不会改变基础配置中的 `game.title`。

配置语法使用 Stella schema 所需的常用子集：文件必须是 UTF-8 且不能含 NUL 字节；字符串必须用双引号包围，布尔值写作 `true` / `false`，整数使用十进制。完整行和行尾注释都使用分号 `;`；`#` 不属于 Stella 注释语法，出现在完成的 section header 或赋值后会使整个来源被拒绝。字符串转义兼容 Godot 4.6 `ConfigFile`，包括 `\\`、`\"`、`\n`、`\uXXXX`、`\UXXXXXX` 及 UTF-16 surrogate pair；未知转义也沿用其“去掉反斜杠、保留后一字符”的行为。显式写入空字符串也是一次有效覆盖。单个来源最多 1 MiB，单个 quoted String 的原始 UTF-8 表示最多 256 KiB；超限、NUL 和非法 UTF-8 都会按无部分提交的错误处理。

两个文件都是可选来源：缺失的文件不会报错，也不会清空较低优先级已经解析出的值。每个存在的来源会先完成读取和 schema 校验，再一次性提交；类型错误、未知 section/key 或语法损坏都会原子拒绝整个来源，该来源不会部分生效，也不会出现在已应用来源列表中。基础配置失败时保留默认值并停止继续叠加，本地覆盖失败时则完整保留已经生效的基础配置。语法错误诊断会带来源路径、安全的行列位置和预期修复提示；schema 错误会指出相关 section/key，类型错误还会带预期类型，且二者都不会打印配置值。

兼容边界：`StellaConfig.SCHEMA_VERSION == 2` 标识分层配置与严格 closed schema 的迁移边界。v2 继续兼容上面的 Godot 4.6 标量值和字符串转义，但未知 section/key 不再像 v1 的直接 `ConfigFile` 加载器那样静默忽略。这是有意的校验收紧；“只使用基础文件”仅保证已声明 Stella key 的值保持原有语义，并不继续接受旧的自定义键。升级到 v2 前请把宿主自定义元数据移出 `stella.cfg` / `stella.local.cfg`，或改用 Stella 已声明的 section/key。

Runtime 每次解析后都会完整应用 resolved snapshot，包括没有配置文件时的内置默认值。因此删除或禁用配置来源并重新初始化时，Runtime 不会继续保留上一轮的本地路径或其他覆盖。

可用 Facade 查询本次启动实际提交的来源，返回顺序也就是应用顺序：

```gdscript
var sources: PackedStringArray = StellaRuntime.get_applied_config_sources()
# 典型结果：["res://stella.cfg", "res://stella.local.cfg"]
```

自动化、CI 或一次性诊断应显式禁用本地层和启动时隐式读取的
`user://settings.json`，避免当前机器状态污染结果：

```bash
STELLA_DISABLE_LOCAL_CONFIG=1 STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD=1 \
  godot --audio-driver Dummy --headless --path /path/to/project --quit
```

前者只跳过启动时隐式加载的本地文件，后者只跳过启动时隐式加载设置；测试代码显式传入的 synthetic 配置/设置路径和显式 `load_settings()` / `save_settings()` 仍可验证同一 production contract。

发布公共构建时，请在每个 Godot Export Preset 的资源过滤规则中显式包含 `stella.cfg`，并显式排除 `stella.local.cfg` 以及实际存放私有或生成内容的目录（例如上面的 `private_preview/`）。`.gitignore` 只控制 Git 是否跟踪文件，**不会**阻止 Godot 将它打包进导出产物。

Godot 无法从字符串形式的动态路径自动发现 `[overrides]` 中的场景依赖和 `[settings] schema` 引用的 JSON。使用 **Export All Resources** 时应确认这些资源没有被 exclude filter 排除；使用 **Export Selected Scenes/Resources** 时，必须把 settings schema 以及配置引用的 `title_scene`、`game_scene`、`settings_scene`、`save_load_scene`、`backlog_scene` 和 `flowchart_scene` 全部加入导出资源集。无效或遗漏的自定义标题会回退内置标题，但遗漏 settings schema、game/overlay 会让对应功能不可用并产生带路径的诊断。

导出后应从源码目录外启动 PCK 或发布包并走一遍标题、开始游戏及各 overlay，而不只检查导出命令的退出码。仓库维护者可在安装 Godot 4.6.1 后运行标准 smoke；脚本会拒绝覆盖已有 `export_presets.cfg` 或 `stella.local.cfg`，创建一个必须被 export exclude filter 剔除的 synthetic local poison，临时使用 CI fixture，并验证三种 PCK 都看不到该文件，同时覆盖 Binary Tokens、Compressed Binary Tokens 及 Selected Scenes fallback 的真实配置 consumer：

```bash
GODOT_BIN=godot tests/pck_smoke/run_export_smoke.sh
```

`stella.local.cfg` 只是方便开发的覆盖层，不是 secrets vault：它既不加密，也不保证不会被误导出、备份或读取。不要在其中存放 API token、密码或其他凭据；凭据应通过环境变量或专用密钥管理服务提供。

### Step 4 — 搭建游戏场景

参考 `examples/demo/` 的结构搭建自己的标题场景和游戏场景，然后在 `stella.cfg` 的 `[overrides]` 中指向它们。

使用插件提供的默认 bootstrap 入口时，`[overrides].title_scene` 同时控制首次启动进入的标题场景和之后的返回标题行为；启动配置会在场景重定向和 Presenter 消费配置前完成解析与应用。所有配置场景的脚本、嵌套场景和其他外部依赖必须全部随构建存在，依赖声明类型（包括 custom `script_class` Resource）必须与实际可加载资源兼容，且节点脚本的原生基类必须与节点类型兼容；title 失败会原子回退内置标题，game/overlay 失败则保持当前有效场景和状态。安全预检也会拒绝未声明的 ExtResource/SubResource ID、非法序列化构造器，以及不符合 Godot `.tscn`/`.tres` 格式的未知、乱序或缺少必填字段的 tag，不把错误值交给可能回显原文的 Godot parser；单个资源 tag 最多 512 KiB，单个 quoted tag attribute 最多 256 KiB。`return_to_title()` 可以从场景根 `_ready()` 调用；它会延迟切换，并在实际 `scene_changed` 确认后才清理游戏状态。其他游戏导航同样会在取得导航所有权前校验场景、剧本，以及存档中的 scenario/scene/command 边界和各内置 provider 字段类型；失败调用不会销毁当前有效运行状态。配置场景路径可使用 Godot UID，Runtime 会在请求和确认前统一解析到当前 canonical resource path。

安全预检还会在调用 Godot resource parser 前拒绝非法 attribute key、未知或错误基类的 node/sub-resource type，以及 effective inherited/nested tree 中不存在的 parent、owner、connection endpoint 或 editable path。quoted tag attribute 与 Variant String 使用同一套 Godot 4.6 转义语义，包括 `\u` / `\U`、引号和反斜杠。resource ID 按 Godot 4.6 numeric Variant 语义解析：numeric token 先转换为 Godot 的 canonical String，quoted ID 保留 decoded 原文并进入同一 key 域。因此 signed、int64 边界外、decimal、exponent、有限值格式化和浮点溢出的 `inf` / `-inf` 都能与同值 canonical quoted ID 匹配，而 `"01"` 等文本 ID 仍与数字 `1` 分离；`id=""` 是合法的 quoted ID，缺少 token 的 unquoted 空 ID 仍非法。Godot tokenizer 不接受的前导 `+` 和 hex 继续拒绝。format 2/3 的现有数字 ID 场景无需迁移。文本 nested scene、binary `.scn` 和导出 remap 都按真实 SceneState 验证 property-only child override；重复实例会在一次预检事务内按 canonical path + expected type 复用结果，不会无条件展开整棵 effective tree。

游戏场景中使用插件的 Presenter 脚本（`BackgroundPresenter`、`StagePresenter` 等），通过 `StellaRuntime` 的 Facade API 控制游戏流程。`BackgroundPresenter` 独立管理 `@bg` 基础背景；人物、前景、事件图和其他可变换图片统一放在动态 `StageLayer` 中。StageLayer 按稳定 ID 创建任意数量的图片层，不预建位置槽。

如果自定义游戏场景需要支持 `@effect shake`，请在每个需要震动的舞台 `CanvasLayer` 下添加一个专用的全屏 `Control` 根节点（建议命名为 `ShakeRoot`，Full Rect、Mouse Filter Ignore），把该层的可见内容放到根节点下，再将根节点路径写入 `ScreenEffects.shake_target_paths`。使用全屏 `Control` 可确保子 Control 的 anchors 仍以视口尺寸布局；普通 `Node2D` 目标也受支持，但不适合作为锚点 UI 的父节点。路径相对 `ScreenEffects` 解析；内置默认值为 `../BackgroundLayer/ShakeRoot` 和 `../StageLayer/ShakeRoot`。`ScreenEffects` 在特效期间独占这些根节点的 `position`；镜头移动、平移等系统应使用外层 `CanvasLayer.offset` 或其他子节点，这样它们可以与 shake 安全叠加。不要把 UI 根节点列入目标，便可让对话框保持静止。

为避免恰好等于视口大小的背景在位移时露出清屏色，还应把背景的 `ShakeRoot` 同时写入 `shake_coverage_target_paths`。该目标必须是宽高至少 1 px 的有限尺寸、单位缩放、零旋转的 `Control`；运行时只在 shake 期间围绕中心按强度增加必要的 overscan，窗口尺寸变化时会同步重算，并在结束或取消时恢复原始 scale 与 pivot。舞台根不要加入 coverage 列表，因此人物比例和 anchor 不会改变。`Node2D` 目标或未配置 coverage 的自定义场景仍可震动，但需要项目自己提供足够的背景出血区。

`@effect flash` 的绘制宿主由 `ScreenEffects.flash_canvas_path` 指定。推荐像内置场景一样，创建一个独立且 `layer` 严格高于场景内所有 UI（包括项目自定义 UI）的 `CanvasLayer`，再将其路径填入该属性；`ScreenEffects` 不会修改外部宿主的层级。宿主必须位于场景树中，退出场景树时其活动 flash 会被同步取消。宿主层应使用唯一的最高层级，因为同一 CanvasLayer 层级的跨层绘制顺序不应作为遮盖保证。若路径留空，`ScreenEffects` 会创建私有 CanvasLayer，并使用可配置的 `flash_canvas_layer`（默认 100）。

```text
Game
├── BackgroundLayer (CanvasLayer)
│   └── ShakeRoot (Control，Full Rect)
│       ├── BgFront
│       └── BgBack
├── StageLayer (CanvasLayer + StagePresenter)
│   └── ShakeRoot (Control，Full Rect)
│       └── Layer_*（运行时按稳定 ID 动态创建）
├── UILayer (CanvasLayer)
└── ScreenEffects
    └── FlashCanvas (CanvasLayer，最高 layer)
```

内置场景的 `ScreenEffects` 将 `BackgroundLayer/ShakeRoot` 同时配置为 shake target 和 coverage target，将 `StageLayer/ShakeRoot` 只配置为 shake target。

如果不搭建自己的场景，引擎会使用内置的默认场景。

#### 声明式配置 ADV / NVL / overlay 对话布局

普通项目直接在 STLA 中声明并选择命名 Profile，不需要打开 Godot 场景：

```stla
@dialogue_profile novel panel_anchors=0,0,1,1 panel_offsets=0,0,0,0
@dialogue_profile novel text_anchors=0.15,0.1,0.85,0.7 text_margins=20,20,20,20
@dialogue_profile novel horizontal_alignment=left line_spacing=8
@dialogue_profile novel background_visible=true background_modulate=#ffffff00
@dialogue_profile novel show=quick_menu
@dialogue_profile novel entry_prefix="・" entry_separator=""
@dialogue_profile novel advance_indicator_texture="res://ui/dialogue/wait.svg"
@dialogue_profile novel advance_indicator_offset=8,-2 advance_indicator_animation=bob
@dialogue_profile message panel_anchors=0,0.72,1,1

@chapter prologue "序章"
@scene start
@adv profile=message
@nvl profile=novel
「第一行。」
「第二行。」
@nvl off
「这里已经恢复 ADV。」
```

上例的两条 NVL 记录会累积显示为 `・第一行。・第二行。`。`entry_prefix` 放在角色名和正文之前，`entry_separator` 只放在相邻记录之间；两者只影响 NVL 的屏幕排版，不会进入 Backlog。Backlog 保存正文的玩家可见纯文本：BBCode 格式与 expression/effect marker 会被剥离，段落和列表转换为普通换行、项目符号或序号，所以默认 Backlog 场景的普通 Button 不会露出 `[b]` / `[ul]` 等标签。省略 entry format 时使用内置兼容默认值：空前缀和换行分隔。`@combine` 块始终算一条记录，只添加一次前缀。字符串可使用 `\\`、`\"`、`\n`、`\r`、`\t` 转义，例如 `entry_separator="\n\n"` 可留出空行；它们仅支持纯文本，BBCode 方括号会产生诊断。

示例中的 wait 图片会在一条对话完整显示后跟随实际换行后的文字端点，并在下一条开始打字或玩家推进时隐藏。也可以用 `advance_indicator_scene="res://ui/dialogue/wait_indicator.tscn"` 提供根节点为 `CanvasItem` 的自定义场景；其中 `Control` 根需使用左上角锚点并明确尺寸。texture 与 scene 二选一。`advance_indicator_offset=x,y` 调整像素位置，`advance_indicator_animation` 支持 `none`、`pulse`、`bob`。这套能力同样适用于 ADV 和 overlay；NVL 每累积一条记录都会移到最新端点。标记不会进入文字、Backlog 或存档，未配置时不会创建任何标记节点。内置定位直接读取 Godot 的实际 glyph 排版，因此支持段落对齐、`[indent]`、`[ul]` / `[ol]`、混合 RTL 和滚动条占宽，无需项目自定义定位；用于探测的透明排版镜像不会改变正文的选择、打字进度或滚动位置。纯文本 NVL 会在同一个镜像中只追加新条目，避免每条记录重新解析整页；含 BBCode、自定义效果或布局变化时则重新建立引擎排版，保证语义正确。`[wave]`、`[shake]` 与自定义时间相关 `RichTextEffect` 的端点采用 ready 时的稳定快照，不会让 marker 每帧抖动；下一次文本、尺寸、主题或滚动触发的定位会重新采样当时的最终 glyph transform。

完整属性表和诊断规则见 [DSL.md](DSL.md#33-对话框模式切换)。内置场景已经提供可定位文字区域、`DialogueBg` 和 `quick_menu` 分组，常规 ADV、透明 NVL、书信、独白等版式都能只用 STLA 完成。Presenter 在就绪时保存 ADV 基线；配置过 `@adv profile=name` 时，`@nvl off` / `@overlay off` 恢复该 ADV Profile，否则恢复场景原始 ADV，并精确还原 panel、文字区域、文字样式、背景和分组 UI。

自定义 `DialoguePresenter` scene 还必须在 Inspector 中显式设置
`dialogue_background_path`，指向这个 Presenter 后代中真正绘制对话窗背景的
`Control`。例如背景节点名为 `DialogueBackdrop` 时，scene 属性应保存为：

```ini
dialogue_background_path = NodePath("DialogueBackdrop")
```

该路径同时归属 Profile 的背景布局/显隐/调制和
`GameSettings.text_window_opacity`；默认空值不会按节点名、group 或 scene-tree 扫描猜测。
空路径、失效路径或非 `Control` target 会给出带 scene resource 与 NodePath 的诊断，
并只禁用背景专属投影。请把正文、姓名、avatar 和 toolbar/Button 放在该背景节点之外；
设置只修改目标 Control 自己的 `self_modulate`，不会继承到这些 UI。最终背景 alpha 为
Theme/style alpha、Profile/场景 `modulate.a`、场景 authored `self_modulate.a` 与
`text_window_opacity` 的乘积；因此值 `1` 保留场景/Profile 透明度，`0` 只让背景完全透明，
反复在 ADV/NVL/overlay 间切换也不会重复相乘。内置场景与 demo 已声明该 binding。

只有项目加入自定义 frame、logo 等专属 UI 时，才需要在 Godot 的 Node > Groups 中给节点增加语义分组，并在 STLA 的 `show` / `hide` 中引用。极少数需要程序动态注入样式的项目仍可在 Inspector 中使用 `DialoguePresentationProfile` / `DialogueModeProfile` Resource，或调用 `DialoguePresenter.set_presentation_profile()`；这是高级兜底接口，不是常规创作流程。

完全不写 `@dialogue_profile` 时，`@nvl` / `@overlay` 使用内置兼容布局，旧项目不需要迁移。离开 NVL 后，下一次进入会开始新的累积文本；这一规则也适用于 `@jump` 循环、重复 `@call` 和条件分支的实际执行路径。不同分支可以保留不同 Profile 到共同 continuation；若希望汇合后统一布局，再显式写一次模式选择。未离开 NVL 时重复 `@nvl` 不会另起一页。存档记录当前与 ADV 的 Profile 名称、声明式选择状态，以及当前 NVL 页每条记录的 Profile 名、原始角色/segment 输入；读档或 Backlog 回退后从当前剧本的 Profile registry 逐条重建页面，所以同一页中途换 Profile 不会改写更早记录的 prefix/separator。存档不保存已解析 Profile、诊断 provenance 或渲染后的 `RichTextLabel.text`。

### Step 5 — 运行

按 F5 运行。

---

## Facade API

`StellaRuntime` 提供简洁的 API，用户搭建自己的 UI 时只需要调用这些方法：

### 自定义对话 consumer / handler 迁移

Canonical 对话事件是 `SignalBus.dialogue_requested(request)`。自定义 UI 或无界面 runner 完成显示后，应确认收到的**同一个** request；不要用旧的全局 `advance_requested` 作为剧情确认：

```gdscript
func _ready() -> void:
	SignalBus.dialogue_requested.connect(_on_dialogue_requested)

func _on_dialogue_requested(request: DialogueRequest) -> void:
	# 渲染 request.get_segments()；玩家推进时：
	request.advance()
	# 若该次显示被关闭/取消，则改用 request.abort()
```

`advance()` / `abort()` 只有第一次调用成功，迟到的另一结果返回 `false`，也不能影响替换后的 request。正常 `advance()` 会先由 Core 验证 owner 并提交已读，再广播兼容通知；`abort()` 会取消当前 scenario context，不会跳过当前行继续执行下一条。自定义 Presenter 只能保留一个可见 owner；若 typed request 被另一条 typed/raw SHOW 替换，或 hard hide/场景退出令它不可达，必须在丢失引用前调用旧 request 的 `abort()`。`show_dialogue(character, segments, mode)` 与 `advance_requested()` 仍会作为扩展兼容通知发出，但不拥有 DialogueHandler 的命令完成权；没有 pending 对话时，内置输入会用旧 advance 通知解除 `@wait click` 或带 `skippable=true` 的定时 wait。

直接组装 `CommandRegistry` 的扩展需把同一个已读管理器注入 handler：

```gdscript
var read_flags := ReadFlagManager.new()
registry.register(DialogueHandler.new(read_flags))
```

`DialogueHandler.new()` 的无参数形式不再可用；内置 `StellaRuntime` 已在 composition root 统一完成注入，并会在测试/session reset 替换 read manager 时重建注册。

扩展若直接调用 `ReadFlagManager.mark_read()` / `mark_dialogue_read()`，command UID 必须是 `0` 到 `2^53 - 1` 范围内的整数。写入与存档恢复使用同一校验；非法 UID 会立即拒绝，不会制造一份可以 capture 却无法 JSON restore 的已读状态。

### 游戏流程

```gdscript
StellaRuntime.start_game()           # 开始新游戏
StellaRuntime.load_game(slot_id)     # 读档并进入游戏
StellaRuntime.return_to_title()      # 返回标题
StellaRuntime.request_quit()         # 安全退休音频后退出
```

自定义标题、性能模式或其他宿主退出入口必须调用 `request_quit(exit_code=0)`，不要直接 `get_tree().quit()`。该 API 与内置标题、`StellaAction.QUIT` 和 OS close 共用同一个幂等边界：OS close 先自动存档，唯一 AudioPresenter 再退休 BGM/loop-SE/Voice/SE，Runtime 观察真实 AudioServer mix 回绕并给主线程一次 cleanup boundary 后退出。ack、driver 或 timing 非法及有界等待耗尽会以非零状态 fail-close。Godot 4.6.1 的 raw `--quit-after` 存在上游 audio-driver teardown 顺序限制（godotengine/godot#76745 / #122742），不能用于验证 active-audio 的产品 clean shutdown。

#### 场景回想 / Gallery 播放

Gallery controller 以一个明确的零参数 continuation 启动同一份 STLA：

```gdscript
# GalleryController 建议是 Autoload 或其他不会随 game scene 被释放的 owner。
func play_memory() -> void:
	var entered := await StellaRuntime.start_recollection(
		"res://story/memory_001.stla",
		Callable(self, "_on_memory_returned"),
	)
	if not entered:
		push_error("cannot enter memory playback")

func _on_memory_returned() -> void:
	# Runtime 已完整退休旧 engine/presentation owner；这里可安全打开下一段
	# recollection、开始 normal story，或返回标题/Gallery。
	show_gallery()

func _on_gallery_return_button_pressed() -> void:
	StellaRuntime.return_from_recollection()
```

`start_recollection(scenario_path, return_continuation, game_scene_path="") -> bool` 在切换场景前解析剧本、预检 game scene，并要求 continuation 在入口时有效且恰好零参数。continuation 不得绑定在即将被替换的 Gallery scene node 上；请使用持久 controller/autoload，或显式保证 owner 生命周期。Runtime 不序列化 Callable，也不根据 scene path 猜返回目标。

`@recollection_exit` 与剧本自然耗尽都会走和 `return_from_recollection()` 相同的 exact-once 终点：先退休 ScenarioEngine generation、Choice/Director、Stage、presentation clip、chapter、dialogue、BGM/loop-SE 与 canonical state，停止 Auto/Skip，再调用 continuation。若 target 在成功入口后失效，Runtime 仍先完成清理，然后用触发命令的 `source_path:line`（自然结束为 `:end`）报错并拒绝回调；不会留下半活回想。continuation 在 callback 中重入 normal story、另一个 recollection 或 title 是安全的，旧 return 没有能取消新 owner 的尾部工作。

回想播放期间 Backlog 仍可只读查看，Auto/Skip 保持普通播放语义；实际正常推进完成的 Dialogue 仍以同一 source identity/command UID 记录为已读。manual/quick/auto save 与 Backlog、Choice、流程图 rollback/jump 都 fail-close，因为 continuation 不是可持久化状态。return cleanup 不回滚 monotonic read flags 或 UnlockManager；入口/退出也不会自动猜测某个 scene/CG 的解锁，Gallery controller 应用稳定业务 ID 显式管理解锁。任一显式 normal load/start/title replacement（fresh restart 也属于 normal start）都会取消旧回想 continuation，不会在新 owner 后重新打开旧 Gallery。公开示例见 [`examples/demo/scenarios/recollection_playback.stla`](../examples/demo/scenarios/recollection_playback.stla)。

### 当前章节标题与可见目标

当前章节身份来自正在执行的 scene cursor，标题已通过 `TranslationServer` 解析。项目 UI 只需使用三个稳定 Facade getter 和一个公开通知：

```gdscript
var chapter_id := StellaRuntime.get_current_chapter_id()
var title := StellaRuntime.get_current_chapter_title()
var authored_visible := StellaRuntime.is_chapter_indicator_visible()

SignalBus.current_chapter_changed.connect(
	func(new_id: String, new_title: String) -> void:
		# 同一 chapter 在 locale 切换后也会重新通知。
		pass
)
```

`is_chapter_indicator_visible()` 返回 `ScenarioContext` 中的 authored target，不是某个 Control 当下的 alpha；导航尚未成功替换 context 时，它仍报告可供 autosave 的旧目标。`@chapter_indicator` 的 fade 会等待该次验证通过的全部 Presenter，零 Presenter 则同步完成。完整 apply tail 全部 accept 后才提交 target，因此 apply 回调内同步存档仍保存旧值，进入 fade 后的存档保存新值；读档、Backlog/流程图回退和 restart 会先 cut 恢复目标，再从同一 cursor 重新执行完整 typed validation/apply。此时已在目标上的 Presenter 以 no-work 同步确认，不创建或重播旧 Tween。

默认场景挂有 `ChapterIndicatorPresenter`，自定义 game scene 也可以把同一脚本挂到任意项目自有 `Control`，只需提供一个 `Label` 的 `NodePath`：

```gdscript
# ProjectChapterBadge.gd/scene setup
var badge := PanelContainer.new()
badge.set_script(load(
	"res://addons/stella/presentation/ui/chapter_indicator_presenter.gd"))
var title_label := Label.new()
title_label.name = "Title"
badge.add_child(title_label)
badge.set("title_label_path", NodePath("Title"))
```

Presenter 只管理标题文本、可见性和本次转场，不改写项目的 anchors、offset、minimum size、theme 或装饰节点。多个合法 Presenter 会加入同一 barrier；任何 binding 在 validation/apply 间失效都会让整条命令 fail-closed，而不是留下部分 UI。运行中晚加入的 Presenter 只 cut 到 canonical 投影，不加入已经开始的 barrier；导航 reset 后、winning context 尚未投影前加入的节点保持隐藏。

裸 `@chapter id` 的标题回退到 ID；显式 `@chapter id ""` 保持空标题并阻止 badge 渲染，但不会篡改 authored visibility。标题字符串可直接作为翻译 key；locale 改变会刷新标题而不重启 scenario。章节更换本身不隐式 show/hide，必须由 DSL 明确控制。

### 动态命名舞台层

```gdscript
StellaRuntime.show_stage_layer("hero", {
	"kind": "character",
	"body": "stage:hero/body",
	"face": "stage:hero/smile",
	"position": [960.0, 1050.0],
	"origin": [500.0, 1000.0],
	"z_index": 10,
}, "fade", 0.3)

# 补丁只修改给出的字段，body 节点与纹理保持复用
StellaRuntime.update_stage_layer("hero", {
	"face": "stage:hero/sad",
	"redraw": [
		{
			"type": "color_overlay",
			"color": "#355c7d80",
			"blend": "soft_light",
		},
		{"type": "brightness_contrast", "brightness": 12, "contrast": -20},
		{"type": "grayscale", "amount": 0.4},
		{"type": "blur", "radius": [1, 1]},
		{"type": "blur", "radius": [2, 0]},
		{
			"type": "clip",
			"asset": "stage:hero/mask",
			"offset": [0.0, 0.0],
			"fit": "native",
		},
	],
}, "fade", 0.2)

# 投影型转场的 kind 与 typed params 分开传递；资源仍是 Stella logical ID
StellaRuntime.update_stage_layer(
	"hero",
	{"face": "stage:hero/surprised"},
	"rule",
	0.8,
	{"mask": "stage:masks/diagonal", "softness": 0.08, "invert": false},
)

StellaRuntime.hide_stage_layer("hero", "fade", 0.2)  # 保留节点和资源
StellaRuntime.remove_stage_layer("hero")             # 删除单层
StellaRuntime.clear_stage_layers()                    # 删除全部命名舞台层
```

多个操作可通过 `apply_stage_operations(operations, force_cut)` 同批提交。public Facade 的 canonical operation 必须显式提供 `action / id / properties / transition / transition_params / duration` 六字段；缺少或错误类型的 `transition_params` 会整批 fail-close，不存在五字段兼容分支。`show_stage_layer` 等 typed helper 的参数可省略，helper 会自行发出完整六字段 payload。布尔属性必须是真正的 `bool`，清空 `asset` / `body` / `face` 使用字符串 `"none"`，景深与旋转只使用 `depth_scale` / `rotation`。`rule` 的 typed params 为 `{mask, softness, invert}`，`mosaic` 为 `{cell}`；完整参数、logical mask ID、像素公式与预算规则见 DSL 文档。任何操作含非法字段、值、transition、transition_params 或 duration 时，整批都会被拒绝，不会部分派发。DSL 中 `transition=none` 只是作者层写法，parser 会把它 lowering 为 canonical `transition=cut`；programmatic Facade 不接受 `none`、大小写或前后空白变体。含 rule/mosaic/custom projection 的 Facade batch 即使 `force_cut=true` 也必须经过唯一 Director 与 Presenter provider/resource/viewport/budget preflight；true 只把有效目标同步 cut 投影为零 Tween/receipt，绝不退回 raw signal 或跳过缺失 mask/provider 诊断。所有人物与其他舞台图片都同步进入同一份 `PresentationState.stage_layers`；`hide` 的层仍在快照中，`remove` / `clear` 则会移除状态。

`redraw` 是有序的完整操作数组，而不是按类型合并的字典；更新它会原子替换整条管线，传 `[]` 会清空。支持 `color_overlay`、`brightness_contrast`、`grayscale`、`tint`、`blur` 和 `clip`；每条管线最多 16 个操作，其中最多 4 个 `blur`、1 个 `clip`。每个非零 `blur([x,y])` 都是独立 pass，对前一操作输出的 `[-x,+x] × [-y,+y]` 矩形窗口作完整等权 RGBA 平均；连续 blur 不会合并，`blur([0,0])` 则是保留在状态中的真正 no-op。`grayscale` 的 8-bit 目标灰度严格为 `(54 * R + 183 * G + 19 * B) >> 8`，再按 `amount` 与原色混合。`clip.asset` 继续使用 `background:` / `character:` / `stage:` / `res://` 或裸 stage 路径，并与普通纹理共享 `ResourceLoader` 缓存；快照只保存逻辑资源 ID，不保存 `Texture2D`。

含 blur 的层会使用离屏纹理。可查询渲染设备时，单轴尺寸上限取设备 2D 纹理上限与 8192 的较小值；无法查询时使用保守的 4096 上限。单层估算的离屏纹理总量上限为 256 MiB；静态投影每次最多 268,435,456 次纹理采样，连续投影每帧最多 67,108,864 次。超限时该层 fail-closed 为透明并报告错误，后续合法更新可恢复显示。只有动画纹理、源通道布局动画或交叉淡入确实逐帧改变离屏内容时才保持连续更新；隐藏层仍保留规范状态和已加载的源纹理，但会释放全部派生离屏目标，重新显示时按最新纹理尺寸重建。动态源纹理或 clip 遮罩变尺寸时，Presenter 会重新计算 bounds、fit 与 clip 矩形。

Godot 4.6 的 redraw 像素管线使用 Forward+ 或 Mobile renderer。macOS 上如需使用 Compatibility renderer，请升级到 Godot 4.7 或更新版本，以避开 4.6 的 CanvasGroup screen-backbuffer 缺陷。

### 声明式对话界面显隐

普通剧本直接使用最短的 standalone 写法，不需要 presentation batch：

```stla
@dialogue_visibility hide
@dialogue_visibility show
```

省略 target 会规范化为 `surface`。只有独立控制快捷菜单时才显式写
`quick_menu`；淡入淡出也是可选的高级参数：

```stla
@dialogue_visibility quick_menu hide
@dialogue_visibility show transition=fade duration=0.3
```

显式 `surface` 仍属于同一套可选 target grammar，并与省略形式生成相同的
canonical payload。精确语法和 fail-close 规则见 [DSL 文档](DSL.md#35a-dialogue-visibility)。

### 可寻址对话头像

对话 surface 需要在台词边界之外预置或切换头像时，使用固定
`dialogue:avatar` channel：

```stla
@dialogue_avatar set character=hero expression=neutral visible=false position=-280,-140 scale=0.45,0.45
@dialogue_avatar show transition=fade duration=0.3
@dialogue_avatar set expression=smile
@dialogue_avatar hide
```

也可直接使用 `asset=<logical-id>`；它与 `character` / `expression` source 互斥。
`set visible=false` 会建立可存档、可恢复但隐藏的稳定状态，不会延迟到下一句。
位置、原点、缩放、旋转、层级与透明度只使用 Stella canonical property；源格式字段必须由
importer 在有确定证据时翻译，否则保留原 source line fail-close。内部 Sprite、outgoing
crossfade 与 receipt 都由内建 DialoguePresenter 管理，项目不应操作 UI node 或创建第二条
scheduler。完整语法见 [DSL 文档](DSL.md#35b-addressable-dialogue-avatar)。
`position` / `origin` 是 avatar-container 本地画布中的有符号像素，`origin` 从源纹理左上角
计量并映射为负 offset；`scale` 无单位，`rotation` 使用弧度。Importer 必须先解码源格式的
无符号、定点或角度编码，不能把 raw 数字直接塞入 Stella DSL。
可运行且由 CI 实际解析的公开 synthetic 示例位于
[`examples/demo/scenarios/dialogue_avatar.stla`](../examples/demo/scenarios/dialogue_avatar.stla)。

### 声明式 presentation clip

普通作者只选择一个 logical definition；时间线、命名状态 cue、system audio cue、UI 抑制和
转场都保存在可复用的 `PresentationClipDefinition` 中，不展开成一长串 DSL 参数：

```stla
@presentation_clip ui/eyecatch
@presentation_clip ui/eyecatch policy=fire_and_forget
```

默认 `policy=join`，仅另接受 `fire_and_forget`。definition 从
`[paths] presentation_clips`（默认 `res://presentation/clips/`）下以 logical ID 解析为
`.tres`，并引用纯数据 `.tscn`。首次 Resource load 前的文本/依赖门先拒绝 script 与 binary
依赖；dependency 与 SceneState walk 都有显式 depth/work 上限。随后 isolated definition 的
SceneState 在 instantiate 前按 nested instance multiplicity 封顶 512 nodes，并与 detached
instance 的 exact node count 一致；两道门还会在入树前拒绝 autoplay、
音视频 node、独立 Timer/AnimationTree/AnimatedTexture、nested render surface/3D owner 与
`TIME` shader。可见变化只由一个 bounded main `AnimationPlayer` clock 和 authored-order cue
数组驱动。state cue
的 named animation 使用 main position 确定性 seek，不自行播放第二时钟；system audio 仍由
唯一 AudioPresenter typed ownership 预检并播放。

单 asset system audio 继续使用最短 `PresentationClipAudioCue`。需要随机选择时只在
definition 内加入 `PresentationClipAudioChoiceCue`；scenario 仍是同一行
`@presentation_clip logical-id`。choice 只支持明确的 uniform policy 与
allow-repeat/no-repeat policy。ordered candidate 只有 stable ID、logical asset、authored enabled、
可选 authoritative character binding 和 source provenance；没有项目 callback、source alias、
candidate volume 或 weight。空 character 使用 master/system-SE 设置，非空 character 使用
master/voice/character enabled+volume 设置。volume=0 仍会照常选择并启动静音 player，因此调整
音量不会改变内容/RNG 序列；cue 到点前 character 被禁用时该已选 cue no-op，之后不会补播或重选。

所有 candidates（每 cue 最多 32、每 definition 累计最多 256）都先 detached-preflight，disabled
也不能隐藏坏资源。whole visual/dialogue/audio quorum 可发布后，单一 Runtime-owned RNG authority
才按 authored cue order 抽取；每个有 eligible candidate 的 choice exact 消耗一个值，即使只有
一项；0 eligible 不消耗也不创建 player。no-repeat 只记录同 logical definition + cue ordinal 的
last candidate ID。Skip/cancel/stale apply 在 publish 前不推进 RNG，publish 后 cue 只读取封存选择。

需要粒子时也不增加 scenario 参数：在同一个 definition 的 `particle_layers` 中选择 typed
`PresentationClipParticleLayer` 即可。`rate` 每次在 authored
`1/spawn_rate_min..1/spawn_rate_max` interval endpoints 间重新采样，
`burst` 保留一次性 count min/max；stable seed + layer/spawn/channel ordinal 让任意 seek 都得到
相同 spawn order。unscaled local `offset_motion_keys` 与乘一个共享随机 scalar 的
`scaled_motion_keys` 相加（都为 logical-pixel Vector2 curve，不会拆 x/y 改变方向）；纹理与
mask 各自显式选择 nearest/linear，mask 为 alpha/inverse-alpha，blend 为
mix/add/sub/mul。粒子 lifetime、spawn window、projection bounds、texture/mask 与 maximum-live
pool 都在 publish 前验证和预算。项目 scene 中的 GPUParticles/CPUParticles 仍严格拒绝；作者
不需要、也不能用第二 scheduler 或 wall-clock 粒子 node 绕过 main timeline。粒子纹理也只
接受static imported/Image与递归static Atlas/Canvas；render-target、camera/RD、animated、noise
或external texture不能作为看似data-only的隐式live owner。
每层还必须选择 closed `teardown_policy=fully_contained|cut`（默认
`fully_contained`）。普通粒子要在 bounded main 结束前自然耗尽；只有源对象确实在 clip teardown
截断仍存活实例时才用 `cut`。所有 spawn 仍必须位于 bounded main；cut 会保留原 emission window 与 lifetime，在 main 结束时由同一个
Presenter 同步归零 fixed pool；之后的 Skip、cancel、replacement、load/rollback、restart 和 scene
replacement 复用同一幂等清理，旧 projection 不能复活。它是 definition resource 字段，不会扩大
`@presentation_clip` 的 scenario grammar。

`logical_viewport_size` 与 `fit_mode=contain|cover|stretch` 明确坐标空间；resource cap 和
viewport cap 在 `[presentation_clips] resource_budget_bytes` / `max_viewport_pixels` 配置，
默认分别为 512 MiB 与 3840×2160 pixels。texture、显式 clip SubViewport surface、封存的
under snapshot surface、sealed particle packed event/curve work 与 fixed MultiMesh pool 都在
任何 UI、audio、scene mutation 前预算；失败会报告 scenario
`source_path:line`、definition path 和
对应的 cue 或 particle-layer ordinal/provenance 与 offending field。`cut` / exact `turn`、
Skip、cancel、replacement、load/rollback/
restart/return-to-title/scene replacement 都走同一 Runtime-owned Director quorum。项目无需也
不应添加专用 Presenter、源格式 alias、预烘帧/video 或 wall-clock timer。
CI 会通过公开 synthetic scene/audio definition 实际解析并运行
[`tests/fixtures/scenarios/presentation_clip/lifecycle.stla`](../tests/fixtures/scenarios/presentation_clip/lifecycle.stla)，
该 fixture 不依赖任何私有来源、名称或素材。

`[presentation_clips] audio_choice_seed` 接受 `0..2147483646`。默认 0 在每个 fresh new-game /
scenario restart 用 OS entropy 初始化一次；测试和需要完全可重现内容的项目可写固定非零 seed。
return-to-title 在 autosave 后清成 unstarted，不提前抽 entropy；load/rollback 恢复 current
`presentation_clip_audio_choice` provider 的 version、initial seed、state 与 last-choice map。
当前 manual/quick/auto/rollback snapshot 缺失或损坏该 provider 会在 scene/provider mutation 前
fail-close，不从 config seed 猜测或保留 live state。clip whole-quorum complete 前的 tentative
choice 不会被同步 save 捕获；Backlog、previous-choice、flowchart 也会先验证 provider，再移动
cursor/history/path。load 后未访问 chapter 的 initial checkpoint 使用存档 initial seed 重建，绝不
采用 load 过程中临时 fresh entropy。

### Native movie

项目先把可发布的视频离线转为 Godot 4.6 原生 Ogg Theora/Vorbis `.ogv`，放在 `[paths] movies` 根目录，以 logical ID 引用：

```stla
@movie opening
@movie copyright skippable=false
@movie ambience loop=true policy=fire_and_forget
@movie stop
```

普通播放默认非循环、可跳过且 JOIN，因此最常见写法没有附加参数。`skippable=false` 会消费 story input 但不结束电影；右键和 persistent Skip 是否结束可跳过电影分别由 `movie_right_click_skip`（默认 true）与 `movie_skip_on_skip`（默认 false）设置决定，普通 advance 可跳是 Stella 的产品默认。Presenter 不自行监听 raw input。

电影占用固定 full-screen media layer 90，screen flash 为 100；它与 presentation clip 互斥，双方在资源加载和 receipt 之前拒绝冲突。音量只计算一次 `master_volume * movie_volume`。活动电影 snapshot 保存真实 native cursor；资源/长度改变、`position >= length`、native 已停止但 terminal 尚未提交、seek 失败或完成边界竞态均 fail-close，不会从零伪恢复。接近末尾但仍严格小于 length 的有效 cursor 可以精确恢复。Runtime-owned Presenter 跨 game scene 常驻；新 movie 替换旧 movie，title/new-game/shutdown 则 exact 退休资源与 receipt。

Stella 不内置 ffmpeg，不支持原作 MP4/WMV、帧序列、stage-background 或预渲染兼容。importer 应在构建阶段生成单个 `.ogv`，PCK/export 必须显式收集该 native resource。

### 清空当前对话页

普通作者只写零参数命令：

```stla
@dialogue_clear
```

它清空当前 ADV/overlay 内容或当前 NVL 累计页，但保留 mode、所选 profile、surface 与
quick-menu 显隐、Stage、音频和 backlog。它不是 `@dialogue_visibility hide`，也不是
`@nvl off`；下一行仍用原 mode/profile。页面已经为空时仍会正向执行。只有需要与其他
presentation child 共用原子 authored boundary 时才放入 batch：

```stla
@presentation_batch policy=join
  @dialogue_clear
  @dialogue_visibility hide transition=fade duration=0.25
@end
```

clear 只退休当前 dialogue-content 拥有的 typewriter/voice/inline cue callback，不会取消
独立 Stage transition。cleared 是版本化存档中的显式状态，读档、回滚、重启和场景替换
都不会让旧 callback 重新写回文本。公开 synthetic reference 是
[`examples/demo/scenarios/dialogue_clear.stla`](../examples/demo/scenarios/dialogue_clear.stla)。

### 持续命名 loop-SE

普通一次性音效仍只写 `@se asset`。需要跨对话、普通 scenario scene 变化或 AudioPresenter 重建持续播放的环境声时，以稳定 channel（而不是素材名）寻址：

```stla
@loop_se ambience play rain
@loop_se ambience play storm volume=0.7 fade=1.0
@loop_se ambience stop fade=1.0
```

standalone 默认 fire-and-forget，不需要 policy、transition、duration 或 position 参数。只在确实要等待淡变或与其他 presentation child 原子组合时，使用唯一 `@presentation_batch policy=join|fire_and_forget`：

```stla
@presentation_batch policy=join
  @loop_se ambience play rain fade=0.5
  @stage rain show asset=stage:rain transition=fade duration=0.5
@end
```

仓库中的 `examples/demo/scenarios/loop_se.stla` 使用 redistributable demo WAV，展示两个独立 channel、同素材音量过渡与 JOIN stop。

资源从 `[paths] se` 解析，只接受 OGG/WAV；格式 stream 会先 duplicate 再启用 loop，所以普通 one-shot 不受影响，并保留已有 OGG/WAV loop marker。same channel 的 asset+volume 相同是 no-op；只改 volume 保留 player/position；换 asset 才 crossfade，任意时刻最多一个 incoming 与一个 outgoing。缺失资源会在 mixed batch 的任何 child mutation 前按 authored line 拒绝整批。session/new-game/title reset 会清 channels；普通场景和 UI replacement 不会。

### BGM lifecycle 与 cue marker

BGM 只有一个 `bgm:main` channel。普通作者使用四条短 standalone 命令；默认立即执行并 fire-and-forget，动画必须显式写 `fade=`：

```stla
@bgm play theme
@bgm play evening cue=bridge volume=0.7 fade=1.0
@bgm play battle_stems mix=rhythm,bass:0.7
@bgm mix rhythm:0.4,bass,melody fade=0.8
@bgm pause fade=0.2
@bgm resume fade=0.2
@bgm stop fade=1.0
```

replacement 的 `fade` 是 outgoing 淡出与 incoming 淡入重叠的整个总时长。需要等待或 mixed 原子提交时，只复用现有 typed contract；每个 batch 最多一个 BGM child：

```stla
@presentation_batch policy=join
  @bgm play evening cue=bridge fade=0.8
  @stage evening show asset=stage:evening transition=fade duration=0.8
@end
```

最短 `@bgm play asset` 保持不变。multi-stem resource 可在 `play` 上以 `mix=stem[,stem[:gain]...]` 指定初始配比，之后用 `@bgm mix ... [fade=...]` 原地改变配比；裸 stem gain 为 1，未列出的已定义 stem 为 0，空或全零 mix 会 fail-close。same playing asset+cue+volume+mix 会重新完成 resource/Presenter positive preflight，但稳定时不 seek、不重启 player；只改 volume 或 mix 保留同一个 player/stream/cursor。若同 action 的上一条 FNF fade 尚未结束，新 aligned JOIN 会先 exact-finish 旧 receipt 到唯一 authored endpoint，再以零新 Tween 同步完成，旧 token 之后保持 inert。paused 下 `play` 从 cue start 重播，`resume` 才继续保存的 cursor。play/mix/pause/resume/stop fade 都由同一 Director receipt 驱动，普通 advance 与 Skip 只 exact-finish 当前 JOIN；Auto 本身不制造 ack。context/global abort 会 cut 当前 Tween 到已提交 stable target；reset/load/rollback/restart/title 与 stale callback 使用同一 generation/ownership边界。

原始 OGG/MP3/WAV 默认从 0 开始、循环到 stream end，并保留格式中合法的 loop marker。需要 authored start/loop marker 或 named cue 时，创建 `BgmTrackDefinition` Resource。single-stream 设置 `stream`；multi-stem 必须把 `stream` 留空并设置 2..32 个 `BgmStemDefinition`（唯一 `stem_name`、AudioStream、`default_gain=0..1`）。两者必须且只能选一个。multi-stem 所有流必须同为 OGG/MP3/WAV、长度相同；WAV 还要求 mix rate、stereo 和 sample format 相同。Presenter 只创建一个 `AudioStreamSynchronized` BGM player，各 stem 从同一 playback 相位开始。

track 设置共享 `loop`、`start_position`、`loop_position`、`loop_end_position`，并可添加完整的 `BgmCueDefinition`。named cue 不继承 track default。`loop_end_position=-1.0` 是唯一 physical-stream-end sentinel；其他值必须有限，且每个定义都须对所有流满足 `0 <= start_position <= loop_position < resolved_loop_end <= length`。`loop=false` 时仍验证完整 region，但不启用循环，也不会截断显式 end 后的 natural tail。

WAV definition duplicate 以 source sample frame 写入 `loop_begin` / `loop_end`；OGG/MP3 duplicate 以 Godot 4.6 mixer 的 `loop_offset` + 单 beat boundary 写入显式 end，并要求读回误差小于一个 source sample，否则 fail-close。natural sentinel 清除 definition duplicate 的 beat end marker，raw stream 自带的合法 native marker 则原样保留。multi-stem 的同一 end 原子应用到每个 synchronized child；mix/volume-only 更新仍不 seek、不 restart、不换 stream。Stella 不裁剪、转码或猜测素材时长，也没有 polling/timer/frame-wait loop owner。`loop_end_position` 只属于 resource definition，不是新 DSL/save 字段。资源/cue/stem/region 缺失、歧义、非法或不可精确表示，会在 mixed child 的任何 mutation 前按 BGM authored line fail-close。公开 synthetic single/multi-stem reference 见 [`examples/demo/scenarios/bgm_lifecycle.stla`](../examples/demo/scenarios/bgm_lifecycle.stla) 与对应 redistributable `.tres`。

旧 `@bgm asset [fade]` / `@bgm off [fade]` 已删除，必须迁移为 `play` / `stop` action grammar；Runtime 中没有第二 BGM handler 或 legacy alias。

### 声明式 Stage 批次：JOIN 与 fire-and-forget

当多个命名 Stage 层必须在同一 authored boundary 提交，且后续对话或音频必须等待全部转场到达终态时，使用 `policy=join`：

```stla
@stage_batch policy=join
  @stage sakura show kind=character asset=character:sakura/smile position=480,80 transition=fade duration=0.3
  @stage senpai show kind=character asset=character:senpai/default position=1440,80 transition=fade duration=0.3
@end

「两层都已到达 authored 终态。」
```

若只需要保证整批操作已经完整 dispatch 并 seal，允许剧情立即继续、Tween 仍在运行，使用 `policy=fire_and_forget`：

```stla
@stage_batch policy=fire_and_forget
  @stage sakura update position=720,80 transition=move duration=0.4
  @stage senpai update asset=character:senpai/smile transition=fade duration=0.4
@end
@se se_select
「这行可在 Tween 运行时开始。」
```

普通左键、Space 或 Enter 只会把当前 sealed JOIN 的 exact receipts（包括 rule-mask/mosaic Stage projection）snap 到 authored endpoint；standalone Stage 与 `FIRE_AND_FORGET` 不 claim input，也不会消费、重放 advance 或把下一句 click 归给旧转场。Skip 从 false 切换为 true 时 exact-finish 当前 JOIN 一次；Skip 是持续模式，新 batch 提交时已 active 则在 participant seal 后直接 force-cut，不创建 projection snapshot/Tween。Auto 状态本身不结束 Stage JOIN。完整语法、ordering 与 fail-close 规则见 [DSL 文档](DSL.md#312-舞台批次组合stage_batch)；公开的 reference scenario 见 [`examples/demo/scenarios/stage_batch.stla`](../examples/demo/scenarios/stage_batch.stla)，它不是默认 Start Game 入口。

`z_index` 是整数基础平面，`depth_origin` 是独立有限浮点排序偏移；最终排序键为两者之和。它不会改变 position、二维 origin、scale/zoom、`depth_scale`、rotation、clip/crop 或 Asset/Body/Face 合成。对于把基础深度与深度原点分开存储的来源格式，importer 必须生成这两个 canonical 字段，不得烘焙素材或添加项目侧 Presenter 分支；`originz` 等来源字段名不是 Stella DSL alias。完整浮点键会进入 Stage canonical snapshot，并由 move transition 连续插值；load、rollback、restart、return-to-title 和 scene replacement 都通过同一 Runtime-owned Stage lifecycle cut 恢复精确终态。

Rule-mask 与 mosaic 的公开合成示例位于 [`examples/demo/scenarios/stage_transitions.stla`](../examples/demo/scenarios/stage_transitions.stla)，遮罩是仓库内可再分发的 synthetic SVG；测试和示例都不依赖任何宿主项目素材。

高级 typed surface 由 `PresentationOperation`、`StagePresentationOperation`、`DialogueAvatarPresentationOperation`、`DialogueVisibilityPresentationOperation`、`DialogueClearPresentationOperation`、`ChapterIndicatorPresentationOperation`、`LoopSePresentationOperation`、`BgmPresentationOperation`、`PresentationOperationReceipt`、`PresentationBatchRequest` 和 `PresentationDirector` 组成。唯一 owner 是 `StellaRuntime.presentation_director`；项目不应自行 `new()` 第二个 Director，也不应调用 `_bind_authority()`、`_seal()` 或 `_settle()` 等下划线内部方法。`PresentationRequestReservation` 同样是 Runtime 内部的单次 capability，仅供 `@combine` 在同步 typed dispatch 前登记 exact owner，不是用裸 request ID 提交工作的公开 API。同一个 Director 支持 Stage、`@dialogue_avatar`、`@dialogue_visibility`、`@dialogue_clear`、`@chapter_indicator`、`@loop_se` 与 `@bgm` 的 mixed `@presentation_batch`，在任何 apply 前完成全批 preflight/seal，再按 authored child order dispatch。它只用于需要跨 channel 共享 JOIN/FNF boundary 的高级 composition；普通 avatar/chapter/dialogue clear/显隐与 loop-SE/BGM 保持各自 standalone 写法，并由 parser lowering 到同一条 canonical child 路径。

公开的 `StellaRuntime.apply_stage_operations(operations, force_cut) -> void` 是 canonical programmatic Facade：它要求完整六字段 operation，不返回 receipt、不等待 Tween，也不等价于 authored `@stage_batch`。simple transition 保留同步 raw notification contract；projection transition 经 typed Director preflight 后才发布同一个 canonical notification。`@combine` 的 Stage cue 同样经 typed Director，且 parser 保留每条 cue 的 source line；segment sequencing 不因此变成 batch JOIN。

### 存档/读档

```gdscript
StellaRuntime.quick_save()           # 快存（slot 0）
StellaRuntime.quick_load()           # 快读（slot 0）
StellaRuntime.save(slot_id)          # 存档到指定槽位
StellaRuntime.has_save(slot_id)      # 检查槽位是否有存档
StellaRuntime.delete_save(slot_id)   # 删除存档
StellaRuntime.get_save_list()        # 获取所有有存档的槽位
```

Runtime 会把规范化剧本来源的版本化 identity 写入存档，并在 `load_game()`、`quick_load()`、`continue_from_save()` 和 `continue_game()` 导航前校验它。这样不同目录下同为 `shared.stla` 的剧本也不会串档，存档 JSON 中不会写入私有来源路径。缺少该 identity 的旧版存档会 fail-closed；如果产品必须保留旧档，请在升级发布前由宿主迁移工具读取旧 JSON、根据产品自己的旧版本映射确认目标剧本，再显式写入新 identity，不要仅按文件 basename 自动猜测。

直接调用公开 parser 时请传入 authored path；identity 会在 parser 边界生成，而不依赖 Runtime 的私有包装：

```gdscript
var data := DslParser.parse(tokens, "route_a", "res://story/route_a.stla")
```

扩展若完全程序化构造 `ScenarioData`，必须在需要读写持久存档前提供稳定的 authored key：

```gdscript
var data := ScenarioData.new()
data.id = "route_a"
var identity_error := data.set_authored_identity("my_extension:route-a:v1")
if identity_error != OK:
	push_error("invalid authored scenario identity")
```

这个 key 会先哈希再进入存档，不会原样写入 JSON；它不是 secret。兼容版本必须持续使用同一个 key，不兼容内容应显式换 key。不要用显示标题或文件 basename 充当 key，也不要给空 identity 的程序化 `ScenarioData` 开启 scenario-aware 读档。

迁移旧的程序化存档时，宿主必须先按自己的旧版本映射确认目标，再使用同一个 authored key，并把生成值写入待迁移 snapshot；不要对未知旧档猜 key：

```gdscript
var legacy_snapshot := StellaRuntime.save_manager.read_save_data(slot_id)
# 仅在宿主已确认 legacy_snapshot 属于 route_a 后执行：
legacy_snapshot["scenario_context"]["scenario_source_identity"] = (
	data.source_identity
)
# 再由宿主自己的原子迁移事务写回 JSON。
```

在游戏内读档、快读或从 Backlog/选项/流程图回退时，Runtime 会先把 engine context 所有权转交给恢复后的 context，再清理旧画面和阻塞命令。旧对话的取消不会触发自然 `scenario_ended`，恢复后的 context 始终是最终执行 owner；自定义 Presenter 仍只需遵守上文的 request `advance()` / `abort()` 契约。

JOIN 动画进行中可以存档。存档记录已原子提交的 final canonical Stage target、loop-SE 的 `{asset, loop, volume, position}`、BGM 的 `{asset, cue, loop, position, status, stem_mix, volume}`（stopped 为 `{}`；single-stream 的 `stem_mix={}`）与 scenario cursor；operation、policy、request/batch、receipt、token、generation、Tween、barrier、fade progress 与 outgoing player 都不入档。恢复时先 cancel old generation，再 reset + atomic cut canonical target，最后在 same cursor 重新派发。BGM pause fade 存档会采样保存瞬间 cursor，但恢复直接是稳定 paused；crossfade 存档只保存 incoming target/current incoming cursor，mix fade 保存已提交的 final mix。这是有意的 cut projection，不恢复 Tween progress。loop-SE/BGM 的 same target 仍须通过 AudioPresenter/resource preflight。旧版 String `bgm` 或缺少 `stem_mix` 的旧六字段 BGM 存档不是当前版本公共 schema，generic read 与 scenario-aware load 都在任何 provider mutation 前 fail-close；宿主若需要迁移已确认版本的 single-stream 旧档，应在自己的版本化迁移事务中补入 `stem_mix={}`，Stella Runtime 不保留 legacy 分支。

Stage target 中的 `z_index` 与 `depth_origin` 作为两个独立 canonical 字段进入同一 JSON snapshot；恢复时重新计算完整浮点排序键，不保存 CanvasItem bucket、sibling index 或 Tween 中间值。

presentation-clip audio choice 另保存 Runtime-owned RNG authority 的完整 current snapshot。active clip
的 player、timeline、cue cursor 仍不入档并在 load/rollback 边界退休；selection 前快照重新派发会
得到同一选择，selection 后快照保留已推进 state/last ID。当前存档必须含该 versioned provider，
不存在 presence-based legacy fallback。

### 播放控制

```gdscript
StellaRuntime.toggle_auto_play()     # 开关自动播放
StellaRuntime.toggle_skip()          # 开关快进
StellaRuntime.is_auto_playing()      # 是否在自动播放
StellaRuntime.is_skipping()          # 是否在快进
```

### UI 覆盖层

```gdscript
StellaRuntime.show_settings()        # 打开设置
StellaRuntime.show_save_load()       # 打开存档/读档
StellaRuntime.show_backlog()         # 打开回想记录
StellaRuntime.close_overlay()        # 关闭当前覆盖层
```

### CG Gallery

```gdscript
StellaRuntime.unlock_cg(cg_id)       # 启用 cg_gallery 时记录解锁
StellaRuntime.is_cg_unlocked(cg_id)  # 查询单个 CG
StellaRuntime.get_unlocked_cgs()     # 获取已解锁 CG 的副本
```

`cg_gallery=false` 时三个 API 都 fail-closed：写入返回 `false`，查询返回 `false` / 空数组；已有存档进度不会被清除。

### 设置

不声明项目设置时无需任何新配置；内置设置仍由同一个 `SettingsManager` registry
管理。要增加一个项目设置，在 `stella.cfg` 指向 JSON schema：

```ini
[settings]
schema = "res://settings/project_settings.json"
```

普通 schema 只需要 `version` 和 `settings`。例如，下面注册一个与内置
`auto_play_delay` 完全独立的 `0..100` 整数：

```json
{
  "version": 1,
  "settings": {
    "project.auto_base_wait": {
      "type": "integer",
      "default": 50,
      "minimum": 0,
      "maximum": 100
    }
  }
}
```

项目 key 必须是小写 namespaced identifier，不能覆盖内置 key。项目设置支持
`boolean`、`integer`、`number`、`enum` 和 `dictionary`；integer/number 可声明有限
`minimum` / `maximum`，enum 声明唯一非空 `values`，dictionary 还声明
`value_type=boolean|integer|number|string|enum` 及适用的 range/values。要覆盖内置
reset 默认值，使用可选的顶层 `defaults`，且只能精确命中已注册内置 key：

integer（包括 dictionary 的 integer value）使用单一 JSON-safe 闭区间
`[-9007199254740991, 9007199254740991]`。schema default/range、direct set、save/load 和
migration 都经过同一检查；边界外数值一律视为非法，不截断、取整或创建第二种编码。
项目定义的 integer 会 fail-close；内置 typewriter 毫秒项继续使用下文既有的
warning + authored-default invalid-input 行为，但同样绝不接受或保存舍入后的整数。

```json
{
  "version": 1,
  "defaults": {"bgm_volume": 0.7},
  "settings": {}
}
```

省略 `defaults`、`settings` 或 `migrations` 等同空值；因此只覆盖内置默认值时也不必
写空的其他段。schema 会在注册前整份校验，未知字段、非法类型/range、非 namespaced
key、内置 shadow 或坏默认值都会带 schema 资源路径与 JSON field/index 原子拒绝。

```gdscript
var wait := StellaRuntime.get_setting("project.auto_base_wait")
var changed := StellaRuntime.set_setting("project.auto_base_wait", 75)
var definition := StellaRuntime.get_setting_definition("project.auto_base_wait")
var keys := StellaRuntime.get_registered_settings()
var save_error := StellaRuntime.save_settings()
StellaRuntime.reset_settings()  # 恢复 schema authored defaults
```

`get`、definition 和 signal 中的 Dictionary 都是 defensive deep copy。direct set 的未知
key 或非法值会 warning 并返回 `false`，不发生写入；成功 set 沿用内置设置既有通知语义。
definition 中的 `default` 是 effective authored default，因此自定义 UI 不必复制 schema
覆盖规则。
reset 先原子恢复全部 authored defaults，再按“内置规范顺序、项目 key 排序”对实际变化
exact-once 发布 `SignalBus.settings_changed(key, value)`，同步监听器不会看到半重置状态。

持久化使用 `user://settings.json`，格式严格为
`{"schema_version": <int>, "values": {...}}`。load 先读取、迁移和校验整份候选，再原子
提交 present registered keys；省略项保持当前值，未知/unregistered key、未来 schema
version、旧 flat JSON 或任一被对应 setting contract 拒绝的值都会拒绝整次载入，零写入、零通知。成功载入只按 registry
顺序通知实际变化，且每个 payload 都是通知时的完整当前值。

#### 高级：设置迁移

schema version 大于 1 时，必须为每个旧 version 提供一条连续的 `rename` / `remove`
迁移；没有猜测、跳步或项目 callback：

```json
{
  "version": 2,
  "settings": {
    "project.auto_base_wait": {
      "type": "integer", "default": 50, "minimum": 0, "maximum": 100
    }
  },
  "migrations": [
    {
      "from": 1,
      "to": 2,
      "rename": {"project.auto_delay": "project.auto_base_wait"},
      "remove": ["project.obsolete"]
    }
  ]
}
```

rename target 必须由当前 schema 注册且不能冲突或形成同一步 chain；rename/remove 不能
重叠。迁移只作用于 detached candidate，任何冲突都在 live settings mutation 前
fail-close。Stella 不保留旧 flat JSON 的读取分支；需要跨越该明确格式边界的项目，应在采用
schema 版本化存储前自行完成一次离线转换。

`character_interval` 与 `punctuation_pause` 都是非负整数毫秒，默认分别为
`50` 和 `200`，`0` 合法且不设上限。前者是每个可见字符的基础间隔；后者只对
固定集合 `，。！？；：、,.!?;:…—` 中的每个 Unicode codepoint 增加额外停顿。
通过 `set_setting()` 或持久化 load 提供负数、非整数或非数值时，框架会 warning
并把对应项恢复为其独立 authored 默认值；JSON 中可无损表示整数毫秒的数值会归一化为整数。
Presenter 在一条对话真正开始显示时快照两项设置，因此当前行中途调用
`set_setting()`、恢复默认或载入设置不会改变剩余字符，下一条 active 对话才采用
新值；启动时在创建游戏场景/DialoguePresenter 前载入的值会用于首行。句内
`{speed:...}` 只覆盖当前行的基础间隔，`{wait:...}` 保持为字符前的独立 authored
停顿，两者均与标点停顿相加。

`text_window_opacity` 是 `0..1` 的数字，默认 `0.8`。Presenter ready 时读取已完成
启动载入的当前值；direct set、成功的显式 load 与 reset 会立即更新当前 active 对话背景，
无需重新打开 scene。scene replacement/rebuild 由新 Presenter 从同一个 live registry
重投影，旧 Presenter 退场后不再订阅设置。该设置只消费上文显式绑定的背景 Control，
不修改 panel、正文、姓名、avatar、toolbar 或其他 focusable control。

`click_to_complete` 是布尔设置，默认 `true`。左键、Space、Enter 和手柄 A 每次
进入正常推进路径时都会实时读取它：打字中且为 `true` 时，该次输入只补全当前句；
为 `false` 时，该次输入仍被消费，但不会改变可见字符、退休 timer，也绝不会回退到
当前 owner 或全局 advance。文本自然完成后，下一次正常输入照常推进。由此
`set_setting()`、reset 或 load 的新值会从下一次输入起生效，即使当前句已经在
打字。UI 隐藏恢复、交互 Button/Slider、非 `PLAYING` 状态，以及左键的 Skip/Auto
策略仍优先处理；程序化 `DialoguePresenter.complete_typewriter()` 是强制完成接口，
不读取这一设置。

`effect_enabled` 是布尔设置，默认 `true`。它在 `ScreenEffects` 进入场景时读取，并
实时响应 direct set、成功 load 与 reset。切到 `false` 会同步停止活动 shake/flash，
恢复 shake 的 position/scale/pivot 与 resize/process 状态，并移除 flash overlay；
禁用期间的新 shake/flash 被直接丢弃，重新开启不会重放。公开
`SignalBus.effect_requested`、自定义 effect、`@fade`、舞台、对话和音频链路不受影响，
`@effect off` 始终可以清理。

Choice 菜单是独立于 `click_to_complete` 的 hard modal boundary。每次菜单显示前分别
快照 `auto_play_pause_on_choice` 与 `skip_stop_on_choice`（默认都为 `true`）：Auto
pause 保留 `auto_play.is_active` / `is_auto_playing()` 的用户 intent，只暂停内部
effective progression，并在有效选择 effects 提交后释放；它不会重启 choice 前旧句的
timer。Skip stop 会同步停止且不在选择后恢复。任一设置为 `false` 都只表示保留对应
intent，绝不自动选项或穿透 choice。菜单期间修改这两个设置从下一次 choice 起生效。

Choice 显示时，背景左键、Space、Enter、手柄 A 都被消费，不会恢复隐藏 UI、补全文字
或解除 `@wait`；只有聚焦 option Button 的 GUI `ui_accept` 或直接点击 option Button
才会选择。toolbar Button 仍交给 GUI：菜单期间可以更改 Auto/Skip intent，但当前菜单
继续阻断旧 dialogue tail。读档、回退、restart、abort 和返回标题会取消当前 choice、
停止两个 controller 并拒绝旧 listener/timer；这些 hard boundary 会先转移或清空 engine
owner，再发布旧 choice HIDE，因此同步回调不能推进旧剧情或误关替换 context 的新菜单。
普通 save 不会关闭菜单。

> 高级用户也可以直接访问子系统对象：`StellaRuntime.save_manager`、`StellaRuntime.settings_manager` 等。

---

## 资源命名约定

`@stage` 的 `asset`、`body`、`face` 支持以下资源写法：

| 资源引用 | 文件路径 |
|----------|----------|
| `background:bg_school` | `{backgrounds_path}/bg_school` |
| `character:sakura/smile` | `{characters_path}/sakura/smile` |
| `stage:sakura/body` | `{stage_assets_path}/sakura/body` |
| `fx/sparkle` | `{stage_assets_path}/fx/sparkle`（无前缀默认使用 stage） |
| `res://art/shared/light.png` | Godot 资源绝对路径，原样使用 |

相对引用可省略扩展名；Presenter 会依次尝试常见图片与 Texture Resource 扩展名。

独立资源指令使用各自的配置路径：

| DSL 指令 | 文件路径 |
|----------|---------|
| `@bg bg_school` | `{backgrounds_path}/bg_school.png` |
| `@bgm play bgm_spring` | `{bgm_path}/bgm_spring.ogg` / `.mp3` / `.wav`，或 `BgmTrackDefinition` `.tres` / `.res` |
| `@se se_click` | `{se_path}/se_click.ogg` (或 .wav) |

路径前缀通过 `stella.cfg` 的 `[paths]` 段配置，也可在代码中直接设置 `StellaRuntime` 的属性。

### 对话头像资源

舞台人物与对话头像是两个独立功能。`@stage` 直接引用舞台图片；对话头像则从
`art/characters/<character>/config.json` 读取裁剪区域和可选的表情资源映射：

```json
{
  "avatar_rect": {"x": 80, "y": 20, "w": 240, "h": 240},
  "avatar_assets": {
    "default": "portrait_neutral",
    "sad": "portrait_sad"
  }
}
```

上例把 `[expr:sad]` 解析为同目录下的 `portrait_sad.png`，再按 `avatar_rect`
裁剪。省略 `avatar_assets` 时，表达式名本身就是文件名；每句对话都从
`default` 开始，句内标签不会隐式改变任何舞台层。没有有效 `avatar_rect` 时，
该角色不显示对话头像。

---

## DSL 语法速查

详见 [DSL.md](DSL.md)。常用指令：

```
// 场景
@scene scene_id "标题"

// 对话
sakura「台词」
sakura「台词」 #voice:voice_id
sakura「电话里的台词」 #voice:voice_id #voice_dsp:telephone
ensemble「同时发声」 #voice_layer:lead(character=sakura,asset=sakura_001) #voice_layer:reply(character=senpai,asset=senpai_001,dsp=telephone)
「旁白」
sakura（内心独白）

// 基础背景由 @bg 独立管理
@bg bg_school fade 0.8

// 人物与其他动态图片统一使用命名舞台层
@stage sakura show kind=character body=stage:sakura/body face=stage:sakura/smile x=960 y=1050 origin=500,1000 z_index=25 depth_origin=-9000
@stage foreground_effect show asset=stage:soft_light z_index=25 depth_origin=-8000
@stage sakura update face=stage:sakura/sad transition=fade duration=0.2
@stage sakura hide
@stage sakura remove
@stage clear

// 原子提交多个命名 Stage 层，并等待 exact receipts
@stage_batch policy=join
  @stage sakura update position=720,80 transition=move duration=0.3
  @stage senpai hide transition=fade duration=0.3
@end

// dispatch seal 后继续，Tween 可仍在运行
@stage_batch policy=fire_and_forget
  @stage sakura update position=960,80 transition=move duration=0.4
@end

// 方括号只更新对话框头像；舞台图片只由 @stage 改变
sakura「[expr:sad]我有点担心。」

// 音频
@bgm play bgm_spring fade=0.8
@bgm pause
@bgm resume fade=0.2
@bgm stop fade=0.8
@se se_click

// 选择
@choice "提示文字"
  - "选项A" -> scene_a {var += 5}
  - "选项B" -> scene_b

// 流程
@jump scene_id
@set var = value
@if condition
  ...
@else
  ...
@end

// 演出
@fade out 1.0
@wait 1.5
@wait 1.5 skippable=true  // 允许玩家推进或 Skip 提前结束
@wait click
@effect shake
@nvl / @nvl off
@overlay / @overlay off
@parallel
  @bg bg_sunset dissolve 1.0
  @stage sakura update position=960,1050 transition=move duration=0.5
@end

// 多段语音 + 舞台差分合并为一句对话
@combine
@stage sakura update face=stage:sakura/sad transition=fade duration=0.2
sakura「[expr:sad]我本来很开心的...」 #voice:sakura_013
@stage sakura update face=stage:sakura/surprised transition=fade duration=0.2
sakura「[expr:surprised]但是听说下周要期中考...」 #voice:sakura_018
@stage sakura update face=stage:sakura/sad transition=fade duration=0.2
sakura「[expr:sad]我数学肯定完蛋了。」 #voice:sakura_019
@end
```

绝大多数对话只写 `#voice`；`#voice_dsp` 与它前后顺序均可。只有一个 segment
确实需要多条独立语音同一 mix boundary 开始时才重复写 `#voice_layer`（最多 8 层）。
每层必须给稳定 id、character、逻辑 asset，可选 dsp；不得与 `#voice` shorthand
混用。Stella 保留 authored layer 顺序并对全组资源/DSP 原子预检，Backlog/Auto/Skip/
load/rollback 都复用同一 group lifecycle，不会预混或串行播放。

Timed wait 默认不可由玩家截短；`skippable=true` 是唯一可选项，适合仍需保留最长演出时长、但允许左键、Space、Enter、手柄 A 或 Skip 提前继续的场景。Auto 保持 authored duration。`@wait click` 是独立模式，不接受 option。无论是否 skippable，读档、回退、重启、返回标题和 scenario replacement 都会取消旧 execution generation；迟到 timer 或输入不会影响恢复后的命令。完整 grammar 与诊断见 [DSL 文档](DSL.md#314-等待)。

---

## 自定义扩展

### 添加自定义命令

```gdscript
class_name MyShakeHandler extends CommandHandler

func get_command_type() -> String:
    return "my_shake"

func execute(data: CommandData, _context: ScenarioContext) -> void:
    var intensity = data.get_float("intensity", 5.0)
    SignalBus.effect_requested.emit("shake", {"intensity": intensity})
```

如果自定义命令会阻塞等待 signal，应把 `context` 传给统一取消 helper：

```gdscript
func execute(_data: CommandData, context: ScenarioContext) -> void:
    if not await CommandHandler.await_with_abort(my_completed, context):
        return
```

context 在一次剧情执行期间就是它的代际 token；载入、重启或回滚会取消旧 context 的所有此类等待，避免旧 handler 响应新剧情的输入。

在启动时注册：
```gdscript
StellaRuntime.registry.register(MyShakeHandler.new())
```

### 添加自定义选项风格

继承 `TextChoicePresenter`，实现自己的 UI 展示逻辑。
