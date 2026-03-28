# Natsume — 使用指南

## 安装

### 方法 1：从 GitHub 安装

1. 下载 [最新 Release](https://github.com/MadCcc/Natsume/releases) 中的 `natsume-plugin.zip`
2. 解压到你的 Godot 项目的 `addons/` 目录下
3. 在 Godot 编辑器中：**Project → Project Settings → Plugins** → 启用 **Natsume**

### 方法 2：从源码安装

1. 将 `addons/natsume/` 目录复制到你的项目的 `addons/` 下
2. 启用插件（同上）

插件激活后会自动注册 `SignalBus` 和 `NatsumeRuntime` 两个 Autoload。

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
├── scenarios/             ← .ntm 剧本
└── scenes/                ← Godot 场景
```

### Step 2 — 写一段剧本

创建 `scenarios/demo.ntm`：

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

### Step 3 — 创建启动脚本

创建 `scripts/bootstrap.gd`：

```gdscript
extends Node

func _ready():
    # 配置资源路径（指向你的目录）
    NatsumeRuntime.backgrounds_path = "res://art/backgrounds/"
    NatsumeRuntime.characters_path = "res://art/characters/"
    NatsumeRuntime.bgm_path = "res://audio/bgm/"
    NatsumeRuntime.se_path = "res://audio/se/"

    await get_tree().process_frame
    NatsumeRuntime.start_scenario("res://scenarios/demo.ntm")
```

### Step 4 — 搭建场景

创建一个场景，包含以下节点结构（可参考 `examples/demo/scenes/poc_main.tscn`）：

```
Main (Node2D)
├── BackgroundLayer (CanvasLayer, layer=0)
│   │  script: addons/natsume/presentation/background/background_presenter.gd
│   ├── BgFront (TextureRect, 全屏)
│   └── BgBack (TextureRect, 全屏)
├── CharacterLayer (CanvasLayer, layer=1)
│   │  script: addons/natsume/presentation/character/character_presenter.gd
│   ├── SlotLeft (TextureRect)
│   ├── SlotCenter (TextureRect)
│   └── SlotRight (TextureRect)
├── UILayer (CanvasLayer, layer=2)
│   ├── DialoguePanel (PanelContainer, 底部)
│   │  │  script: addons/natsume/presentation/dialogue/dialogue_presenter.gd
│   │  └── ... (NameLabel + TextLabel)
│   ├── ChoicePanel (PanelContainer, 居中)
│   │     script: addons/natsume/presentation/choice/text_choice_presenter.gd
│   └── FadeOverlay (ColorRect, 全屏)
│         script: addons/natsume/presentation/effects/fade_presenter.gd
├── InputHandler (Node)
│     script: addons/natsume/presentation/input/input_handler.gd
├── ScreenEffects (Node)
│     script: addons/natsume/presentation/effects/screen_effects.gd
├── AudioPresenter (Node)
│     script: addons/natsume/presentation/audio/audio_presenter.gd
└── Bootstrap (Node)
      script: scripts/bootstrap.gd
```

### Step 5 — 运行

在 **Project Settings → Application → Run** 中设置主场景，按 F5 运行。

---

## 资源命名约定

| DSL 指令 | 文件路径 |
|----------|---------|
| `@bg bg_school` | `{backgrounds_path}/bg_school.png` |
| `@show sakura smile` | `{characters_path}/sakura/smile.png` |
| `@show sakura` | `{characters_path}/sakura/default.png` |
| `@bgm bgm_spring` | `{bgm_path}/bgm_spring.ogg` (或 .mp3) |
| `@se se_click` | `{se_path}/se_click.ogg` (或 .wav) |

路径前缀通过 `NatsumeRuntime` 配置：

```gdscript
NatsumeRuntime.backgrounds_path = "res://art/backgrounds/"
NatsumeRuntime.characters_path = "res://art/characters/"
NatsumeRuntime.bgm_path = "res://audio/bgm/"
NatsumeRuntime.se_path = "res://audio/se/"
```

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

在 bootstrap 中注册：
```gdscript
NatsumeRuntime.registry.register(MyShakeHandler.new())
```

### 添加自定义选项风格

继承 `TextChoicePresenter`，实现自己的 UI 展示逻辑。
