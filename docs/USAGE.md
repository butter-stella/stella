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

[features]
cg_gallery = false
backlog = true
save_slots = 8

[overrides]
title_scene = "res://scenes/my_title.tscn"
game_scene = "res://scenes/my_game.tscn"
settings_scene = ""
save_load_scene = ""
backlog_scene = ""
```

#### 分层配置与本地覆盖

将可公开、可复现的项目配置提交到受版本控制的 `stella.cfg`（tracked），只把当前开发者或当前机器需要的覆盖写入已被 Git 忽略的 `stella.local.cfg`（ignored）。例如，仓库中提交的基础配置可以是：

```ini
; stella.cfg（提交到仓库）
[game]
title = "Starfall"
scenario = "res://scenarios/main.stla"

[paths]
voice = "res://audio/voice/"

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

[overrides]
game_scene = "res://private_preview/ui/preview_game.tscn"
```

配置按 key 独立解析，优先级为“内置默认值 < `stella.cfg` < `stella.local.cfg`”。这套规则一致覆盖 `[game]`、`[paths]`、`[features]`、`[system_se]` 和 `[overrides]`；后一个文件只覆盖其中明确写出的 key，例如上面的本地文件不会改变基础配置中的 `game.title`。

配置语法使用 Stella schema 所需的常用子集：字符串必须用双引号包围，布尔值写作 `true` / `false`，整数使用十进制，注释以分号 `;` 开头。显式写入空字符串也是一次有效覆盖。

两个文件都是可选来源：缺失的文件不会报错，也不会清空较低优先级已经解析出的值。每个存在的来源会先完成读取和 schema 校验，再一次性提交；类型错误、未知 section/key 或语法损坏都会原子拒绝整个来源，该来源不会部分生效，也不会出现在已应用来源列表中。基础配置失败时保留默认值并停止继续叠加，本地覆盖失败时则完整保留已经生效的基础配置。语法错误诊断会带来源路径、安全的行列位置和预期修复提示；schema 错误会指出相关 section/key，类型错误还会带预期类型，且二者都不会打印配置值。

Runtime 每次解析后都会完整应用 resolved snapshot，包括没有配置文件时的内置默认值。因此删除或禁用配置来源并重新初始化时，Runtime 不会继续保留上一轮的本地路径或其他覆盖。

可用 Facade 查询本次启动实际提交的来源，返回顺序也就是应用顺序：

```gdscript
var sources: PackedStringArray = StellaRuntime.get_applied_config_sources()
# 典型结果：["res://stella.cfg", "res://stella.local.cfg"]
```

自动化、CI 或一次性诊断应通过通用环境变量显式禁用本地层，避免当前机器的 `res://stella.local.cfg` 污染结果：

```bash
STELLA_DISABLE_LOCAL_CONFIG=1 godot --headless --path /path/to/project --quit
```

该环境变量只跳过启动时隐式加载的本地文件；测试代码显式传入的 synthetic 配置路径仍可用于验证分层行为。

发布公共构建时，请在每个 Godot Export Preset 的资源过滤规则中显式包含 `stella.cfg`，并显式排除 `stella.local.cfg` 以及实际存放私有或生成内容的目录（例如上面的 `private_preview/`）。`.gitignore` 只控制 Git 是否跟踪文件，**不会**阻止 Godot 将它打包进导出产物。导出后还应检查资源清单或 PCK，确认这些排除规则确实生效。

`stella.local.cfg` 只是方便开发的覆盖层，不是 secrets vault：它既不加密，也不保证不会被误导出、备份或读取。不要在其中存放 API token、密码或其他凭据；凭据应通过环境变量或专用密钥管理服务提供。

### Step 4 — 搭建游戏场景

参考 `examples/demo/` 的结构搭建自己的标题场景和游戏场景，然后在 `stella.cfg` 的 `[overrides]` 中指向它们。

使用插件提供的默认 bootstrap 入口时，`[overrides].title_scene` 同时控制首次启动进入的标题场景和之后的返回标题行为；启动配置会在场景重定向和 Presenter 消费配置前完成解析与应用。

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

上例的两条 NVL 记录会累积显示为 `・第一行。・第二行。`。`entry_prefix` 放在角色名和正文之前，`entry_separator` 只放在相邻记录之间；两者只影响 NVL 的屏幕排版，不会改写 Backlog 的原始对话文本。省略它们时使用空前缀和换行分隔。`@combine` 块始终算一条记录，只添加一次前缀。字符串可使用 `\\`、`\"`、`\n`、`\r`、`\t` 转义，例如 `entry_separator="\n\n"` 可留出空行；它们仅支持纯文本，BBCode 方括号会产生诊断。

