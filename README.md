# dsa: disk space auditor

`dsa` shows what is filling your Mac, why each item can go, and how to get the space back. Nothing is ever deleted outright. Space is reclaimed in one of two ways: the item moves to the Trash, or the owning tool runs its own cleaner (`docker`, `brew`, `uv`, `npm`, `bun`, `pnpm`, `xcrun simctl`).

It comes as a command-line tool (`dsa`) and a native SwiftUI app (**Disk Auditor**) that share one core. It is a first-principles take on [tobi/disktree](https://github.com/tobi/disktree), tuned for a Mac used heavily by coding agents (Codex, Claude Code and similar tools leave a lot of state behind). About 4,000 lines of Swift, with no dependencies.

Example output (illustrative; paths and sizes will differ on your Mac):

```
$ dsa
41.0G free of 494G (44.5G counting what macOS can purge)  ·  ~ holds 210G in 1904388 files, read in 11.8s

  1    12.3G     0d  ~/.codex/sessions
                    agent: Codex transcripts: only for resuming or searching old sessions · dsa trash
  2 ✓   9.8G     0d  ~/Library/Containers/com.docker.docker
                    container: Docker's VM disk: … · dsa clean → docker system prune -a -f
  3     6.1G    40d  ~/code/old-archive
                    archive: you named it stale/archived · git: 2 dirty, 1 unpushed · dsa trash
  4 ✓   4.2G    12d  ~/code/some-rust-app/target
                    build: Rust build output · dsa trash
  …
✓ 28.7G regenerable with nothing of yours lost · 61.4G listed in all · the rest is your call
```

`✓` means the item is regenerable **and** git reports no work that exists only here.

## Install

You need macOS 14 or newer and Apple's Command Line Tools (`xcode-select --install`). Xcode is not required. There are no other dependencies.

```sh
git clone https://github.com/ShiftedReality12/disk-auditor
cd disk-auditor
make install     # ~/Applications/Disk Auditor.app  +  ~/.local/bin/dsa
make test        # 28 tests on real files, real git repos and a real mounted disk image
```

`make install` builds in release mode and installs the CLI to `~/.local/bin/dsa` (set `PREFIX=...` to change that) and the app to `~/Applications`. Make sure `~/.local/bin` is on your `PATH`. `make build` only compiles; `make app` builds the app bundle in `.build/` without installing. `make uninstall` moves both to the Trash with the `trash` command (built into macOS 15 and later; on macOS 14, `brew install trash` or drag them to the Trash yourself).

Then open **Disk Auditor** from Spotlight. The first launch asks once for Full Disk Access (System Settings › Privacy & Security › Full Disk Access). After that, macOS stops asking about each folder, and everything is counted.

- **Signing.** `make` signs the app with the first code-signing certificate in your keychain, so macOS keeps its permissions across rebuilds. Without one, it signs ad hoc, and macOS asks for Full Disk Access again after each rebuild.
- **AI (optional).** "Explain with AI" and "Ask AI" use [Claude Code](https://claude.com/claude-code) if it is installed, through your own login. Nothing else in the app needs it.
- **Nothing personal is built in.** The rules match common tool folders by name (`node_modules` beside `package.json`, `~/.cache/uv`, Docker's container, …). Your scan results, AI answers and marks stay in `~/.local/state/dsa/` on your Mac.

## The app

- **Treemap.** It shows the folder you are in, three levels deep by default (the Depth menu, or `[` and `]`). Colour says what a folder *is*: code, agent state, toolchains, cache, Git, media, documents, synced, or app data. Hatching says it can go. Click to select, double-click to open, `⌘[` / `⌘]` to go back and forward, `↑` for the enclosing folder, space to mark.
- **Filter** (`⌘F`). Type a name, such as `node_modules`. Every match anywhere in the scan, and the path down to it, keeps its colour, and everything else dims. The line above the map counts the matches and their size.
- **Inspector.**
  - *Selection* shows size, share of the scan, files, last write and kind, plus what the rules or AI say about the folder.
  - *Worth a look* lists the findings, largest first.
  - *Disk* shows free and used space, broken down by kind.
- **Look Inside** (`⌘I`). It runs locally in a second or two, and nothing leaves the Mac. It shows:
  - what the folder is made of (file types by size);
  - its largest files;
  - a peek at readable files: READMEs, manifests, logs. Files named like credentials (`.env`, `*.pem`, `*.key`, `id_*`, `*credentials*`, `*token*`) are never read, and key-shaped strings are redacted.
  - **what relies on it**: a running app with files open inside it, a launch job or shell or git config that names it, a link pointing into it, and, for `~/Library` folders, whether the app that owns it is still installed. An app's data with no app is leftover bloat.
- **Review.** Each marked item appears with its guard verdict. Refused items show why and cannot be ticked. Folders go to the Trash, and **Undo** puts them back. A tool-owned folder is reclaimed by its own cleaner. That cannot be undone, so the app asks first in an alert whose default button is Cancel.
- **Copy Agent Prompt** hands the list to Claude or Codex instead.

## AI: explain the rest

The rules explain the known patterns. For the large folders they do not explain, **Explain with AI** (app) or `dsa explain` (CLI) asks Claude what each one is and whether it is bloat, stale, regenerable, active or your own data.

- It sends folder **names, sizes and ages** only, never file contents. A dated run or numbered copy is judged as one unit.
- It runs through your Claude Code login (the `claude` binary in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` or `~/.claude/local`) with **no tools**, so it cannot read files or run anything. It uses no settings, hooks, MCP servers or saved session; that costs about 60× less and changes nothing in your own Claude Code setup. The default model is Sonnet; `--model haiku` is cheaper but weaker at identifying apps.
- Answers are **advice**. They appear with an *AI %* badge, never with ✓. Nothing is marked or run automatically, and a suggested command is shown, never executed. Trashing an AI suggestion still goes through every guard.
- **Ask AI** on a folder you are looking inside sends that folder's evidence: its file types, largest file names, the redacted excerpts, and what relies on it. Use it when a folder's name says nothing. The measured dependencies outweigh anything the model infers.
- Answers are cached for two weeks (`~/.local/state/dsa/advice.json`) while a folder stays about the same size, so each folder is paid for once. A pass over a large home folder took about 2 minutes and cost a few cents.

`open -a "Disk Auditor" --args -scan ~/some/folder` scans a folder directly.

## Use

| command | does |
|---|---|
| `dsa` / `dsa worth [PATH]` | the largest items that could go, numbered, with reasons, age and git state |
| `dsa top [PATH] -d 3` | the biggest folders, as a tree |
| `dsa trash 3 6 ~/some/path` | moves items to the Trash (by `#` from the last listing, or by path), after asking |
| `dsa clean 2` | runs the owning tool's cleaner and reports the free space it **measured** |
| `dsa prompt 1 4` | a checked hand-off prompt for Claude or Codex |
| `dsa inspect PATH [--ai]` | what is inside a folder and what relies on it; `--ai` also asks Claude |
| `dsa explain` | ask Claude about the large folders no rule explains (advice only) |
| `--json` | machine-readable `worth` / `top`; every key is always present |
| `--disk` | the whole Data volume instead of `~` |

From an agent: `dsa worth --json` returns `findings[]` with `path`, `bytes`, `age_days`, `kind`, `why`, `clean` (argv or null), `git`, `trashable`, and `safe`. `dsa trash` and `dsa clean` refuse to act without a terminal unless you pass `--yes`.

Each run saves its listing to `~/.local/state/dsa/last.json`. That file is what the `#` numbers refer to, and the next run uses it to show **what grew**.

## What it measures

- **Allocated blocks** (`st_blocks × 512`): what deleting a file actually gives back, the same figure `du` reports. A sparse file counts at its allocated size.
- Hardlinks are counted once. Symlinks are not followed. The scan stays on one volume.
- iCloud items evicted to the server are never opened, so a scan never downloads them.
- The scan runs in parallel. On an Apple-silicon Mac it read about 2.7 M files in roughly 15 s, where `du` took 52 s on the same tree.

## What it refuses to do

Each rule is tested, and each test was checked by deleting the guard and watching the test fail:

- remove anything outside your home folder, the home folder itself, or anything that holds it;
- remove folders that must exist (`~/Library`, `~/Library/Caches`, `~/Desktop`, …). It removes what is inside them instead;
- touch iCloud Drive, `CloudStorage` or `Keychains`: removing those deletes them on every device;
- trash Docker's disk by hand: its owner's cleaner is used instead;
- remove a mount point, or a folder with a volume mounted inside it;
- remove a checkout with uncommitted, unpushed or stashed work, or an orphaned worktree, unless you pass `--allow-git`;
- run a program a checkout names: git is called with hooks, fsmonitor and optional locks off, and a checkout with its own filter drivers is not asked at all;
- pass a path through a shell.

## Where things live

| file | holds |
|---|---|
| `Sources/AuditorCore/Scan.swift` | the parallel scanner and the tree |
| `Sources/AuditorCore/Rules.swift` | **the rules table**: every known place, what it is and how to reclaim it |
| `Sources/AuditorCore/Findings.swift` | "worth a look" (rules, worktrees, stale checkouts, stale archives, big old files) |
| `Sources/AuditorCore/Git.swift` | read-only git state |
| `Sources/AuditorCore/Remove.swift` | the guards, free space, and the Trash |
| `Sources/AuditorCore/Snapshot.swift` | the last listing and the growth since it |
| `Sources/AuditorCore/Classify.swift` | the category of every folder, for colour |
| `Sources/AuditorCore/Inspect.swift` | Look Inside: types, largest files, redacted excerpts, what relies on a folder |
| `Sources/AuditorCore/Advisor.swift` | what is left unexplained, the tool-less Claude call, its cache |
| `Sources/AuditorCore/Treemap.swift`, `Marks.swift` | squarified layout; marks that never nest; shared formatting and agent prompt |
| `Sources/dsa/main.swift` | the CLI |
| `Sources/DiskAuditor/` | the SwiftUI app: `Model.swift` (state and actions), `Treemap.swift` (layout and painting), `Inspector.swift`, `Views.swift` (window, toolbar, review) |

To teach it a new place, add one row to `Rules.table`.

## License

MIT, see [LICENSE](LICENSE).
