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
  1. active choice？→ Button/Slider 交给 GUI；非 PLAYING return；其余背景左键只按策略停止 Skip 或 Auto，并消费，绝不进入隐藏/typewriter/wait fallback
  2. UI 隐藏？→ 恢复 UI + set_input_as_handled
  3. 鼠标下有交互控件（Button/Slider）？→ return，让 GUI 处理
  4. 非 PLAYING？→ return；否则执行 Skip/Auto 的既有点击策略
  5. 普通模式且打字中？→ 实时读取 click_to_complete；true 时原子补全，false 时保持打字状态；两者都 set_input_as_handled（消费事件）
  6. 否则 → 当前 pending `DialogueRequest.advance()`；若没有 Dialogue owner，广播一次语义 advance，交给当前 Stage/Presentation JOIN、chapter indicator、loop-SE、BGM 或 `@wait click`/可跳过定时 `@wait`

_unhandled_input:
  active choice 先消费未被 GUI option Button 的 ui_accept 接受的空格/回车/手柄 A；否则键盘与手柄 A 在 UI 隐藏时先恢复并消费输入，再检查 PLAYING，最后进入与左键相同的 live click_to_complete 门槛或推进。Ctrl 沿用独立的快进按下/释放策略
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

- `_input`：处理所有鼠标事件（左键进入正常推进门槛、右键隐藏 UI）
- `_unhandled_input`：处理键盘与手柄事件（隐藏时先恢复 UI；否则空格/回车/手柄 A 进入同一推进门槛、Ctrl 快进）
- 通过 `%DialoguePanel` 访问 DialoguePresenter 的状态

InputHandler 还在所有 story fallback 之前查询当前 choice policy session。Option/toolbar
Button 和 Slider 继续由 GUI 处理；其余四种 normal advance 输入由 modal choice 消费，
不会补全文字、恢复隐藏对话或解除 wait，也不会隐式选择第一项。

### DialoguePresenter (`presentation/dialogue/dialogue_presenter.gd`)

纯展示，零输入处理代码。暴露打字、临时隐藏和 Ctrl 快进状态；InputHandler 把事件时的策略传给 `consume_typewriter_advance(allow_completion)`，由 Presenter 在一次同步调用中判断当前是否仍在打字。允许补全时，它统一退休尚未结束的字符基础间隔、标点停顿与 `{wait}` 计时，应用最终表情并进入 ready；不允许时只确认当前 typewriter 拥有这次输入，不修改 visible boundary、generation 或 timer。`complete_typewriter()` 仍是 Skip 和扩展代码使用的强制完成 API，不读取 `click_to_complete`。字符间隔和标点停顿在每条 active SHOW 开始时从 settings-backed cache 一次性快照，因此输入完成与设置变更都不会让旧行的 timer 穿越到下一句。

Presenter 同时观察 `AutoPlayController` / `SkipController` 的状态变化，因此内置工具栏、`StellaAction` 与 `StellaRuntime.toggle_auto_play()` / `toggle_skip()` 共享同一条完成路径：ready 状态开启快进会在允许跳过时立即确认当前 request；`skip_only_read=true` 时 ready 但尚未确认的行仍属未读，快进会停在该行。开启自动播放会进入配置的 voice-wait 与 delay tail，而不是只改变按钮高亮。

Choice SHOW 会同步退休上一句的 Auto/Skip attempt 并清除 Ctrl-held，但不改写关闭
stop/pause 策略时应保留的用户 intent。菜单内 toolbar 正向切换只更新 future intent；
Presenter 在 active choice gate 下绝不让旧 ready/typewriter 建立推进 tail。Auto suspension
解除的 positive effective edge 同样不启动旧 timer，下一条 active dialogue 才创建新 tail。

### Overlay（save_load/backlog/settings）

`_input` 处理 ESC/右键关闭。Overlay 打开时 `game_state` 不是 `PLAYING`，InputHandler 的 `is_playing()` 守卫阻断键盘推进。鼠标推进被 `gui_get_hovered_control()` 检测到 overlay 上的控件而跳过。

