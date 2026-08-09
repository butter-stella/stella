# Stella — 使用指南

## 安装

### 方法 1：从 GitHub 安装

1. 下载 [最新 Release](https://github.com/butter-stella/stella/releases) 中的 `stella-plugin.zip`
2. 解压到你的 Godot 项目的 `addons/` 目录下
3. 在 Godot 编辑器中：**Project → Project Settings → Plugins** → 启用 **Stella**

### 方法 2：从源码安装

1. 将 `addons/stella/` 目录复制到你的项目的 `addons/` 下
2. 启用插件（同上）

插件激活后会自动注册 `SignalBus` 和 `StellaRuntime` 两个 Autoload，并设置主场景为内置标题画面。

---

## 快速开始（5 分钟跑通）

### Step 1 — 创建目录结构

在你的项目中创建以下目录：

```
your_project/
├── addons/stella/        ← 框架插件
├── art/
│   ├── backgrounds/       ← 背景图 PNG
│   └── characters/        ← 立绘（按角色分文件夹）
│       └── sakura/
│           ├── default.png
│           └── smile.png
├── audio/
│   ├── bgm/               ← BGM (ogg/mp3)
│   └── se/                ← 音效 (ogg/wav)
├── scenarios/             ← .stla 剧本
└── stella.cfg            ← 配置文件
```

### Step 2 — 写一段剧本

创建 `scenarios/demo.stla`：

```
@scene start "开始"

@bg bg_school
@show sakura smile center

sakura「你好，欢迎使用 Stella！」
sakura「这是一个最小的示例。」

@hide sakura
@bg bg_black fade 1.0
@end
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

### Step 4 — 搭建游戏场景

参考 `examples/demo/` 的结构搭建自己的标题场景和游戏场景，然后在 `stella.cfg` 的 `[overrides]` 中指向它们。

游戏场景中使用插件的 Presenter 脚本（`BackgroundPresenter`、`CharacterPresenter` 等），通过 `StellaRuntime` 的 Facade API 控制游戏流程。

如果自定义游戏场景需要支持 `@effect shake`，请在每个需要震动的舞台 `CanvasLayer` 下添加一个专用的全屏 `Control` 根节点（建议命名为 `ShakeRoot`，Full Rect、Mouse Filter Ignore），把该层的可见内容放到根节点下，再将根节点路径写入 `ScreenEffects.shake_target_paths`。使用全屏 `Control` 可确保子 Control 的 anchors 仍以视口尺寸布局；普通 `Node2D` 目标也受支持，但不适合作为锚点 UI 的父节点。路径相对 `ScreenEffects` 解析；内置默认值为 `../BackgroundLayer/ShakeRoot` 和 `../CharacterLayer/ShakeRoot`。`ScreenEffects` 在特效期间独占这些根节点的 `position`；镜头移动、平移等系统应使用外层 `CanvasLayer.offset` 或其他子节点，这样它们可以与 shake 安全叠加。不要把 UI 根节点列入目标，便可让对话框保持静止。

为避免恰好等于视口大小的背景在位移时露出清屏色，还应把背景的 `ShakeRoot` 同时写入 `shake_coverage_target_paths`。该目标必须是宽高至少 1 px 的有限尺寸、单位缩放、零旋转的 `Control`；运行时只在 shake 期间围绕中心按强度增加必要的 overscan，窗口尺寸变化时会同步重算，并在结束或取消时恢复原始 scale 与 pivot。人物根不要加入 coverage 列表，因此人物比例和 anchor 不会改变。`Node2D` 目标或未配置 coverage 的自定义场景仍可震动，但需要项目自己提供足够的背景出血区。旧版自定义场景中直系的 `BgFront`/`BgBack` 与 `SlotLeft`/`SlotCenter`/`SlotRight` 仍可正常加载，但需要按上述结构迁移后才会获得可组合且不露边的 shake。

`@effect flash` 的绘制宿主由 `ScreenEffects.flash_canvas_path` 指定。推荐像内置场景一样，创建一个独立且 `layer` 严格高于场景内所有 UI（包括项目自定义 UI）的 `CanvasLayer`，再将其路径填入该属性；`ScreenEffects` 不会修改外部宿主的层级。宿主必须位于场景树中，退出场景树时其活动 flash 会被同步取消。宿主层应使用唯一的最高层级，因为同一 CanvasLayer 层级的跨层绘制顺序不应作为遮盖保证。若路径留空，兼容模式会在 `ScreenEffects` 下创建私有 CanvasLayer，并使用可配置的 `flash_canvas_layer`（默认 100）。

```text
Game
├── BackgroundLayer (CanvasLayer)
│   └── ShakeRoot (Control，Full Rect)
│       ├── BgFront
│       └── BgBack
├── CharacterLayer (CanvasLayer)
│   └── ShakeRoot (Control，Full Rect)
│       └── ...
├── UILayer (CanvasLayer)
└── ScreenEffects
    └── FlashCanvas (CanvasLayer，最高 layer)
```

内置场景的 `ScreenEffects` 将 `BackgroundLayer/ShakeRoot` 同时配置为 shake target 和 coverage target，将 `CharacterLayer/ShakeRoot` 只配置为 shake target。

如果不搭建自己的场景，引擎会使用内置的默认场景。

#### 声明式配置 ADV / NVL / overlay 对话布局

普通项目直接在 STLA 中声明并选择命名 Profile，不需要打开 Godot 场景：

```stla
@dialogue_profile novel panel_anchors=0,0,1,1 panel_offsets=0,0,0,0
@dialogue_profile novel text_anchors=0.15,0.1,0.85,0.7 text_margins=20,20,20,20
@dialogue_profile novel horizontal_alignment=left line_spacing=8
@dialogue_profile novel background_visible=true background_modulate=#ffffff00
@dialogue_profile novel show=quick_menu
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

完整属性表和诊断规则见 [DSL.md](DSL.md#33-对话框模式切换)。内置场景已经提供可定位文字区域、`DialogueBg` 和 `quick_menu` 分组，常规 ADV、透明 NVL、书信、独白等版式都能只用 STLA 完成。Presenter 在就绪时保存 ADV 基线；配置过 `@adv profile=name` 时，`@nvl off` / `@overlay off` 恢复该 ADV Profile，否则恢复场景原始 ADV，并精确还原 panel、文字区域、文字样式、背景和分组 UI。

只有项目加入自定义 frame、logo 等专属 UI 时，才需要在 Godot 的 Node > Groups 中给节点增加语义分组，并在 STLA 的 `show` / `hide` 中引用。极少数需要程序动态注入样式的项目仍可在 Inspector 中使用 `DialoguePresentationProfile` / `DialogueModeProfile` Resource，或调用 `DialoguePresenter.set_presentation_profile()`；这是高级兜底接口，不是常规创作流程。

完全不写 `@dialogue_profile` 时，`@nvl` / `@overlay` 保持 Stella 原有布局行为，旧项目不需要迁移。

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

| DSL 指令 | 文件路径 |
|----------|---------|
| `@bg bg_school` | `{backgrounds_path}/bg_school.png` |
| `@show sakura smile` | `{characters_path}/sakura/smile.png` |
| `@show sakura` | `{characters_path}/sakura/default.png` |
| `@bgm bgm_spring` | `{bgm_path}/bgm_spring.ogg` (或 .mp3) |
| `@se se_click` | `{se_path}/se_click.ogg` (或 .wav) |

路径前缀通过 `stella.cfg` 的 `[paths]` 段配置，也可在代码中直接设置 `StellaRuntime` 的属性。

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

// 立绘
@show sakura smile center
@hide sakura
@expr sakura sad
@anim sakura jump
@move sakura left 0.5

// 背景
@bg bg_school fade 0.8

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
  @show sakura smile center
@end

// 多段语音 + 表情合并为一句对话
@combine
@expr sakura sad
sakura「我本来很开心的...」 #voice:sakura_013
@expr sakura surprised
sakura「但是听说下周要期中考...」 #voice:sakura_018
@expr sakura sad
sakura「我数学肯定完蛋了。」 #voice:sakura_019
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
