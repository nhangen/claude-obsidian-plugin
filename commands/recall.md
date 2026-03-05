---
name: obsidian:recall
description: Recall context about past work. Searches vault, git history, GitHub PRs, and claude-mem. Usage: /obsidian:recall <query>
---

Recall and synthesize context about past work from multiple data sources.

Pass the full user query to the obsidian-recall skill at `${CLAUDE_PLUGIN_ROOT}/skills/obsidian/recall/SKILL.md` to execute.

Examples:
- `/obsidian:recall what did I do on ticket #188 last week`
- `/obsidian:recall stripe webhook changes this month`
- `/obsidian:recall recent commits`