`StellaAction.QUIT` 不进入 advance dispatch；它与标题按钮、宿主显式退出和 OS close 一样调用 `StellaRuntime.request_quit()`。OS close 先 autosave，随后 Runtime 通过唯一 AudioPresenter 退休所有音频 owner，并等待真实 AudioServer mix + 主线程 cleanup boundary；重复 UI/OS 请求不会创建第二个退出或等待 owner。

## 打字完成 vs 推进

默认的 AVG 行为是：打字未完成时正常推进输入 = 完成打字（不推进），打字完成后下一次输入 = 推进。`click_to_complete=false` 会把第一条规则改成“只消费输入、继续打字”；自然完成后，下一次输入仍正常推进。

实现：左键、Space、Enter 和手柄 A 每次进入正常推进路径时都重新读取 `click_to_complete`，不会对 active line 做策略快照。Presenter 的原子 gate 返回“该 typewriter 是否消费了输入”：`true` 策略会同步取消旧的字符/等待协程、应用最终头像状态，并把当前对话剩余的 `@combine` 舞台操作按声明顺序归约后以 cut 投影；`false` 策略保持所有打字状态。两种结果都由输入层立即 `set_input_as_handled()`，绝不落入 owner/global advance；只有 gate 表明已经 ready 时，才确认当前 request 或发送兼容 advance，并同样消费事件。UI 隐藏恢复、Button/Slider、非 PLAYING，以及左键的 Skip/Auto 策略仍先于这个门槛处理。仅完成打字不会把该行标为已读；`DialogueHandler` 在当前 request 的 `DialogueActivation` 被正常确认、且 engine/context owner 仍有效后写入已读记录，中止则保持未读并终止当前 context，因此无界面执行也遵守相同语义。Presenter 的输入、Auto 与 Skip 都调用当前 `DialogueRequest.advance()`；Core 提交已读后先发送带 activation identity 的内建完成事件，再广播无参数 `advance_requested` 作为扩展/音频兼容通知。若 Presenter 没有 pending dialogue activation，输入层改发该无参通知，交给当前 Director-owned blocker 或 `@wait click`/`skippable=true` 的定时等待。WaitHandler 与各 Presenter 都用 dispatch serial 拒绝旧 signal tail，因此一次真实推进最多完成一个 blocking command。typed owner 被新 SHOW、hard hide 或生命周期边界替换时，Presenter 会在清除其可达性前 `abort()`，不会留下只能由旧 UI 完成的 Core waiter；若 abort 回调同步发布更新的 SHOW/HIDE，使正在接受的外层 request 失去 current/queue 所有权，该 incoming request 也会被明确 abort。扩展直接广播旧信号不会完成任何 DialogueHandler waiter，也不会误推进另一个 activation。

## Chapter indicator fade 与一次输入边界

当没有 pending dialogue owner、当前 sealed Director JOIN 含有 `@chapter_indicator ... transition=fade` 时，普通左键、Space、Enter 和手柄 A 仍走同一 `advance_requested` 语义：只把这个 owner 的 exact receipts snap 到 authored final state，并消费该次输入。toolbar Skip 开启也只 finish 当前 exact owner；Auto 状态本身不会自动结束 indicator。

每个 Presenter 在接受 request 时记录 `SignalBus` 的 advance dispatch serial。若第一位 Presenter 的 acknowledgement 同步推进引擎并创建下一条 indicator，后一位 Presenter 收到的仍是旧 signal tail；新 request 的接受 serial 与当前 dispatch 相同，因此它必须拒绝这次旧 tail。结果是一次 physical/semantic advance 最多完成一个 blocking command，不会把 chained fade 一起跳过。

## Presentation JOIN 与一次推进边界

