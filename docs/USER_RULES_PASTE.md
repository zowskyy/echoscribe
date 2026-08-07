# Global User Rules (optional — for ALL projects)

**AUTO-ENABLED in the Schema repo** — agents follow gate and delegation policy automatically; no user command or reminder is required.

**You may not need this file** if you only work in the Schema repo — the policy is already enforced via `.cursor/rules/ship-finished-work.mdc`, `.cursor/rules/quarterback-worker.mdc`, and `AGENTS.md`.

Use User Rules only when you want the same policy in **every** project on your machine.

---

## How to find User Rules in Cursor

Try these paths (UI varies by version):

### Path A — Customize sidebar (most common)
1. Look at the **left sidebar** in Cursor (same area as Chat, Composer, etc.)
2. Click **Customize** (sliders/wand icon)
3. Click **Rules**
4. At the **top** of the page, look for **User Rules** (separate from Project Rules below)
5. Click **Add rule** or edit the text box
6. Paste the block below → save

### Path B — Settings gear
1. Click the **gear icon** (top-right)
2. Open **Cursor Settings** (not VS Code Settings)
3. Go to the **Rules** tab
4. Find **User Rules** at the top

### Path C — Command palette
1. `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
2. Type **Rules** or **Cursor Settings**
3. Open Rules / Customize → Rules
4. User Rules is the **global** section at the top

### Still can't find it?
- User Rules may be labeled **"Global rules"** or just a text area above Project Rules
- On some versions, **Add Rule** under Customize only creates *project* rules — scroll up for the User Rules text field
- **Cloud Agents** use repo rules (`AGENTS.md`, `.cursor/rules/`) — User Rules apply to local Agent chat, not always to cloud runs

---

## Text to paste (User Rules)

```
Ship finished work only. Never deliver partial code or stop at iteration limits.

AUTO-ENABLED — apply this policy every session without waiting for a user command or reminder.

When writing or changing code, run both gate reviewers and fix until PASS:
  python3 ~/.cursor/cursor_gate_fastest.py --file <path> --region us-west-2
  python3 ~/.cursor/cursor_gate.py --file <path> --iterations 3

Loop write → gate → fix until both return "status": "PASS". Only stop if BLOCKED with a specific ask. Never hand me unfixed gate failures when I can still fix them.
```
