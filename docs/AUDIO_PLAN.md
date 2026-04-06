# 音频系统完善计划

## 现状分析

| 组件 | 状态 | 说明 |
|------|------|------|
| BGM Handler + Presenter | ✅ 已实现 | 淡入淡出、OGG/MP3 |
| SE Handler + Presenter | ⚠️ 部分 | loop 参数未生效 |
| Voice Handler | ❌ 未实现 | 信号/设置已定义，无处理器 |
| DSL `@voice` 命令 | ❌ 未实现 | 解析器未支持 |
| 对话语音联动 | ❌ 未实现 | `_voice` 参数被忽略 |
| 音量设置应用 | ❌ 未实现 | 所有播放器都在 Master bus，不受设置控制 |
| Backlog 语音重播 | ❌ 未实现 | BacklogManager 已存 voice 字段，但 UI 无重播按钮 |

## 实现计划

### 1. VoiceHandler（Core 层）

新建 `addons/stella/core/commands/voice_handler.gd`：

```gdscript
class_name VoiceHandler extends CommandHandler

func get_command_type() -> String:
    return "voice"

func execute(data: CommandData, _context: ScenarioContext) -> void:
    var asset = data.get_string("asset", "")
    SignalBus.voice_play.emit(asset)
```

在 `stella_runtime.gd:_register_handlers()` 中注册。

### 2. DSL 解析器 — `@voice` 命令

编辑 `dsl_parser.gd`，在命令 switch 中添加：

```gdscript
"voice":
    return _make_cmd("voice", {
        "asset": parts[0] if parts.size() > 0 else "",
    })
```

### 3. 对话语音联动

编辑 `dialogue_presenter.gd:_on_show_dialogue()`：

当 `voice != ""` 时，发射 `SignalBus.voice_play.emit(voice)` 触发语音播放。

### 4. AudioPresenter — 语音播放

编辑 `audio_presenter.gd`，添加：

- `_voice_player: AudioStreamPlayer`（Voice bus）
- 连接 `voice_play` 信号 → 加载并播放语音文件
- 连接 `advance_requested` → 停止语音（除非 `voice_continue_on_advance`）
- 播放结束时发射 `voice_finished` 信号
- 文件探测：`.ogg` → `.wav`

### 5. 音量集成

编辑 `audio_presenter.gd`：

- `_ready()` 时读取 GameSettings 音量值，通过 `linear_to_db()` 转换应用
- 监听 `SignalBus.settings_changed` 信号，动态更新音量
- 计算公式：`linear_to_db(master_volume * category_volume)`
- 语音额外检查 `character_voice_volume` / `character_voice_enabled`

### 6. 语音重播

#### 6a. 对话框工具栏重听按钮

编辑 `dialogue_presenter.gd`：

- 在工具栏按钮列表中添加 `{"id": "voice_replay", "text": "重听", "callback": _on_voice_replay_pressed}`
- 记录当前对话的 voice asset（`_current_voice: String`）
- `_on_voice_replay_pressed()` → `SignalBus.voice_play.emit(_current_voice)`
- 仅当 `_current_voice != ""` 时按钮可见/可用

#### 6b. Backlog 语音重播按钮

编辑 `backlog_screen.gd:_populate()`：

- 当 `entry["voice"] != ""` 时，在条目旁添加一个重播按钮（▶）
- 点击按钮 → `SignalBus.voice_play.emit(entry["voice"])`
- 受 `voice_replay_on_backlog` 设置控制（设置为 false 时不显示按钮）

### 7. 系统 SE（UI 音效）

新建/编辑系统 SE 播放逻辑：

- 提供一个全局可调用的系统 SE 播放方法（如 `StellaRuntime.play_system_se(asset: String)`）
- 常见触发点：
  - 对话推进（点击/Enter）
  - 按钮悬停、点击
  - 选项确认
  - 存档/读档操作
- 音效资源路径：`StellaRuntime.se_path` 下的系统音效文件
- 独立音量控制：受 `system_se_volume` 设置
- 可配置：通过 `stella.cfg` 或代码指定各事件对应的音效文件名

## 涉及文件

| 文件 | 操作 |
|------|------|
| `addons/stella/core/commands/voice_handler.gd` | 新建 |
| `addons/stella/core/script_parser/dsl_parser.gd` | 添加 @voice 命令 |
| `addons/stella/presentation/dialogue/dialogue_presenter.gd` | 接入语音信号 |
| `addons/stella/presentation/audio/audio_presenter.gd` | 语音播放 + 音量 + SE loop |
| `addons/stella/autoload/stella_runtime.gd` | 注册 VoiceHandler |
| `tests/unit/test_audio_controllers.gd` | 语音测试 |
| `addons/stella/presentation/ui/backlog_screen.gd` | 语音重播按钮 |
| `tests/unit/test_dsl_parser.gd` | @voice 解析测试 |

## TDD 流程

1. **Red**：编写 VoiceHandler 信号发射测试 + `@voice` DSL 解析测试
2. **Green**：实现 VoiceHandler + 解析器 + 注册
3. **Red**：编写对话语音联动测试
4. **Green**：实现对话语音联动
5. **实现** AudioPresenter 语音播放、音量集成、SE loop 修复
6. **实现** Backlog 语音重播按钮
7. **Refactor**：整理代码，确保测试全绿
