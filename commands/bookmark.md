---
name: obsidian:bookmark
description: Drop a chapter bookmark in the current session. The session-end hook will save each bookmarked segment as a separate note. Usage: /obsidian:bookmark [label]
---

Mark this point in the conversation as a chapter boundary.

Check `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/capture-owner.py" status`.
For MCP ownership, this is an outline marker in the pending session capture,
not a promise of a separate automatically split note. Say "Bookmark noted in
the pending session outline" and stop. Disabled/draining ownership must not
promise a future save. The legacy chapter behavior below is legacy-only.

Add a marker comment to the conversation context:
`#bookmark [label] @ [current timestamp]`

Confirm to the user: "Bookmark set — this will become a separate note when the session ends."
