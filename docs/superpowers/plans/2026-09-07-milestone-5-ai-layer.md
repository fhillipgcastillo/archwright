# Milestone 5 — AI Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans.

**Goal:** Ship the AI layer from spec §9 — lazy agent stubs, a default agent with
a keybind and an inline shortcut, a shared agent skill directory, and a
time-boxed passwordless sudo window — plus the `archwright` CLI that hosts them.

**Architecture:** Agent identities are data (`manifest/agents.tsv`), never code.
The installer generates stub scripts into `/usr/share/archwright/agent-stubs/`
(ours, refreshed every run) and seeds them into `~/.local/bin/` with the existing
never-overwrite semantics. Runtime behaviour lives in one dispatcher,
`/usr/bin/archwright`, which milestone 6 extends rather than replaces.

**Tech Stack:** bash, mise (`npm:` backend), systemd transient timers, visudo.

## Global Constraints

- Installer code NEVER runs on the development host. QEMU only.
- Never hardcode a package or agent name in `lib/` — it belongs in `manifest/`.
- Never overwrite anything under the user's `~/.config`, `~/.local/bin` or
  `~/.local/share`. Seed only.
- Every value interpolated into `aw_run_in_chroot` must be validated first.
- ASCII only in shipped config files.

---

## Verified facts (checked against live registries 2026-09-07, do not re-guess)

| Thing | Status |
|---|---|
| `mise` | Arch `extra`, 2026.9.1 |
| `github-cli` | Arch `extra`, 2.100.0 — the package is NOT called `gh` |
| `ollama` | Arch `extra`, 0.33.3 — stays in extras, unchanged |
| `npm:@anthropic-ai/claude-code` | 2.1.263, bin `claude` |
| `npm:@openai/codex` | 0.153.4, bin `codex` |
| `npm:opencode-ai` | 1.18.29, bin `opencode` |
| `npm:@charmland/crush` | 0.92.0, bin `crush` |
| `pi` | **NO installable CLI.** `@mariozechner/pi-agent` declares no `bin`; `@mariozechner/pi` is `pi-pods`, a different tool. |

### Decisions this plan locks in

- **D17 — `pi` is not shipped.** A stub whose first invocation fails is worse
  than an absent stub. Revisit if a `pi` CLI is published with a `bin`.
- **D18 — `gh` ships as the `github-cli` package, not a mise stub.** Arch
  packages it; a stub would bypass pacman's updates and signature checks. Stubs
  exist for things Arch does NOT package.
- **D19 — the `archwright` CLI lands in milestone 5, not 6.** Spec §9.2 and §9.4
  are defined as `archwright` subcommands, so the dispatcher is a milestone 5
  dependency. Milestone 6 adds `hardware` and `theme` to the same file.

---

## Task 1: The agent manifest and its reader

**Files:**
- Create: `manifest/agents.tsv`
- Modify: `lib/manifest.sh`
- Test: `test/unit/test_manifest.sh`

**Interfaces:**
- Produces: `aw_manifest_agents <file>` emitting `name<TAB>spec<TAB>bin` rows.

- [ ] **Step 1: Write the failing test**

Assert structurally, never on row counts of the shipped file — a corrupted
manifest must not pass by having the right number of lines.

- [ ] **Step 2: Run it and watch it fail** — `bash test/run-unit.sh`, expect
      "command not found: aw_manifest_agents".

- [ ] **Step 3: Implement** — same shape as `aw_manifest_subvolumes`: strip
      comment lines and blanks, emit the rest verbatim so tabs survive.

- [ ] **Step 4: Write `manifest/agents.tsv`** with the four verified rows only.

- [ ] **Step 5: Run the suite green. Commit.**

---

## Task 2: The stub generator

**Files:**
- Create: `lib/agents.sh`
- Test: `test/unit/test_agents.sh`

**Interfaces:**
- Produces: `aw_agent_stub_text <name> <spec> <bin>` — pure text, no I/O, so it
  is unit-testable without mise present.

- [ ] **Step 1: Failing test** — assert the output starts with a shebang, names
      the spec exactly once, `exec`s mise, and forwards the argument list.
- [ ] **Step 2: Run, watch it fail.**
- [ ] **Step 3: Implement.** The generated stub is three meaningful lines: a
      shebang, a comment explaining that nothing downloads until first run and
      that the file belongs to the user, and an `exec mise exec <spec> -- <bin>`
      forwarding all arguments.
- [ ] **Step 4: Green. Commit.**

---

## Task 3: The `archwright` dispatcher

**Files:**
- Create: `bin/archwright`
- Test: `test/unit/test_cli.sh`

Subcommands: `help`, `version`, `agent`, `default`, `mise-install`,
`sudo-window`. Unknown subcommand exits 2 with usage on stderr.

