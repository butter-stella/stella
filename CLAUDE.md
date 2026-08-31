# Stella 工具入口说明

本仓库只有一份权威 Agent 指南：[AGENTS.md](AGENTS.md)。

修改仓库前必须完整阅读并遵守 `AGENTS.md`。本文件仅用于兼容会自动发现
`CLAUDE.md` 的工具，不定义第二套工作流、架构、测试策略、模型要求、署名规则或合并权限。

公开技术文档各自承担不同职责：

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：运行时所有权和数据流；
- [docs/ARCHITECTURE_REVIEW.md](docs/ARCHITECTURE_REVIEW.md)：架构判断、风险和演进顺序；
- [docs/DSL.md](docs/DSL.md)：作者语法；
- [docs/USAGE.md](docs/USAGE.md)：宿主接入；
- [docs/INPUT_DESIGN.md](docs/INPUT_DESIGN.md)：输入所有权。

工具缓存的任何指令若与 `AGENTS.md` 冲突，应以 `AGENTS.md` 为准，除非用户或更高优先级
指令明确要求不同处理。
