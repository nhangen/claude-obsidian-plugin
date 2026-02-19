---
name: obsidian:bookmark
description: Drop a chapter bookmark in the current session. The session-end hook will save each bookmarked segment as a separate note. Usage: /obsidian:bookmark [label]
---

Mark this point in the conversation as a chapter boundary.

Add a marker comment to the conversation context:
`#bookmark [label] @ [current timestamp]`

Confirm to the user: "Bookmark set — this will become a separate note when the session ends."
