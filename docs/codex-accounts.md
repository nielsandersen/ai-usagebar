# Codex account guide

ai-usagebar can report several Codex subscriptions alongside your Claude
accounts. Each named account has an independent `CODEX_HOME` and login.
The existing `[openai] codex_auth_path` remains the default account, falling
back to `~/.codex/auth.json` when omitted.

## Choose a setup

| Need | Setup |
|---|---|
| One Codex account | Keep the default Codex login. No extra config is needed. |
| A few named accounts | Run `ai-usagebar account add <label> --codex`. |
| Accounts already organized by `CODEX_HOME` | Set `[openai] accounts_dir`. |

## Add a named account

```bash
ai-usagebar account add work --codex
```

The command:

- creates `~/.config/ai-usagebar/accounts/codex/work/` with mode `0700` on Unix;
- adds a `[[openai.accounts]]` entry to the active config with `toml_edit`,
  preserving comments, formatting, and other settings;
- runs `codex login` with `CODEX_HOME` set to that directory, inheriting your
  terminal for sign-in.

Re-run the command to sign in again. Existing explicit or discovered accounts
keep their configured directory. Pass `--no-login` to register without opening
Codex. `--codex` and `--desktop` cannot be combined.

Named accounts appear in the menu bar, TUI, and usage report when `[openai]`
is enabled. The command does not switch the default Codex CLI login. To use a
named account in Codex itself, start it with the same `CODEX_HOME`.

### Configure accounts by hand

```toml
[openai]
# Optional override for the default account:
# codex_auth_path = "~/.codex/auth.json"

[[openai.accounts]]
label = "work"
codex_home = "~/.config/ai-usagebar/accounts/codex/work"

[[openai.accounts]]
label = "personal"
codex_home = "~/.config/ai-usagebar/accounts/codex/personal"
```

Each account reads only `<codex_home>/auth.json`. Paths expand a leading `~`.
Labels use the same rules as Claude and OpenRouter: non-empty, no path
separators, drive prefixes, control characters, or reserved cache filenames.
Duplicate explicit labels are rejected. `codex_home` must be non-empty.

## Select an account

```bash
ai-usagebar --vendor openai --account work
ai-usagebar --vendor openai --account work --pretty
ai-usagebar usage --json
ai-usagebar account status
ai-usagebar account status --json
```

An unknown label reports the valid labels. `--account` conflicts with
`--creds-path`, just as it does for Claude. The `usage` command lists all
configured accounts; the TUI has one tab per account after the default.
Status adds `codex.accounts` without changing the existing Claude fields.

To hide the unnamed account in aggregate views when every login is named:

```toml
[openai]
show_default_account = false
```

The default stays visible when no named accounts exist. Direct access to the
default account remains available without `--account`.

## Discover accounts from a directory

```toml
[openai]
accounts_dir = "~/.config/ai-usagebar/accounts/codex"
```

Each immediate subdirectory containing an `auth.json` file becomes an account
labelled by its directory name. Discovered labels are sorted; explicit entries
come first and win label clashes. Missing or unreadable directories are ignored.
An explicit entry remains visible even before its first login.

Keep Claude accounts explicit if `[anthropic] accounts_dir` points to the parent
`~/.config/ai-usagebar/accounts`: Claude treats every immediate subdirectory as
an account, including the `codex` container. Alternatively, put Codex homes in
a separate directory and configure them by hand.

## Caches and refreshes

Each named account uses `~/.cache/ai-usagebar/openai/<label>/` on Linux, or the
platform cache root on macOS (`~/Library/Caches/ai-usagebar/openai/<label>/`).
The default keeps its original `openai/` cache. A `--cache-dir <root>` override
uses `<root>/openai/<label>/` for named accounts and `<root>/openai/` for the
default, so labels remain isolated.

Named accounts follow the existing Codex token refresh flow. Refreshed tokens
are written atomically to that account's own `auth.json`, mode `0600` on Unix.
The default login and other account files are untouched. Use independent
sign-ins rather than copies of the same rotating refresh token.

A missing named auth file reports that the account is not signed in and points
to `ai-usagebar account add <label> --codex`.

### Use a named account in Waybar

```jsonc
"custom/codex-work": {
    "exec": "ai-usagebar --vendor openai --account work",
    "return-type": "json",
    "interval": 300,
    "tooltip": true
}
```
