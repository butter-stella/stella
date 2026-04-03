# 输入系统设计

## 核心矛盾

AVG 游戏需要"点击任意位置推进剧本"，但工具栏按钮（自动、快进、存档等）点击时不应推进。

Godot 的输入传播顺序：`_input` → GUI (`_gui_input`) → `_unhandled_input`

- **`_unhandled_input`** 是 Godot 推荐的游戏输入处理方式，按钮的 `MOUSE_FILTER_STOP` 会自动消费点击，`_unhandled_input` 不会触发。但 AVG 游戏场景中有大量装饰性 Control 节点（背景 TextureRect、立绘 Slot 等），它们默认 `STOP` 也会消费鼠标事件，导致 `_unhandled_input` 收不到任何鼠标点击。
- **`_input`** 能收到所有事件，但在 GUI 之前执行，无法知道当前点击是否会命中按钮。

## 解决方案

使用 `_input` + `gui_get_hovered_control()` 确定性检测。

```
_input:
  1. 鼠标下有交互控件（Button/Slider）？→ return，让 GUI 处理
  2. 打字中？→ 完成打字 + set_input_as_handled（消费事件）
  3. UI 隐藏？→ 恢复 UI + set_input_as_handled
  4. 否则 → advance_requested（推进剧本）

_unhandled_input:
  键盘（空格/回车/Ctrl）→ 不受 mouse_filter 影响，正常处理
```

### 为什么 `gui_get_hovered_control()` 有效

- 返回鼠标位置下的最顶层 Control（上一帧 GUI 路由结果）
- 鼠标在点击时位置不变，所以上一帧的结果就是当前帧的目标
- 在 `_input` 中调用，**确定性**判断，不依赖时序、信号、defer

### 为什么不用其他方案

| 方案 | 问题 |
|------|------|
| `_unhandled_input` | 背景/立绘等装饰 Control 的 `STOP` 消费鼠标，收不到事件 |
| 给装饰节点设 `MOUSE_FILTER_IGNORE` | 用户自定义场景时容易遗漏或冲突 |
| 全屏透明 ColorRect 浮层 | 对话框子节点仍然 STOP 挡住浮层 |
| `_input` + `call_deferred` / `_process` | 按钮回调时序不确定，headless 模式下 GUI 不触发 |
| `_input` + 信号标记取消 | 同上时序问题 |
| `_input` + `is_playing()` 状态检查 | Auto/Skip/QuickSave 不改状态，仍会推进 |

## 组件职责

### InputHandler (`presentation/input/input_handler.gd`)

普通 Node，挂在 game 场景中。

- `_input`：处理所有鼠标事件（左键推进/完成打字、右键隐藏 UI）
- `_unhandled_input`：处理键盘事件（空格/回车推进、Ctrl 快进）
- 通过 `%DialoguePanel` 访问 DialoguePresenter 的状态

### DialoguePresenter (`presentation/dialogue/dialogue_presenter.gd`)

纯展示，零输入处理代码。暴露 `_is_typing`、`_ui_hidden`、`_ctrl_held` 状态供 InputHandler 读写。

### Overlay（save_load/backlog/settings）

`_input` 处理 ESC/右键关闭。Overlay 打开时 `game_state` 不是 `PLAYING`，InputHandler 的 `is_playing()` 守卫阻断键盘推进。鼠标推进被 `gui_get_hovered_control()` 检测到 overlay 上的控件而跳过。

## 打字完成 vs 推进

AVG 标准行为：打字未完成时点击 = 完成打字（不推进），打字完成后点击 = 推进。

实现：`_input` 中打字完成调用 `set_input_as_handled()` 消费事件，阻止后续 GUI 处理和推进。
