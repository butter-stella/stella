# Natsume — 使用指南

> 本文档是开发者视角的使用指南，同时作为验收标准和开发方向的参考。

## 1. 安装

通过 Unity Package Manager 的 git URL 安装：

```
https://github.com/MadCcc/Natsume.git?path=Assets/Natsume
```

或克隆仓库后将 `Assets/Natsume` 文件夹复制到自己的项目。

## 2. 最小启动（5 分钟跑通）

**Step 1** — 场景中创建一个空 GameObject，挂载入口脚本：

```csharp
// 这是唯一需要手动挂载的脚本
public class MyGameBootstrap : MonoBehaviour
{
    [SerializeField] Canvas uiCanvas;  // 拖入场景中的 Canvas

    void Awake()
    {
        // 一行启动框架，自动创建所有子系统
        NatsumeRuntime.Initialize(uiCanvas);
    }
}
```

**Step 2** — 写一段 YAML 剧本放到 `Scenarios/` 目录：

```yaml
# Scenarios/YAML/demo.yaml
meta:
  id: "demo"
  title: "Demo"

scenes:
  - id: "start"
    commands:
      - { type: bg, asset: "bg_room" }
      - { type: char_show, character: "sakura", expression: "smile", position: center }
      - { type: dialogue, character: "sakura", text: "欢迎使用 Natsume！" }
      - { type: dialogue, character: "sakura", text: "这是一个最小的示例。" }
```

**Step 3** — 运行：

```csharp
// 在 Bootstrap 或任意位置调用
var engine = ServiceLocator.Get<ScenarioEngine>();
engine.LoadScenario("demo");
engine.Start();
```

框架自动处理对话显示、立绘渲染、等待点击推进。

### 验收标准

- [ ] Bootstrap 挂载后运行不报错
- [ ] 对话文本逐字显示，点击推进到下一句
- [ ] 背景和立绘正确显示

## 3. 编写剧本

### YAML 方式（程序友好）

```yaml
scenes:
  - id: "scene_001"
    commands:
      # 背景
      - { type: bg, asset: "bg_school", transition: { type: fade, duration: 0.8 } }

      # 立绘
      - { type: char_show, character: "sakura", expression: "smile", position: left }
      - { type: char_show, character: "kaito", expression: "default", position: right }

      # 对话（支持内联标签和表情切换）
      - type: dialogue
        character: "sakura"
        text: "今天天气真好呢。{wait:300}对了，你放学后有空吗？"
        voice: "sakura_001"

      # 变量操作
      - { type: set, var: "talked_to_sakura", value: true }

      # 分支选择（style 决定展示风格）
      - type: choice
        style: "text"
        options:
          - { id: "go", label: "一起走吧", jump: "scene_go", set: { sakura_affection: "+5" } }
          - { id: "busy", label: "今天有点忙...", jump: "scene_busy" }

      # 条件跳转
      - type: condition
        if: "sakura_affection >= 10"
        then: { jump: "good_ending" }
        else: { jump: "normal_ending" }

      # 并行指令
      - type: parallel
        commands:
          - { type: bg, asset: "bg_sunset", transition: { type: dissolve, duration: 1.0 } }
          - { type: char_move, character: "sakura", position: center, duration: 0.5 }
```

### DSL 方式（编剧友好）

```
@scene scene_001
@bg bg_school fade 0.8

@show sakura smile left
@show kaito default right

sakura「今天天气真好呢。{wait:300}对了，你放学后有空吗？」 #voice:sakura_001

@set talked_to_sakura = true

@choice
  - "一起走吧" -> scene_go {sakura_affection += 5}
  - "今天有点忙..." -> scene_busy

@if sakura_affection >= 10
  @jump good_ending
@else
  @jump normal_ending
```

句内表情切换（内联标记）：

```
sakura「我本来很开心的...[expr:surprised]但是听到这个消息之后...[expr:cry]呜呜...」 #voice:sakura_ch01_042
```

### 验收标准

- [ ] YAML 剧本加载不报错，所有指令类型可执行
- [ ] DSL 剧本可转译为等价 YAML
- [ ] 分支选择跳转正确
- [ ] 条件表达式求值正确
- [ ] 并行指令同时执行

## 4. 配置角色

```yaml
# Characters/sakura.yaml
id: "sakura"
name: "樱"
name_color: "#FFB7C5"
expressions:
  smile:    { body: "sakura/body_school", face: "sakura/face_smile" }
  default:  { body: "sakura/body_school", face: "sakura/face_default" }
  cry:      { body: "sakura/body_school", face: "sakura/face_cry" }
  angry:    { body: "sakura/body_school", face: "sakura/face_angry" }
# 如果不用差分，直接给完整图路径：
#   smile: { full: "sakura/full_smile" }
voice_sample: "sakura/sample"  # 设置面板试听用
```

### 验收标准

