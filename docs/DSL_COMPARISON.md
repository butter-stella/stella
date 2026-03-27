# Natsume DSL 与业界方案对比

## 同一场景的语法对比

**场景**：显示背景 → 角色登场 → 一句带语音的对话 → 切换表情 → 两个选项分支。

### Natsume (.ntm) — 6 行

```
@bg bg_school fade 0.8
@show sakura smile center
sakura「你好。」 #voice:sakura_001
@expr sakura surprised
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

### Naninovel (.nani) — 8 行

```nani
@back bg_school transition:CrossFade time:0.8
@char Sakura.Smile pos:0.5
Sakura: 你好。
@voice sakura_001
@char Sakura.Surprised
@choice "你好" goto:#scene_a set:affection+=5
@choice "……" goto:#scene_b
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

### NScripter — 10 行

```
bg "bg_school.bmp",1
ld c,"sakura_smile.bmp",1
wave "sakura_001.wav"
Sakura：你好。@
cl c,1
ld c,"sakura_surprised.bmp",1
select "你好",*scene_a,"……",*scene_b
```

---

## 功能矩阵

| 功能 | Natsume | Ren'Py | KAG | Naninovel | NScripter | Ink |
|------|---------|--------|-----|-----------|-----------|-----|
| 智能默认值 | **核心设计** | 部分 | 无 | 部分 | 无 | N/A |
| 日式括号 `「」` | **原生** | 无 | 无 | 无 | 无 | 无 |
| 句内表情切换 `[expr]` | 有 | 无 | 无 | 有 | 无 | 无 |
| 句内效果 `{wait}` | 有 | 无 | 无 | 有 | 有限 | 无 |
| 语音绑定在对话行 | `#voice:id` | 单独语句 | 单独标签 | `\|#id\|` | 单独 | 无 |
| 并行执行 | `@parallel` | `with`（有限）| 手动 | `@async` | 无 | 线程（叙事） |
| ADV/NVL 切换 | `@nvl` 开关 | 角色类型 | 层配置 | Printer 配置 | 模式命令 | N/A |
| 条件选项 | `?if expr` | `if` 守卫 | TJS | `if:expr` | `if`+`goto` | `{condition}` |
| 选项+副作用 | `{var += 5}` 内联 | `$` Python | TJS | `@set` 嵌套 | 分开写 | `~ var += 5` |
| CG 系统 | `@cg`（全屏/SD/动态/差分）| 自定义 | 自定义 | 自定义 | 无 | N/A |
| 角色动画 | `@anim` | ATL | TJS | `@animate` | 无 | N/A |
| 运行时 | Unity | 独立（Python）| Windows | Unity | Windows | 任意 |
| 面向人群 | 编剧优先 | 编剧→程序员 | 程序员 | 编剧+C# | 程序员 | 纯写作 |
| 授权 | 开源（规划中）| MIT | 开源 | 商业 ($150+) | 免费 | MIT |

---

## 各引擎定位

| 引擎 | 设计哲学 | 适合场景 |
|------|---------|---------|
| **Natsume** | 脚本即演出：编剧用最短语法完成 90% 演出 | 日系 Galgame / AVG，Unity 项目 |
| **Ren'Py** | 低门槛 VN 创作，Python 托底 | 独立 / 同人 VN，跨平台 |
| **KAG** | 最大化渲染控制，标签+层精确操控 | 日本商业 VN（有专职程序员） |
| **Naninovel** | Unity 原生 VN 创作，C# 可扩展 | Unity 商业项目 |
| **NScripter** | 极简直接命令 | 历史遗产（月姬、寒蝉） |
| **Ink** | 纯叙事流，视觉由宿主引擎处理 | 叙事型游戏（非传统 VN） |

---

## Natsume 的优势

### 1. 日式对话原生语法

`角色「台词」` 是日本视觉小说文本的标准书写习惯。没有任何其他引擎原生支持这个格式——它们都使用西式的 `Character "text"` 或 `Character: text`。对于日/中文 VN，这是最直观的书写体验。

### 2. 省略即合理（Smart Defaults）

这是 Natsume 最大的设计差异点。`@show sakura` 一行 = 居中、默认表情、fade 0.3s。`@bg bg_school` = fade 0.5s。编剧只需要写出与默认值不同的部分。

KAG 没有默认值（每个参数必须写）。Ren'Py 有一些但不系统。Naninovel 有部分。只有 Natsume 将此作为核心设计原则，并提供了完整的默认值表。

### 3. 语音与对话耦合

`sakura「你好。」 #voice:sakura_001` 将语音绑定在对话行上——这是 Galgame 工作流的自然形式（配音文件和台词是一一对应的）。Ren'Py 需要单独的 `voice` 语句，KAG 需要单独的 `[playse]` 标签。

### 4. 句内表情变化

`sakura「开心...[surprised]但是...[cry]呜呜」` 在一句对话中标注表情切换点，不需要打断台词。这对情感丰富的场景非常重要。只有 Naninovel 有类似能力（内联 `[char]` 命令），但语法更冗长。

### 5. Unity 原生 + 开源

和 Naninovel 同为 Unity 原生，但 Naninovel 是商业授权（$150+）。Natsume 规划开源，对独立开发者更友好。Ren'Py 虽然免费但不是 Unity 引擎，无法集成到现有 Unity 项目。

### 6. 独有功能

- `@cg` 统一 CG 系统——全屏 CG / SD CG / 动态 CG / 差分 CG 统一管理，其他引擎无内建支持
- `@overlay` 无框叠字模式——区别于 ADV/NVL 的第三种文本模式
- 语音驱动表情时间轴——对话中角色表情随语音进度自动切换

---

## Natsume 的弱项 & 可借鉴

### 1. 缺少变量文本语法（借鉴 Ink）

Ink 的序列/循环/随机文本非常强大：
```ink
{I bought a coffee.|I bought a second.|I ran out of money.}  // 序列
{&Monday|Tuesday|Wednesday}                                    // 循环
{~Heads|Tails}                                                 // 随机
```

对于有重复场景的 VN（日常循环、随机对话），这可以大幅减少重复脚本。Natsume 目前没有类似语法。

**建议**：考虑在 P2 或之后支持类似的内联序列语法。

### 2. 缺少访问计数（借鉴 Ink）

Ink 自动追踪每个段落的访问次数：`{knot_name > 2}` 无需手动 `@set`。VN 中常见的「已读判定」「重复访问时不同对话」目前需要手写变量。

**建议**：考虑为 `@scene` 自动生成 `__visited_{sceneId}` 计数器。

### 3. 缺少脚本级路径导航（借鉴 Naninovel）

Naninovel 支持 `@goto ./Scene2`、`@goto ../Day2/Scene1` 的相对路径跳转。大型项目（数十个剧本文件）需要这种组织能力。Natsume 目前一个文件一个剧本，跨文件跳转机制未定义。

**建议**：定义跨文件引用语法，如 `@jump chapter2:scene_start`。

### 4. 缺少回滚/存档点标注（借鉴 Ren'Py）

Ren'Py 的回滚是语言级特性（引擎自动追踪可回滚的状态变更）。Natsume 的存档是引擎级（ISnapshotProvider），但 DSL 中没有标注存档点或不可回滚操作的语法。

**建议**：后续可考虑 `@checkpoint` 或 `@norollback` 指令。

### 5. 社区和生态

Ren'Py 有 110,000+ 论坛帖子，KAG 有几十年的日本社区积累，Naninovel 有完善的官方文档。Natsume 作为新项目，社区和文档需要从零建设。

**这不是技术问题，而是时间问题**——先做好框架质量和文档，社区会跟随好的项目生长。
