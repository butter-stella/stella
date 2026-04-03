# Natsume API 驱动 UI 设计方案

> 状态：设计中
> 日期：2026-04-03

## 背景

当前表现层（Presentation Layer）直接深入 NatsumeRuntime 的子系统对象调用方法：

```gdscript
# 用户要写这样的代码来实现一个快存按钮
NatsumeRuntime.save_manager.save(0)

# 切换到存档画面
NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)

# 开关自动播放
NatsumeRuntime.auto_play.toggle()
```

问题：
1. 用户需要了解内部子系统结构才能搭建自己的 UI
2. 子系统接口是为框架内部设计的，不是面向用户的
3. demo 使用内置场景，用户无法从 demo 学到"怎么搭自己的游戏"

## 设计目标

1. **NatsumeRuntime 提供简洁的 Facade API** — 用户只需要知道一个对象
2. **demo 用用户模式运行** — 自建游戏场景 + 调用 API，作为用户的项目模板
3. **内置场景降级为参考实现** — 仍然保留，但 demo 不依赖它

---

## Facade API 设计

在 NatsumeRuntime 上封装面向用户的便捷方法：

### 游戏流程

```gdscript
# 已有，保持不变
NatsumeRuntime.start_game()
NatsumeRuntime.load_game(slot_id)
NatsumeRuntime.return_to_title()
```

### 存档/读档

```gdscript
NatsumeRuntime.save(slot_id: int) -> void
NatsumeRuntime.load(slot_id: int) -> bool
NatsumeRuntime.has_save(slot_id: int) -> bool
NatsumeRuntime.delete_save(slot_id: int) -> void
NatsumeRuntime.get_save_list() -> Array
NatsumeRuntime.quick_save() -> void           # save(0)
NatsumeRuntime.quick_load() -> bool           # continue_from_save(0)
```

### 播放控制

```gdscript
NatsumeRuntime.toggle_auto_play() -> void
NatsumeRuntime.toggle_skip() -> void
NatsumeRuntime.is_auto_playing() -> bool
NatsumeRuntime.is_skipping() -> bool
```

### UI 状态切换

```gdscript
NatsumeRuntime.show_backlog() -> void
NatsumeRuntime.show_save_load(mode: String = "save") -> void
NatsumeRuntime.show_settings() -> void
NatsumeRuntime.close_overlay() -> void        # return_to_previous
```

### 回想记录

```gdscript
NatsumeRuntime.get_backlog() -> Array
```

### 设置

```gdscript
NatsumeRuntime.get_setting(key: String) -> Variant
NatsumeRuntime.set_setting(key: String, value: Variant) -> void
NatsumeRuntime.save_settings() -> void
```

> 子系统对象（save_manager、settings_manager 等）仍然公开，高级用户可以直接使用。
> Facade 方法只是便捷封装，不添加新逻辑。

---

## Overlay 管理

设置、存档/读档、Backlog、CG 鉴赏等 overlay 画面需要在标题和游戏中都能打开。
不能把它们绑死在 game.tscn 里。

### 设计

- Overlay 画面是**独立场景文件**（`settings.tscn`、`save_load.tscn` 等）
- NatsumeRuntime 管理 overlay 生命周期：打开时 `instantiate()` + `add_child()`，关闭时 `queue_free()`
- overlay 加到 NatsumeRuntime 自身（Autoload 节点），不依赖当前场景
- 用户可通过 `[overrides]` 替换任意 overlay 场景

### Facade API

```gdscript
NatsumeRuntime.show_settings()      # 加载 settings overlay
NatsumeRuntime.show_save_load()     # 加载存档/读档 overlay
NatsumeRuntime.show_backlog()       # 加载 backlog overlay
NatsumeRuntime.close_overlay()      # 关闭当前 overlay
```

### 内置 overlay 场景

```
addons/natsume/scenes/
├── title.tscn                ← 内置标题（参考实现）
├── game.tscn                 ← 内置游戏（参考实现）
├── settings.tscn             ← 内置设置 overlay
├── save_load.tscn            ← 内置存档/读档 overlay
└── backlog.tscn              ← 内置 backlog overlay
```

### natsume.cfg 覆盖

```ini
[overrides]
title_scene = ""
game_scene = ""
settings_scene = ""
save_load_scene = ""
backlog_scene = ""
```

