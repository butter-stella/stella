# Natsume — 使用指南

## 安装

### 方法 1：从 GitHub 安装

1. 下载 [最新 Release](https://github.com/MadCcc/Natsume/releases) 中的 `natsume-plugin.zip`
2. 解压到你的 Godot 项目的 `addons/` 目录下
3. 在 Godot 编辑器中：**Project → Project Settings → Plugins** → 启用 **Natsume**

### 方法 2：从源码安装

1. 将 `addons/natsume/` 目录复制到你的项目的 `addons/` 下
2. 启用插件（同上）

插件激活后会自动注册 `SignalBus` 和 `NatsumeRuntime` 两个 Autoload，并设置主场景为内置标题画面。

---

## 快速开始（5 分钟跑通）

### Step 1 — 创建目录结构

在你的项目中创建以下目录：

```
your_project/
├── addons/natsume/        ← 框架插件
├── art/
│   ├── backgrounds/       ← 背景图 PNG
│   └── characters/        ← 立绘（按角色分文件夹）
│       └── sakura/
│           ├── default.png
│           └── smile.png
├── audio/
│   ├── bgm/               ← BGM (ogg/mp3)
│   └── se/                ← 音效 (ogg/wav)
├── scenarios/             ← .nat 剧本
└── natsume.cfg            ← 配置文件
```

### Step 2 — 写一段剧本

创建 `scenarios/demo.nat`：

```
@scene start "开始"

@bg bg_school
@show sakura smile center

sakura「你好，欢迎使用 Natsume！」
sakura「这是一个最小的示例。」

@hide sakura
@bg bg_black fade 1.0
@end
```

### Step 3 — 创建配置文件

创建 `natsume.cfg`：

```ini
[game]
title = "我的视觉小说"
scenario = "res://scenarios/demo.nat"
```

如果你的目录结构遵循默认约定（`art/backgrounds/`、`art/characters/` 等），只需要这两行配置。

完整配置示例：

```ini
[game]
title = "我的视觉小说"
scenario = "res://scenarios/main.nat"

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
title_scene = ""
game_scene = ""
```

### Step 4 — 运行

按 F5 运行。引擎会自动加载内置标题画面和游戏场景，无需手动搭建场景树。

---

## 三层定制体系

### Level 1：配置定制（natsume.cfg）

适合大部分用户。通过配置文件控制游戏标题、素材路径、功能开关、存档槽位数等。

### Level 2：继承场景

需要调整 UI 布局时，在编辑器中右键内置场景 → 新建继承场景 → 在 `natsume.cfg` 中指定覆盖：

```ini
[overrides]
game_scene = "res://scenes/my_game.tscn"
```

### Level 3：完全自建

有 Godot 经验的开发者可以从零搭建场景、覆写引擎脚本、注册自定义命令。

详见 [ENGINE_DESIGN.md](ENGINE_DESIGN.md)。

---

## 资源命名约定

| DSL 指令 | 文件路径 |
|----------|---------|
| `@bg bg_school` | `{backgrounds_path}/bg_school.png` |
| `@show sakura smile` | `{characters_path}/sakura/smile.png` |
| `@show sakura` | `{characters_path}/sakura/default.png` |
| `@bgm bgm_spring` | `{bgm_path}/bgm_spring.ogg` (或 .mp3) |
| `@se se_click` | `{se_path}/se_click.ogg` (或 .wav) |

路径前缀通过 `natsume.cfg` 的 `[paths]` 段配置，也可在代码中直接设置 `NatsumeRuntime` 的属性。

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
NatsumeRuntime.registry.register(MyShakeHandler.new())
```

### 添加自定义选项风格

继承 `TextChoicePresenter`，实现自己的 UI 展示逻辑。
