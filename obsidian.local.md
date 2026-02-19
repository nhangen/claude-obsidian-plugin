---
vault_path: /mnt/z/Users/nhang/Documents/Obsidian
vault_name: Obsidian
vault_windows_path: Z:\Users\nhang\Documents\Obsidian
wsl_symlink: ~/obsidian
auto_save: true
auto_open: true
time_gap_minutes: 30
smart_detect: true
domains:
  - Development
  - Physics-AI-ML
  - NRX-Research
  - Personal
  - VR-and-E
  - TARS
---

# Obsidian Plugin Config

Vault is at `/mnt/z/Users/nhang/Documents/Obsidian` on the WSL side.
Symlinked at `~/obsidian` for convenience.

## Project Taxonomy

| Domain | Vault path | Notes |
|--------|-----------|-------|
| Development | Projects/Development/ | Claude sessions, tooling, WSL, Obsidian plugin |
| Physics/AI/ML | Projects/Physics-AI-ML/ | DeCoN, Memory-Dynamics, Psychohistory-ECI |
| NRX Research | Projects/NRX-Research/ | Operations, Hiring, Meetings |
| Personal | Projects/Personal/ | Personal notes |
| VR&E | Projects/VR-and-E/ | |
| TARS | TARS/ | AI agent configs and patches |

## Routing Rules

- Keywords "claude", "wsl", "obsidian", "plugin", "terminal" → Projects/Development/
- Keywords "physics", "pinn", "gauge", "decon", "psychohistory", "memory dynamics" → Projects/Physics-AI-ML/
- Keywords "nrx", "norx", "peptides", "hiring", "operations", "business" → Projects/NRX-Research/
- Keywords "daily", "journal", "today" → Daily/
- Ambiguous → Inbox/ (with #needs-filing tag)