### 优点

- overlay 与所在场景完全解耦，标题和游戏中都能打开
- 用户只替换想改的 overlay，其他继续用内置的
- overlay 的生命周期由框架管理，用户不需要关心加载/销毁逻辑

---

## Demo 改造

### 当前结构（引擎化后）

```
examples/demo/
├── scenarios/demo.nat
└── art/...
```

demo 依赖插件内置的 title.tscn 和 game.tscn，用户看不到"怎么搭场景"。

### 目标结构

```
examples/demo/
├── scenarios/demo.nat
├── art/...
├── scenes/
│   ├── title.tscn           ← 用户自建的标题场景
│   └── game.tscn            ← 用户自建的游戏场景
└── scripts/
    ├── title_screen.gd      ← 标题画面逻辑（调用 NatsumeRuntime API）
    └── game_screen.gd       ← 游戏画面逻辑（连接 SignalBus 信号）
```

`natsume.cfg` 通过 `[overrides]` 指定 demo 自建的场景：

```ini
[overrides]
title_scene = "res://examples/demo/scenes/title.tscn"
game_scene = "res://examples/demo/scenes/game.tscn"
```

### demo 场景的职责

**title.tscn** — 标题画面：
- 自己搭 UI（标题、按钮）
- 按钮回调调用 `NatsumeRuntime.start_game()` / `NatsumeRuntime.load_game()`

**game.tscn** — 游戏场景：
- 节点树包含对话框、立绘槽位、背景等（用 Godot 编辑器搭建）
- 挂载插件的 Presenter 脚本（BackgroundPresenter、CharacterPresenter 等）
- 工具栏按钮调用 Facade API（`NatsumeRuntime.quick_save()` 等）
- UI overlay（存档/设置/Backlog）监听 `game_state.state_changed` 信号控制显隐

### 关键原则

demo 的场景和脚本**不在 `addons/natsume/` 内**，和真实用户项目完全一致。
用户可以直接复制 `examples/demo/` 作为新项目的起点。

---

## 改动范围

### Phase 1：Facade API + Overlay 管理

| 文件 | 说明 |
|------|------|
| `natsume_runtime.gd` | 添加 Facade 方法 + overlay 生命周期管理 |
| `natsume_config.gd` | 添加 overlay 场景覆盖配置 |
| `tests/unit/test_facade_api.gd` | Facade API 测试 |

### Phase 2：Overlay 场景拆分

| 文件 | 说明 |
|------|------|
| `addons/natsume/scenes/settings.tscn` | 从 game.tscn 拆出设置 overlay |
| `addons/natsume/scenes/save_load.tscn` | 从 game.tscn 拆出存档/读档 overlay |
| `addons/natsume/scenes/backlog.tscn` | 从 game.tscn 拆出 backlog overlay |
| `addons/natsume/scenes/game.tscn` | 移除内嵌的 overlay 节点 |

### Phase 3：内置场景改用 Facade API

| 文件 | 说明 |
|------|------|
| `presentation/dialogue/dialogue_presenter.gd` | 工具栏改用 Facade API |
| `presentation/ui/title_screen.gd` | 改用 Facade API（标题页也能开设置/读档） |
| `presentation/ui/save_load_screen.gd` | 改用 Facade API |
| `presentation/ui/settings_screen.gd` | 改用 Facade API |
| `presentation/ui/backlog_screen.gd` | 改用 Facade API |

### Phase 4：Demo 改造

| 文件 | 说明 |
|------|------|
| `examples/demo/scenes/title.tscn` | 用户自建标题场景 |
| `examples/demo/scenes/game.tscn` | 用户自建游戏场景 |
| `examples/demo/scripts/title_screen.gd` | 标题画面脚本（调用 Facade API） |
| `natsume.cfg` | 添加 overrides 指向 demo 场景 |

### Phase 5：文档

| 文件 | 说明 |
|------|------|
| `docs/USAGE.md` | 更新快速上手指南 |
| `docs/ENGINE_DESIGN.md` | 更新定制体系描述 |

---

## 不做的事情

- **不删除内置场景** — 仍作为参考实现保留，新用户可以先用内置场景跑通再自建
- **不隐藏子系统对象** — 高级用户可能需要直接访问
- **不做 feature flag 控制按钮显隐** — UI 定制交给场景，不交给配置文件