当没有 pending Dialogue owner，且当前 blocking presentation 使用 `policy=join` 时，左键、Space、Enter 和手柄 A 进入同一个 `SignalBus` semantic advance boundary。`PresentationDirector` 只向最新 current 且已 sealed JOIN 的五元 exact receipts 发送 finish；对应 Stage、dialogue、chapter 或 Audio Presenter 将每个仍属于该 owner 的转场 snap 到 authored endpoint，再只 acknowledgement 一次。同一 advance serial 的旧 signal tail 不得完成同栈新建的下一 batch 或 Dialogue；late timer、input 或 terminal 也不得推进已替换的 tail。

`@dialogue_clear` 是同步的 dialogue-content 生命周期边界，不等待 wall-clock，也不把普通
advance 当成清空确认。它只使旧 typewriter/voice/inline cue callback 失效；已由独立 Stage
或 mixed presentation owner seal 的 transition 仍由该 owner 接收 input/Skip completion，
clear 不得冒领或取消它。

standalone Stage 与 `FIRE_AND_FORGET` 从不 claim advance，也不消费、重放普通 advance，下一句 click 不能被旧的 rule-mask/mosaic Tween 领取。Auto 状态本身也不结束 JOIN。Skip 从 false 激活为 true 时，只 exact-finish 当前 owner 一次；Skip 已 active 时新 batch 仍先通过 participant seal，再按持续模式 policy 直接 force-cut，不创建 projection snapshot/Tween。普通输入的“一次只结束一个 owner”与持续 Skip policy 是两个不同的边界。

Stage、chapter indicator、dialogue visibility、loop-SE 和固定 `bgm:main` 共享 Director-owned generic blocking presentation waiter。reset、load、rollback、restart、return-to-title 或 context replacement 先退休旧 owner/generation，再重置或 cut canonical 投影；不存在 audio/indicator/stage 并列的私有 scheduler/flag，旧 callback 也不能回来领取新 input。单纯 AudioPresenter replacement 只退休旧音频投影并从 canonical channel+position+stem mix 唯一重投影，不把 persistent channel 当成 session state 清空。BGM play/mix/pause/resume/stop receipt 被 context/global abort 取消时会 cut 到已经原子提交的 stable target，不能留下仍在 Tween 的无 owner player 或 stem gain。

`surface`、`quick_menu`、`chapter:indicator`、`loop_se:<channel>` 与 `bgm:main` 在同一个 Director queue 上分配 request/receipt/generation，并和 Stage mixed batch 共用 exact finish、persistent Skip force-cut、save/load projection restore 与 stale callback 拒绝规则。mixed batch 先全量 preflight/seal（包括 loop-SE/BGM resource、cue、stem metadata 和完整 loop-region validation），后按 authored child order apply；dispatch tail 的 Skip 也只能结束这一个 sealed owner。Profile baseline、mode binding 与 canonical gate 是声明式合成关系；backlog overlay 与 soft UI hide 不会修改这些 canonical bool 或 audio channels。

既有输入优先级保持不变：soft-hidden UI 先恢复，Button/Slider 左键交给 GUI，非 PLAYING 不处理；Skip/Auto 的既有左键 policy 先于普通推进。成功进入 normal path 后，无论是 typed dialogue advance、Presentation JOIN、可跳过 timed wait 还是 `@wait click` 都会 `set_input_as_handled()`。左键、Space、Enter 与手柄 A 进入同一个 advance dispatch serial；#133 的可重绑输入系统仍是后续工作。

## Timed wait 与一次推进边界

`@wait <seconds> skippable=true` 复用上述普通 advance 信号，不在 InputHandler 里建立私有 timer 或第二套输入路由。WaitHandler 安装时记录当前 advance serial；只有更新的 serial 可以赢得 timer/input/cancellation race，所以同一 physical input 的兼容 signal tail 无法结束同步开始的下一条 wait。timer 先到、输入先到、Skip 激活或 context cancellation 都会原子退休其余 listener。`skippable=false`（默认）不连接 advance/Skip，只等待 timer 或 engine cancellation；Auto 不生成这类 owner completion。
