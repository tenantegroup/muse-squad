---
name: squad-team
description: Manage the single muse-squad.toml config, its role-derived members, and the regenerated roster and wrappers.
---
You are in SQUAD-TEAM mode. Change the squad configuration and its generated outputs only.

## Read first

1. Resolve the Muse config directory: use `MUSE_CONFIG_DIR` when set, otherwise `~/.config/muse` (`%USERPROFILE%\.config\muse` on Windows).
2. Read `muse-squad.toml` from that directory and the generated `squad/team.md`.
3. Show the current roster briefly as `@<name> | primary | fallback chain` before asking what to change.
4. Treat `mcp/roles.js` as a read-only catalog. Do not edit it or any other file under `mcp/`.

## What you may edit

Edit only `muse-squad.toml`. Do not hand-edit `squad/team.md`, `agents/<name>.md`, `AGENTS.md` / `MUSE.md`, anything under `mcp/`, or the installer-managed `.muse-squad-state.json` beside the TOML. This is the only squad config file; there are no per-repo settings and no helper agents to edit.

The file uses `schema = 1` and these tables:

- `[providers.<Name>]` — a provider name may contain letters, numbers, `.`, `_`, and `-`. `enabled` defaults to `true`; set `false` to disable the provider without removing it from member chains. `type = "native"` requires `model` and `max_concurrency`. `type = "http"` requires `base_url`, `api_key`, and `model`, and accepts `temperature`, `top_p`, `max_tokens`, `max_input_chars`, `on_context_exceeded`, `max_concurrency`, `timeout_ms`, `queue_timeout_ms`, and `max_retries`. `api_key` may be plaintext or `${ENV_VAR}`.
- `[squad.<name>]` — one per member, with only `primary`, an ordered `fallback` array, and `charter`.

Every member needs at least one provider in its chain: `primary` and every `fallback` entry must match a provider table name exactly. Validate all cross-references before writing. Never invent a provider name. Member names are lowercase slugs (`a-z0-9-`); retired helper names are reserved. Keep `schema = 1`. Do not add display names, responsibilities, labels, role IDs, or any new member keys. Use `#` for TOML comments, not `;`.

## Built-in role catalog

`mcp/roles.js` carries 20 pinned roles adapted from GitHub Squad and agency-agents (MIT). Use it to generate names, charters, and templates; the TOML remains the source of truth after generation.

```bash
ROLES="$MUSE_CONFIG_DIR/mcp/roles.js"
node "$ROLES" --list
node "$ROLES" --list --category engineering
node "$ROLES" --search review
node "$ROLES" --show reviewer
node "$ROLES" --charter reviewer reviewer
node "$ROLES" --template software --json
```

On Windows without `MUSE_CONFIG_DIR`, use `node "$HOME\.config\muse\mcp\roles.js" ...`.

Templates:

- `software` — default; `lead`, `frontend`, `backend`, `reviewer`, `tester`, `devops`, `docs`.
- `engineering` — all 13 engineering, quality, operations, product, and design roles.
- `full` — all 20 roles.
- `custom` — no preselected roles; add roles one at a time.

Every role ID is a valid member slug. Use the role ID as the default member name (`@lead`, `@backend`, `@reviewer`) unless the user asks for a rename. `--template ... --json` also includes role-aware `primary`/`fallback` suggestions; treat them as defaults and apply the user's provider choices when overriding. Generated charters include an MIT attribution comment and the sections Identity, Ownership, How I Work, Boundaries, Routing Cues, Voice, and Delegation. Preserve them unless the user explicitly asks for a different charter.

## Apply the change

Ask which change to make unless the user already stated it clearly:

- add, rename, or remove a provider (check every member chain before removing);
- apply a template, or add a single role by ID, number from `--list`, or category;
- rename or remove a member (at least one member must remain);
- change a member's `primary`, reorder or replace its `fallback` array, or rewrite its `charter`;
- reapply a role's charter after a rename or custom edit;
- change any provider setting, including moving a secret into `${ENV_VAR}` or setting `enabled = false` to disable a provider without removing it from member chains.

### Add from the catalog

Resolve the role with `--list`, `--show`, or `--search`, then use its ID as the member name unless another name is requested. Generate the charter with `node "$ROLES" --charter <role-id> <member-name>` and place that full text in `charter = """..."""`. Choose the provider chain from the role-aware template JSON or from the user's explicit choice. Validate every provider name before writing.

### Rename a member

Rename the `[squad.<old>]` table to `[squad.<new>]` and rewrite explicit charter tokens with a word-boundary-safe replacement: replace `@<old>` only when the next character is not `a-z0-9-`. This updates headings and delegation lines such as `# @old — ...` and `Invoke me as @old.` without changing longer names like `@old-2`. Do not attempt semantic rewriting of prose. The generated wrapper follows the TOML name; stale marked wrappers are removed by the materializer.

### Apply or reapply a template

Use `node "$ROLES" --template <template-id> --json` for the roster, provider suggestions, and full charters. If any existing member charter or custom name would be replaced, state exactly what will be overwritten and get explicit confirmation before writing. Without that confirmation, keep the current roster and charters. Applying a template is the only catalog action that may overwrite charter text.

### Manual charter edits

A user may replace a charter with their own text. Do not inject role metadata or extra TOML keys. If the user wants the catalog version back, regenerate it from the role and obtain confirmation if it will replace custom text.

Before writing, copy `muse-squad.toml` to a timestamped sibling backup such as `muse-squad.toml.bak.20261121-143022`. Apply the smallest valid TOML edit, then parse the result and re-check every provider reference. If parsing or validation fails, restore the backup and stop.

## Regenerate

Run the materializer with the same config directory:

```bash
node "$MUSE_CONFIG_DIR/mcp/sync-team.js" --config-dir "$MUSE_CONFIG_DIR"
```

On Windows without `MUSE_CONFIG_DIR`, use `node "$HOME\.config\muse\mcp\sync-team.js" --config-dir "$HOME\.config\muse"`.

If the command fails, restore the config backup, report the exact error, and do not claim success.

Stale `agents/<name>.md` wrappers that carry the generated marker are removed automatically. Leave any unmarked agent file untouched.

## Finish

Re-read `squad/team.md`. Report the final `@<name> | primary | fallback` table, the regenerated file paths, and for each catalog change the role ID, final member name, and whether the charter was newly generated, rewritten by rename, or preserved. Never report the change as done until the materializer exited successfully.
