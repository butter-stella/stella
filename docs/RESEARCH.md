# 竞品调研与语法对比

> 调研现有视觉小说 / AVG 引擎，明确 Stella 的差异化定位。

**文档角色：** 本文件记录产品定位与历史设计假设，不是 Stella 当前实现、兼容性
或竞品现状的规范来源。Stella 能力以 [DSL.md](DSL.md) 和 [USAGE.md](USAGE.md)
为准，架构判断见 [ARCHITECTURE_REVIEW.md](ARCHITECTURE_REVIEW.md)。涉及外部项目
版本、平台和活跃度的结论在产品决策前必须按当时版本重新核验。

这里的功能矩阵表示方向性比较，不应被引用为测试通过、平台认证或性能结论。

## 1. 主流引擎概览

### Ren'Py

- **定位**：全球最流行的开源 VN 引擎
- **价格**：免费（MIT）
- **特点**：
  - Python 基础 + 自定义脚本语言
  - 跨平台（Windows/Mac/Linux/Android/iOS/Web）
  - 巨大的社区（Steam 上大量 Ren'Py 游戏）
  - 完善的存档、Backlog、设置系统
  - 丰富的转场效果和动画
- **不足**：
  - Python 性能限制，复杂演出效果受限
  - UI 定制需要较深的框架知识
  - 对差分立绘、语音驱动表情等日式 Galgame 高级功能缺乏原生支持

### KiriKiri / KAG（吉里吉里）

- **定位**：日本传统 Galgame 引擎
- **价格**：免费（开源）
- **特点**：
  - 日本商业 Galgame 的事实标准（大量商业作品使用）
  - 对日式 AVG 功能支持最完整
  - 脚本语法成熟（KAG 标签语法）
- **不足**：
  - 仅支持 Windows
  - 技术栈老旧（TJS 脚本语言）
  - 不再活跃开发
  - 无法利用现代引擎的 3D、粒子、Shader 能力

### Ink / Inkle

- **定位**：叙事脚本语言 + 运行时
- **价格**：免费（MIT）
- **特点**：
  - 专注叙事逻辑和分支结构
  - 强大的分支/条件/变量系统
  - 可嵌入各种引擎
  - Inky 编辑器
- **不足**：
  - 仅是叙事层，不包含表现层（对话框、立绘、音频等需要自己实现）
  - 不是完整的 VN 引擎
  - 对 AVG 演出指令没有原生概念

### Godot 生态现状

Godot 目前没有成熟的、功能完整的日式 AVG/Galgame 框架。现有方案：

- **Dialogic**：Godot 上最流行的对话插件，支持基本对话和分支，但定位偏通用 RPG 对话，不是 VN/AVG 专用框架。缺少差分立绘、语音系统、CG 管理等日式 Galgame 核心功能。
- **GDScript 社区方案**：零散的教程和模板，无体系化框架。

这是 Stella 在 Godot 生态中的机会。

## 2. 商业日式引擎 vs 开源方案的差距

| 功能 | 商业引擎 | 开源方案现状 |
|------|----------|-------------|
| 差分立绘合成（Body + Face） | 标配 | 大多不支持或需手动实现 |
| 角色独立语音音量控制 | 柚子社等标配 | 几乎没有 |
| 语音驱动表情切换 | 部分高端作品 | 无 |
| 语音收藏 & 场景跳转 | 部分作品 | 无 |
| 精细文字速度控制（逐字间隔、标点停顿） | 标配 | 粗粒度 |
| 快进仅已读 / 未读确认 | 标配 | 部分支持 |
| 多样化选项呈现（地图、角色选择等） | 常见 | 仅文字选项 |

## 3. 语法对比

**场景**：显示背景 → 角色登场 → 一句带语音的对话 → 切换表情 → 两个选项分支。

### Stella (.stla) — 6 行

```
@bg bg_school fade 0.8
@stage sakura show kind=character asset=character:sakura/smile position=960,80
sakura「你好。」 #voice:sakura_001
@stage sakura update asset=character:sakura/surprised
@choice
  - "你好" -> scene_a {affection += 5}
  - "……" -> scene_b
```

