# sessions/ 中的文件归属

本地 GUI 启动脚本的权威位置是：

```text
~/.agents/skills/launch-local-agent-session/
```

本目录只保留：

- **云端权威文件**：`spawn-cloud-agent-session.md`、`spawn_cloud_agent.sh`
- **本地后端回退副本**：与 `launch-local-agent-session/sessions/` 同名的 Cursor / Cursor2–5 / Codex / ZCode / Waku / Zed / Claude 文件

生成循环任务时：

1. 本地后端用 `launch-local-agent-session/scripts/ensure-into-repo.sh`
2. 仅当该 skill 不存在时，才从本目录复制本地后端
3. 不要改本目录里的本地副本来修复启动行为；改权威 skill，再按需同步副本
