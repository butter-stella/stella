# 输入系统设计

## 核心矛盾

AVG 游戏需要"点击任意位置推进剧本"，但工具栏按钮（自动、快进、存档等）点击时不应推进。

Godot 的输入传播顺序：`_input` → GUI (`_gui_input`) → `_unhandled_input`

- **`_unhandled_input`** 是 Godot 推荐的游戏输入处理方式，按钮的 `MOUSE_FILTER_STOP` 会自动消费点击，`_unhandled_input` 不会触发。但 AVG 游戏场景中有大量装饰性 Control 节点（背景 TextureRect、舞台图片等），它们默认 `STOP` 也会消费鼠标事件，导致 `_unhandled_input` 收不到任何鼠标点击。
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
  键盘（空格/回车/Ctrl）→ UI 隐藏时先恢复并消费按键，否则正常处理
```

### 为什么 `gui_get_hovered_control()` 有效

- 返回鼠标位置下的最顶层 Control（上一帧 GUI 路由结果）
- 鼠标在点击时位置不变，所以上一帧的结果就是当前帧的目标
- 在 `_input` 中调用，**确定性**判断，不依赖时序、信号、defer

### 为什么不用其他方案

| 方案 | 问题 |
|------|------|
| `_unhandled_input` | 背景/舞台图片等装饰 Control 的 `STOP` 消费鼠标，收不到事件 |
| 给装饰节点设 `MOUSE_FILTER_IGNORE` | 用户自定义场景时容易遗漏或冲突 |
| 全屏透明 ColorRect 浮层 | 对话框子节点仍然 STOP 挡住浮层 |
| `_input` + `call_deferred` / `_process` | 按钮回调时序不确定，headless 模式下 GUI 不触发 |
| `_input` + 信号标记取消 | 同上时序问题 |
| `_input` + `is_playing()` 状态检查 | Auto/Skip/QuickSave 不改状态，仍会推进 |

## 组件职责

### InputHandler (`presentation/input/input_handler.gd`)

普通 Node，挂在 game 场景中。

- `_input`：处理所有鼠标事件（左键推进/完成打字、右键隐藏 UI）
- `_unhandled_input`：处理键盘事件（隐藏时先恢复 UI；否则空格/回车推进、Ctrl 快进）
- 通过 `%DialoguePanel` 访问 DialoguePresenter 的状态

### DialoguePresenter (`presentation/dialogue/dialogue_presenter.gd`)

纯展示，零输入处理代码。暴露打字、临时隐藏和 Ctrl 快进状态；InputHandler 通过 `complete_typewriter()` 请求同步完成当前句，由 Presenter 统一取消尚未结束的字符/`{wait}` 计时、应用最终表情并进入 ready 状态，避免输入层直接改字段后留下旧协程。

Presenter 同时观察 `AutoPlayController` / `SkipController` 的状态变化，因此内置工具栏、`StellaAction` 与 `StellaRuntime.toggle_auto_play()` / `toggle_skip()` 共享同一条完成路径：ready 状态开启快进会立即推进，开启自动播放会进入配置的 voice-wait 与 delay tail，而不是只改变按钮高亮。

### Overlay（save_load/backlog/settings）

`_input` 处理 ESC/右键关闭。Overlay 打开时 `game_state` 不是 `PLAYING`，InputHandler 的 `is_playing()` 守卫阻断键盘推进。鼠标推进被 `gui_get_hovered_control()` 检测到 overlay 上的控件而跳过。

## 打字完成 vs 推进

AVG 标准行为：打字未完成时点击 = 完成打字（不推进），打字完成后点击 = 推进。

实现：`_input` 调用 Presenter 的 `complete_typewriter()`，由 Presenter 同步取消旧的字符/等待协程、应用最终头像状态，并把当前对话剩余的 `@combine` 舞台操作按声明顺序归约后以 cut 投影。成功后输入层再用 `set_input_as_handled()` 消费事件，因此既不会同时推进，也不会留下跨到下一句的 Tween。已完成的对话直接通过 `SignalBus.emit_advance_requested()` 广播原有无参数 `advance_requested` 信号；SignalBus 的 pre-dispatch hook 在同一次原子推进内先收束该行所属的舞台与语音状态，再把信号交给剧情引擎。这个 hook 同样覆盖扩展代码直接调用 `advance_requested.emit()` 的兼容路径，并避免收束回调同步展示的新台词又被输入层随后发出的 `advance_requested` 误清。