- [ ] 角色配置加载正确
- [ ] 差分合成（body + face）显示正确
- [ ] 整张立绘模式显示正确
- [ ] 表情切换响应正常

## 5. 自定义扩展

### 添加自定义指令

```csharp
// 例：实现一个屏幕震动指令
public class ShakeCommandHandler : ICommandHandler
{
    public string CommandType => "shake";

    public async Task ExecuteAsync(CommandData data, ScenarioContext context)
    {
        float intensity = data.GetFloat("intensity", 5f);
        float duration = data.GetFloat("duration", 0.3f);
        EventBus.Publish(new ScreenShakeEvent(intensity, duration));
        await UniTask.Delay(TimeSpan.FromSeconds(duration));
    }

    public void Rollback(CommandData data, ScenarioContext context) { }
}

// 注册（Bootstrap 中）
NatsumeRuntime.RegisterCommand(new ShakeCommandHandler());
```

YAML 中即可使用：
```yaml
- { type: shake, intensity: 10, duration: 0.5 }
```

### 添加自定义选择风格

```csharp
// 例：地图选点
public class MapChoicePresenter : IChoicePresenter
{
    public string Style => "map";

    public async Task<string> ShowAndWaitAsync(ChoiceData data)
    {
        string mapBg = data.Extra["background"] as string;
        // 显示地图背景，在各选项坐标处放置可点击标记
        foreach (var opt in data.Options)
        {
            float x = Convert.ToSingle(opt.Extra["x"]);
            float y = Convert.ToSingle(opt.Extra["y"]);
            CreateClickableMarker(opt.Id, opt.Label, x, y);
        }
        // 等待玩家点击某个标记
        string selectedId = await WaitForMarkerClick();
        return selectedId;
    }
}

// 注册
NatsumeRuntime.RegisterChoicePresenter(new MapChoicePresenter());
```

### 自定义设置 UI

```csharp
// 框架提供 GameSettingsManager，游戏项目绑定自己的 UI
public class MySettingsPanel : MonoBehaviour
{
    [SerializeField] Slider textSpeedSlider;
    [SerializeField] Slider bgmVolumeSlider;

    void Start()
    {
        var settings = ServiceLocator.Get<GameSettingsManager>();

        // 读取当前值
        textSpeedSlider.value = settings.Current.CharacterInterval;
        bgmVolumeSlider.value = settings.Current.BgmVolume;

        // 绑定变更
        textSpeedSlider.onValueChanged.AddListener(v => settings.Set(s => s.CharacterInterval = (int)v));
        bgmVolumeSlider.onValueChanged.AddListener(v => settings.Set(s => s.BgmVolume = v));
    }
}
```

### 验收标准

- [ ] 自定义 Handler 注册后，YAML 中使用对应 type 可正常执行
- [ ] 自定义 ChoicePresenter 注册后，对应 style 的选项可正常展示和交互
- [ ] GameSettingsManager 修改设置后各子系统实时响应

## 6. 框架 API 总览

```csharp
// ═══ 初始化 ═══
NatsumeRuntime.Initialize(canvas);
NatsumeRuntime.RegisterCommand(handler);
NatsumeRuntime.RegisterChoicePresenter(presenter);

// ═══ 剧情控制 ═══
var engine = ServiceLocator.Get<ScenarioEngine>();
engine.LoadScenario("chapter01");
engine.Start();
engine.AdvanceClick();           // 模拟玩家点击
engine.SelectChoice("option_a"); // 模拟选择
engine.JumpToScene("scene_id");  // 跳转

// ═══ 变量 ═══
var vars = ServiceLocator.Get<VariableStore>();
vars.Set("flag", true, VariableScope.Scenario);
int val = vars.GetInt("affection");

// ═══ 存档 ═══
var save = ServiceLocator.Get<SaveManager>();
save.Save(slotId: 1);
save.Load(slotId: 1);
SaveData[] list = save.GetSaveList();

// ═══ 设置 ═══
var settings = ServiceLocator.Get<GameSettingsManager>();
settings.Set(s => s.BgmVolume = 0.5f);
float vol = settings.Current.BgmVolume;
settings.ResetToDefault();

// ═══ 语音播放状态 ═══
var voice = ServiceLocator.Get<VoiceController>();
VoicePlaybackInfo info = voice.GetPlaybackInfo();
// info.IsPlaying, info.Progress, info.CurrentTime, info.TotalDuration

// ═══ 事件监听 ═══
EventBus.Subscribe<ShowDialogueEvent>(evt => { /* 自定义处理 */ });
EventBus.Subscribe<SceneChangedEvent>(evt => { /* 场景切换时做点什么 */ });
EventBus.Subscribe<VoiceProgressEvent>(evt => { /* 语音进度更新 */ });
```

### 验收标准

- [ ] 以上所有 API 调用均可正常工作
- [ ] ServiceLocator 在未 Initialize 时调用给出明确错误提示
- [ ] 事件订阅/取消订阅无内存泄漏
