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

如果不搭建自己的场景，引擎会使用内置的默认场景。

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
