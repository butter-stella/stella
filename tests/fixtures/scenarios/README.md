# 剧情端到端测试场景

本目录保存供集成测试使用的 synthetic、可再分发 `.stla` 场景。每个 fixture 都通过游戏实际
使用的同一 parser、CommandHandler、SignalBus 和 Presenter 链路验证一项公开 DSL 能力。

fixture 可以使用 `@wait click` 作为确定性检查点。这也便于在 debug build 中人工运行：推进
一次进入 cleanup 命令，再推进一次结束场景。

每个 fixture 应聚焦单项能力，严禁包含私有游戏内容、资产或机器专属路径。
