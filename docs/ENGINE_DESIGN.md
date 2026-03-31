# Natsume 引擎化设计方案

> 状态：设计中
> 日期：2026-03-31

## 背景

当前 Natsume 更接近一个 Godot 插件库——用户需要自己搭场景树、写 bootstrap 脚本配置路径。
目标是转型为 **KiriKiri 式的完整 AVG 引擎**：安装插件 → 放素材和剧本 → 写配置文件 → 即可运行。

## 设计原则

1. **零代码可用** — 不写 GDScript 就能做出完整 AVG 游戏
2. **渐进式定制** — 从配置文件到继承场景到完全自建，用户按需选择深度
3. **插件升级安全** — 用户的定制不在 `addons/natsume/` 里，升级不会覆盖

---

## 用户视角：做一个游戏需要什么

### 最简情况（零代码）

```
my_game/
├── addons/natsume/          ← 安装插件（不需要改动）
├── art/
│   ├── backgrounds/         ← 背景图
│   └── characters/          ← 立绘（按角色名分目录）
│       ├── sakura/
│       │   ├── default.png
│       │   ├── happy.png
│       │   └── sad.png
│       └── senpai/
│           └── default.png
├── audio/
│   ├── bgm/                 ← 背景音乐
│   ├── se/                  ← 音效
│   └── voice/               ← 配音
├── scenarios/
│   └── main.nat             ← 剧本
└── natsume.cfg              ← 配置文件
```

### natsume.cfg 示例

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

所有字段都有默认值。如果目录结构遵循约定，大部分配置可以省略：

```ini
[game]
title = "我的视觉小说"
scenario = "res://scenarios/main.nat"
```

---

## 三层定制体系

### Level 1：配置定制（natsume.cfg）

适合大部分用户。通过配置文件控制：

- 游戏标题
- 素材目录路径
- 功能开关（CG 鉴赏、回想模式等）
- 存档槽位数量
- 对话速度、音量等默认值

### Level 2：继承场景（Inherited Scene）

适合需要调整 UI 布局的用户。Godot 原生支持场景继承：

1. 在编辑器中右键 `addons/natsume/scenes/game.tscn` → 新建继承场景
2. 保存为 `res://scenes/my_game.tscn`
3. 在继承场景中调整节点属性（对话框位置、角色槽位数量等）
4. 在 `natsume.cfg` 中指定覆盖：

```ini
[overrides]
game_scene = "res://scenes/my_game.tscn"
```

优点：只保存与基础场景的 diff，插件升级时基础场景的改动会自动继承。

### Level 3：完全自建

适合有 Godot 经验的开发者。可以：

- 从零搭建游戏场景，只要节点名和结构符合 Presenter 的预期
- 继承框架脚本，覆写行为
- 注册自定义 CommandHandler 扩展 DSL 命令
- 完全不用内置 UI，自己实现 Presenter

---

## 内置场景结构

### title.tscn — 标题画面

引擎内置的默认标题画面。按钮根据 natsume.cfg 中的 `[features]` 配置动态生成：

| 按钮 | 显示条件 |
|------|---------|
| 开始游戏 | 始终显示 |
| 继续游戏 | 存在存档时显示 |
| CG 鉴赏 | `features.cg_gallery = true` |
| 设置 | 始终显示 |
| 退出 | 始终显示 |

### game.tscn — 游戏主场景

引擎内置的游戏运行场景，包含完整的图层结构：

```
Game (Node2D)
├── BackgroundLayer (CanvasLayer, layer=0)
│   ├── BgFront (TextureRect)
│   └── BgBack (TextureRect)
├── CharacterLayer (CanvasLayer)
│   ├── SlotLeft (Control)
│   ├── SlotCenter (Control)
│   └── SlotRight (Control)
├── FadeLayer (CanvasLayer, layer=2)
│   └── FadeOverlay (ColorRect)
├── UILayer (CanvasLayer, layer=3)
│   ├── DialoguePanel — 对话框 + 工具栏
│   ├── ChoicePanel — 选项面板
│   ├── BacklogScreen — 回想记录
│   ├── SaveLoadScreen — 存档/读档
│   └── SettingsScreen — 设置
├── InputHandler (Node)
├── ScreenEffects (Node)
└── AudioPresenter (Node)
```

用户不需要了解这个结构，除非想做 Level 2/3 的定制。

---

## 角色系统

角色**不绑定场景**，完全通过目录约定和剧本命令驱动：

### 添加角色

1. 在 `characters/` 下创建以角色名命名的目录
2. 放入表情立绘（`default.png`, `happy.png`, `sad.png` 等）
3. 在 `.nat` 剧本中直接使用：

```
@show sakura center
sakura「こんにちは！」
@expr sakura happy
sakura「今日はいい天気ですね！」
```

### 高级角色配置（可选）

如需分层立绘（身体 + 表情分离）或自定义名字颜色，创建角色配置文件：

```
characters/
└── sakura/
    ├── config.json       ← 可选的角色配置
    ├── body.png
    ├── face_default.png
    ├── face_happy.png
    └── face_sad.png
```

---

## 启动流程

```
Godot 启动
  → 加载 Autoload: SignalBus, NatsumeRuntime
  → NatsumeRuntime._ready()
      → 初始化子系统（SaveManager, SettingsManager, ScenarioEngine 等）
      → 读取 res://natsume.cfg（不存在则用默认值）
      → 设置素材路径、功能开关
  → 加载 Main Scene: addons/natsume/scenes/title.tscn
      → TitleScreen 从 NatsumeRuntime.config 读取标题和功能配置
      → 动态生成按钮
  → 用户点击「开始游戏」
      → NatsumeRuntime.start_game()
      → 切换到 game.tscn
      → 解析并运行 .nat 剧本
```

---

## 改动范围

### 新建

| 文件 | 说明 |
|------|------|
| `addons/natsume/core/config/natsume_config.gd` | 配置文件加载器 |
| `addons/natsume/scenes/game.tscn` | 内置游戏场景（从 examples 移入） |
| `addons/natsume/scenes/title.tscn` | 内置标题场景（从 examples 移入） |
| `natsume.cfg` | Demo 项目的配置文件 |

### 修改

| 文件 | 说明 |
|------|------|
| `natsume_runtime.gd` | 加载 config，简化 start_game API |
| `title_screen.gd` | 从 config 读取标题和功能开关 |
| `save_load_screen.gd` | 存档槽位数从 config 读取 |
| `natsume_plugin.gd` | 激活时自动设置 main scene |
| `project.godot` | main scene 指向内置标题场景 |

### 删除

| 文件 | 说明 |
|------|------|
| `examples/demo/scenes/` | 场景已移入插件 |
| `examples/demo/scripts/bootstrap.gd` | 被 natsume.cfg 取代 |

---

## 向后兼容

旧的 bootstrap.gd 手动设置路径的方式仍然可用。NatsumeRuntime 检测到无 natsume.cfg 且路径被手动修改时，输出 `push_warning` 提示迁移。