### Ren'Py (.rpy) — 10+ 行

```renpy
define s = Character('Sakura')  # 还需要单独的角色定义

label start:
    scene bg_school
    with fade
    show sakura smile at center
    with dissolve
    voice "sakura_001"
    s "你好。"
    show sakura surprised
    menu:
        "你好":
            $ affection += 5
            jump scene_a
        "……":
            jump scene_b
```

### KAG (.ks) — 15+ 行

```
[image storage="bg_school" page=fore layer=base]
[backlay][image storage="bg_school" layer=base page=back]
[trans method=crossfade time=800][wt]
[image layer=0 page=back storage="sakura_smile" visible=true left=320]
[trans method=crossfade time=300][wt]
[name]Sakura[/name]
[playse storage="sakura_001"]
你好。[l][r]
[backlay][image layer=0 page=back storage="sakura_surprised"]
[trans method=crossfade time=300][wt]
[link target=*scene_a]你好[endlink][r]
[link target=*scene_b]……[endlink][r]
[s]
```

## 4. 功能矩阵

| 功能 | Stella | Ren'Py | KAG | Ink |
|------|---------|--------|-----|-----|
| 智能默认值 | **核心设计** | 部分 | 无 | N/A |
| 日式括号 `「」` | **原生** | 无 | 无 | 无 |
| 句内表情切换 `[expr:name]` | 有 | 无 | 无 | 无 |
| 句内效果 `{wait}` | 有 | 无 | 无 | 无 |
| 语音绑定在对话行 | `#voice:id` | 单独语句 | 单独标签 | 无 |
| 并行执行 | `@parallel` | `with`（有限）| 手动 | 线程（叙事） |
| ADV/NVL 切换 | `@nvl` 开关 | 角色类型 | 层配置 | N/A |
| 条件选项 | `?if expr` | `if` 守卫 | TJS | `{condition}` |
| 选项+副作用 | `{var += 5}` 内联 | `$` Python | TJS | `~ var += 5` |
| 插画 / SD / 动态差分 | `@stage` 命名层与局部更新 | 自定义 | 自定义 | N/A |
| 运行时 | **Godot** | 独立（Python）| Windows | 任意 |
| 面向人群 | 编剧优先 | 编剧→程序员 | 程序员 | 纯写作 |
| 授权 | 开源 | MIT | 开源 | MIT |

## 5. Stella 的差异化定位

| 维度 | Stella 策略 |
|------|-------------|
| **引擎** | Godot 4（GDScript 为主；只有测得 Godot 公共 API 缺口时才评估受控 GDExtension） |
| **脚本** | 自定义 DSL（.stla），编剧零门槛 |
| **日式功能** | 差分合成、语音驱动表情、角色音量、语音收藏 — 填补开源空白 |
| **设置系统** | 精细粒度控制（逐字间隔、标点停顿） |
| **选项系统** | 抽象 Presenter，支持任意呈现方式 |
| **开源** | MIT，面向 Godot 生态 |

**定位**：Godot 生态中第一个具备**商业日式 Galgame 功能深度**的开源 AVG 框架。

## 6. 可借鉴的设计

### 变量文本语法（Ink）

```ink
{I bought a coffee.|I bought a second.|I ran out of money.}  // 序列
{&Monday|Tuesday|Wednesday}                                    // 循环
{~Heads|Tails}                                                 // 随机
```

对于有重复场景的 VN（日常循环、随机对话），可以大幅减少重复脚本。

### 访问计数（Ink）

自动追踪每个段落的访问次数，VN 中常见的「已读判定」「重复访问时不同对话」目前需要手写变量。可考虑为 `@scene` 自动生成访问计数器。

### 跨文件引用

大型项目需要跨文件组织能力，如 `@jump chapter2:scene_start`。

### 存档点标注

可考虑 `@checkpoint` 或 `@norollback` 指令，显式标记存档点或不可回滚操作。