完整属性表和诊断规则见 [DSL.md](DSL.md#33-对话框模式切换)。内置场景已经提供可定位文字区域、`DialogueBg` 和 `quick_menu` 分组，常规 ADV、透明 NVL、书信、独白等版式都能只用 STLA 完成。Presenter 在就绪时保存 ADV 基线；配置过 `@adv profile=name` 时，`@nvl off` / `@overlay off` 恢复该 ADV Profile，否则恢复场景原始 ADV，并精确还原 panel、文字区域、文字样式、背景和分组 UI。

只有项目加入自定义 frame、logo 等专属 UI 时，才需要在 Godot 的 Node > Groups 中给节点增加语义分组，并在 STLA 的 `show` / `hide` 中引用。极少数需要程序动态注入样式的项目仍可在 Inspector 中使用 `DialoguePresentationProfile` / `DialogueModeProfile` Resource，或调用 `DialoguePresenter.set_presentation_profile()`；这是高级兜底接口，不是常规创作流程。

完全不写 `@dialogue_profile` 时，`@nvl` / `@overlay` 使用内置布局。离开 NVL 后，下一次进入会开始新的累积文本；这一规则也适用于 `@jump` 循环、重复 `@call` 和条件分支的实际执行路径。未离开 NVL 时重复 `@nvl` 不会另起一页。

### Step 5 — 运行

按 F5 运行。

---

## Facade API

`StellaRuntime` 提供简洁的 API，用户搭建自己的 UI 时只需要调用这些方法：

### 游戏流程

```gdscript
StellaRuntime.start_game()           # 开始新游戏
StellaRuntime.load_game(slot_id)     # 读档并进入游戏
StellaRuntime.return_to_title()      # 返回标题
```

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

StellaRuntime.hide_stage_layer("hero", "fade", 0.2)  # 保留节点和资源
StellaRuntime.remove_stage_layer("hero")             # 删除单层
StellaRuntime.clear_stage_layers()                    # 删除全部命名舞台层
```

多个操作可通过 `apply_stage_operations(operations, force_cut)` 同批提交。该 API 使用与存档一致的 closed schema：布尔属性必须是真正的 `bool`，清空 `asset` / `body` / `face` 使用字符串 `"none"`，景深与旋转只使用 `depth_scale` / `rotation`。任何操作含非法字段、值、transition 或 duration 时，整批都会被拒绝，不会部分派发。`force_cut=true` 会先归约整批操作，再同步投影最终状态，适合快进、点击补全和读档。所有人物与其他舞台图片都同步进入同一份 `PresentationState.stage_layers`；`hide` 的层仍在快照中，`remove` / `clear` 则会移除状态。

`redraw` 是有序的完整操作数组，而不是按类型合并的字典；更新它会原子替换整条管线，传 `[]` 会清空。支持 `color_overlay`、`brightness_contrast`、`grayscale`、`tint`、`blur` 和 `clip`；每条管线最多 16 个操作，其中最多 4 个 `blur`、1 个 `clip`。每个非零 `blur([x,y])` 都是独立 pass，对前一操作输出的 `[-x,+x] × [-y,+y]` 矩形窗口作完整等权 RGBA 平均；连续 blur 不会合并，`blur([0,0])` 则是保留在状态中的真正 no-op。`grayscale` 的 8-bit 目标灰度严格为 `(54 * R + 183 * G + 19 * B) >> 8`，再按 `amount` 与原色混合。`clip.asset` 继续使用 `background:` / `character:` / `stage:` / `res://` 或裸 stage 路径，并与普通纹理共享 `ResourceLoader` 缓存；快照只保存逻辑资源 ID，不保存 `Texture2D`。

含 blur 的层会使用离屏纹理。可查询渲染设备时，单轴尺寸上限取设备 2D 纹理上限与 8192 的较小值；无法查询时使用保守的 4096 上限。单层估算的离屏纹理总量上限为 256 MiB；静态投影每次最多 268,435,456 次纹理采样，连续投影每帧最多 67,108,864 次。超限时该层 fail-closed 为透明并报告错误，后续合法更新可恢复显示。只有动画纹理、源通道布局动画或交叉淡入确实逐帧改变离屏内容时才保持连续更新；隐藏层仍保留规范状态和已加载的源纹理，但会释放全部派生离屏目标，重新显示时按最新纹理尺寸重建。动态源纹理或 clip 遮罩变尺寸时，Presenter 会重新计算 bounds、fit 与 clip 矩形。

Godot 4.6 的 redraw 像素管线使用 Forward+ 或 Mobile renderer。macOS 上如需使用 Compatibility renderer，请升级到 Godot 4.7 或更新版本，以避开 4.6 的 CanvasGroup screen-backbuffer 缺陷。

### 存档/读档

```gdscript
StellaRuntime.quick_save()           # 快存（slot 0）
StellaRuntime.quick_load()           # 快读（slot 0）
StellaRuntime.save(slot_id)          # 存档到指定槽位
StellaRuntime.has_save(slot_id)      # 检查槽位是否有存档
StellaRuntime.delete_save(slot_id)   # 删除存档
StellaRuntime.get_save_list()        # 获取所有有存档的槽位
```

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

### 设置

```gdscript
StellaRuntime.get_setting(key)       # 读取设置值
StellaRuntime.set_setting(key, val)  # 修改设置值
StellaRuntime.save_settings()        # 保存设置到磁盘
```

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
| `@bgm bgm_spring` | `{bgm_path}/bgm_spring.ogg` (或 .mp3) |
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
「旁白」
sakura（内心独白）

// 基础背景由 @bg 独立管理
@bg bg_school fade 0.8

// 人物与其他动态图片统一使用命名舞台层
@stage sakura show kind=character body=stage:sakura/body face=stage:sakura/smile x=960 y=1050 origin=500,1000
@stage sakura update face=stage:sakura/sad transition=fade duration=0.2
@stage sakura hide
@stage sakura remove
@stage clear

// 方括号只更新对话框头像；舞台图片只由 @stage 改变
sakura「[expr:sad]我有点担心。」

// 音频
@bgm bgm_spring
@bgm off
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

在启动时注册：
```gdscript
StellaRuntime.registry.register(MyShakeHandler.new())
```

### 添加自定义选项风格

继承 `TextChoicePresenter`，实现自己的 UI 展示逻辑。
