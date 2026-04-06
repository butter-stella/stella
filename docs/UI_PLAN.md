# Stella — 用户交互 UI 实现计划

## Context

Core 层已全部完成（存档、设置、播放控制、Backlog、状态机），需要补全用户交互 UI。用户通过对话框底部工具栏访问所有功能。

---

## 1. 对话框底部工具栏

对话框底部增加一排功能按钮，作为所有 UI 的入口。这是 Galgame 的标准交互模式。

**按钮布局（从左到右）：**
```
[自动] [快进] [Backlog] [快存] [快读] [存档] [读档] [设置]
```

**功能：**
- **自动** — 切换自动播放（AutoPlayController.toggle()），激活时按钮高亮
- **快进** — 切换快进（SkipController.toggle()），激活时按钮高亮
- **Backlog** — 打开对话历史（→ BACKLOG 状态）
- **快存** — 一键存到固定槽位（slot 0），无需打开存档界面
- **快读** — 一键从固定槽位（slot 0）读取，无需打开读档界面
- **存档** — 打开存档界面（→ SAVE_LOAD 状态，存档模式）
- **读档** — 打开读档界面（→ SAVE_LOAD 状态，读档模式）
- **设置** — 打开设置界面（→ SETTINGS 状态）

**隐藏 UI：** 右键隐藏对话框和工具栏，再次右键或左键恢复。

**对话框布局变更：**
```
DialoguePanel
├── MarginContainer
│   └── VBox
│       ├── NameLabel
│       ├── TextLabel
│       └── Toolbar (HBoxContainer)
│           ├── AutoBtn
│           ├── SkipBtn
│           ├── BacklogBtn
│           ├── QuickSaveBtn
│           ├── QuickLoadBtn
│           ├── SaveBtn
│           ├── LoadBtn
│           └── SettingsBtn
```

---

## 2. Backlog UI（对话历史）

- 全屏半透明面板，ScrollContainer + VBoxContainer 显示对话历史
- 每条记录：角色名（彩色）+ 对话文本
- 鼠标滚轮滚动
- 点击空白处 / ESC 关闭 → 回到 PLAYING
- 数据来源：BacklogManager.get_entries()
- DialogueHandler 执行时自动写入 BacklogManager

---

## 3. 存档/读档 UI

- 全屏面板，网格布局 8 个存档槽位
- 每个槽位：槽位号 + 时间戳（或"空"）
- 存档模式：点击空槽保存，点击已有槽确认覆盖
- 读档模式：点击已有槽加载
- 顶部 Tab 切换存档/读档
- ESC 关闭
- 数据来源：SaveManager.save() / load_save() / get_save_list()

---

## 4. 设置 UI

- 全屏面板，竖向排列设置项
- 文字速度：HSlider（character_interval 0-100ms）
- 自动播放延迟：HSlider（0.5-5.0s）
- BGM 音量：HSlider（0-100%）
- SE 音量：HSlider（0-100%）
- 语音音量：HSlider（0-100%）
- 全屏切换：CheckButton
- 重置默认按钮
- ESC 关闭
- 修改实时生效（SettingsManager.set_value() → settings_changed 信号）

---

## 5. 标题画面

- 全屏画面，游戏标题 + 按钮列表
- 按钮：开始游戏、继续游戏（最近存档）、读档、设置、退出
- GameStateMachine 初始状态 TITLE → 点击"开始" → PLAYING
- 剧本结束后（scenario_ended）回到标题画面

---

## 场景树变更

```
Main (Node2D)
├── BackgroundLayer (CanvasLayer, layer=0)
├── CharacterLayer (CanvasLayer, layer=1)
├── UILayer (CanvasLayer, layer=2)
│   ├── DialoguePanel          ← 已有，底部增加 Toolbar
│   ├── ChoicePanel             ← 已有
│   ├── FadeOverlay             ← 已有
│   ├── BacklogScreen           ← 新增
│   ├── SaveLoadScreen          ← 新增
│   └── SettingsScreen          ← 新增
├── TitleScreen (CanvasLayer, layer=3)  ← 新增
├── InputHandler
├── ScreenEffects
├── AudioPresenter
└── Bootstrap
```

## 关键架构决策

1. **工具栏是对话框的一部分**，不是独立面板
2. **GameStateMachine 驱动 UI 切换**：PLAYING ↔ BACKLOG / SAVE_LOAD / SETTINGS
3. **所有 overlay UI（Backlog/存档/设置）暂停引擎**，关闭时恢复
4. **StellaRuntime 集中初始化子系统**：SaveManager、SettingsManager、BacklogManager
5. **UI 是框架默认实现**，用户可替换

## Demo 实装

所有 UI 功能完成后，必须在 `examples/demo/` 中完整实装：

- 内置 `game.tscn` + `title.tscn` 场景树包含所有 UI 节点（Toolbar、Backlog、存档/读档、设置、标题画面）
- `stella.cfg` 配置文件指定素材路径和功能开关
- `demo.stl` 确保包含足够的对话量以测试 Backlog 和存档/读档
- F5 运行即可体验完整游戏循环

## 验证标准

完整循环：标题 → 开始 → 对话 → 工具栏操作（自动/快进/Backlog/快存/快读/存档/读档/设置/右键隐藏UI） → 剧本结束 → 标题