- [ ] **Step 1: Failing tests** — `help` exits 0 and lists every subcommand;
      an unknown subcommand exits 2; `default agent <bad name>` is rejected by
      the same charset rule the answer file uses; `sudo-window abc` and
      `sudo-window 0` are rejected before anything touches `/etc`.
- [ ] **Step 2: Run, watch them fail.**
- [ ] **Step 3: Implement.** `default agent <name>` writes
      `~/.local/state/archwright/default-agent`. `agent` reads it (default
      `claude`), refuses to launch from `$HOME` by redirecting to `~/Work`, and
      execs it. `mise-install <spec> [bin]` writes a new stub using Task 2's
      generator.
- [ ] **Step 4: Green, shellcheck clean. Commit.**

---

## Task 4: The sudo window

**Files:**
- Modify: `bin/archwright`
- Test: `test/unit/test_cli.sh`

- [ ] **Step 1: Failing test** for the validator: minutes must be an integer
      1..240; anything else exits 2 having written nothing.
- [ ] **Step 2: Run, watch it fail.**
- [ ] **Step 3: Implement.** Order matters and is the whole point of the
      feature:

  1. Re-exec under sudo if not root, so the drop-in is written by root only.
  2. Write the rule to a temp file with mode 0440.
  3. `visudo -cf` the temp file — **a malformed sudoers file locks you out of
     the machine permanently.** Validate before it is anywhere near
     `/etc/sudoers.d`.
  4. `install -m 0440` it into place.
  5. Schedule the revert with a transient systemd timer, so an abandoned or
     crashed session cannot leave the window open.

- [ ] **Step 4: Green. Commit.**

---

## Task 5: The AI phase

**Files:**
- Create: `lib/70-ai.sh`, `config/agent-skills/archwright/SKILL.md`,
  `config/profile.d/archwright-agents.sh`, `config/archwright/agents.sh`
- Modify: `install.sh` (add `ai` to the phase list), `manifest/core.packages`
  (new `## Group: ai` with `mise` and `github-cli`), `config/hypr/shell.conf`

What the phase does, in order:

1. Generate every stub from the manifest into
   `/usr/share/archwright/agent-stubs/`, mode 0755.
2. Seed each into `~/.local/bin/` with `aw_seed_config` semantics — a user who
   already has a real `claude` there keeps it.
3. Install the shared skill to `~/.local/share/archwright/agent-skills/archwright/`
   and symlink it into `~/.claude/skills/`, `~/.codex/skills/` and
   `~/.agents/skills/`. Not `~/.pi/` — see D17.
4. Create `~/Work` and `~/.local/state/archwright/`, defaulting the agent to
   `claude`.
5. Install `bin/archwright` to `/usr/bin/archwright`.
6. Install `/etc/profile.d/archwright-agents.sh`, which puts `~/.local/bin` on
   PATH (Arch does not), defines the `a` function, and sources
   `~/.config/archwright/agents.sh` when present.
7. Seed `~/.config/archwright/agents.sh` — **auto-approve aliases present but
   commented, with the warning attached** (spec §9.2, the deliberate divergence).
8. `chown -R` everything seeded into the user's home.

A keybind for the default agent in a dedicated terminal goes in
`config/hypr/shell.conf`, launched through `uwsm app` like every other bind.

- [ ] **Step 1..N:** write each file, then run the full unit suite and
      `test/lint.sh`. Commit per file group.

---

## Task 6: The gate

**Files:**
- Modify: `test/vm/assertions.sh`, `test/vm/drive_vm.py` (add the `ai` phase)

Assertions (the spec's stated gate criteria in bold):

- `archwright help` exits 0; an unknown subcommand exits 2
- all four stubs exist in `~/.local/bin` and are executable
- `mise` and `gh` are on PATH
- the skill symlinks **resolve** — check the file through the symlink, not just
  that a symlink exists
- `~/.local/bin` is on the login PATH, and `a` is defined in a login shell
- `~/.config/archwright/agents.sh` contains no UNCOMMENTED auto-approve flag
- **a stub installs on first run** — run one stub and assert mise materialised
  it. This costs real download time in the gate; that is the price of testing
  the thing the feature claims to do.
- **the sudo window grants and auto-reverts** — grant for one minute, assert the
  drop-in exists and `visudo -c` still passes, wait past the deadline, assert it
  is gone.

- [ ] **Run the full gate. It must pass on a real boot, not on inspection.**

---

## Task 7: Record

- [ ] `docs/decisions.md`: D17, D18, D19 plus implementation log entries.
- [ ] `README.md`: the AI layer section, the `EXTRAS=ai-local` note, and the
      sudo-window warning.
- [ ] Update the known-gaps table: no `pi`; agent authentication is the user's
      problem; stubs need network on first run.
