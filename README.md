# nxnative Converter

A Mac app for [nxnative](https://github.com/seedds/nxnative): drop a folder of a Switch game's files on its window, and it converts the game into a Mac app of
its own with nxnative's NSP script, installs it in Applications and keeps a record of which nxnative commit built it. It also checks and installs the tools
the conversion needs, keeps your nxnative checkout up to date, and can hand a game nxnative cannot convert yet to Claude Code or Codex, which attempt the port
in a worktree of nxnative.

The app is separate from nxnative: it runs the NSP script of whichever nxnative checkout you point it at, and nxnative knows nothing about it.

## Requirements

- A Mac with Apple silicon and macOS 27 or later
- Xcode 27 (or a Swift 6.4 toolchain with the macOS 27 SDK) to build the app
- An nxnative checkout new enough to have the script's `--platform mac-app` and `--progress json`. The app's Setup page checks this, and the nxnative page can
  download a checkout.
- The game files (NSP, XCI, NSZ or XCZ) and the `prod.keys` of a Switch you own

## Build and install

```bash
git clone https://github.com/jthrilly/nxnative-mac.git
```

```bash
python3 nxnative-mac/scripts/build_app.py
```

That builds the app and puts it at `/Applications/nxnative Converter.app`. If you can't write to `/Applications`, add
`-o ~/Applications/nxnative\ Converter.app`. The other options:

- `--open` opens the app when it is built.
- `--sign <identity>` signs with your Developer ID; the default is ad-hoc.
- `--scratch-path <dir>` names another build folder.

The script stops before building if it can't write the destination folder. An existing app at that path is replaced only when it is nxnative Converter
(bundle ID `org.nxnative.converter`); anything else stops the script.

The build steps:

1. `swift build -c release`.
2. Render the icon with `Icon/make_icon.swift`, `sips` and `iconutil`. If that fails, the app has no icon and the script prints a warning.
3. Write the bundle beside its destination.
4. Sign it.
5. Swap it in for the old app in one step and move the old one to the Trash.

A failed build leaves the installed app as it was. To update the app, pull this repository and run the script again.

## Choosing the nxnative checkout

The app uses the first of these that holds an nxnative checkout: `~/Projects/nxnative`, `~/Developer/nxnative`, `~/nxnative`. If none does, the nxnative page
offers to download one to `~/nxnative` (`git clone https://github.com/seedds/nxnative.git`). To use another checkout, a fork or a worktree of a branch, choose
it in Settings › General › nxnative folder, or with Setup's "Choose the nxnative Folder…".

The **nxnative** page shows the checkout's git status:

- its branch and HEAD;
- local changes;
- commits that aren't on the upstream yet.

Its actions:

- **Check for Updates** runs `git fetch`. It also runs once at launch, in the background.
- **Update** runs `git pull --ff-only`.
- When local changes or local commits block the pull, it offers `git reset --hard @{u}`, after listing what the reset throws away.

A folder that is not the top of a git checkout counts as missing, so these never act on an enclosing repository.

What the app needs from the script:

- **Required:** `--platform mac-app` and `--progress json`. A checkout without them can't convert; Setup says so and offers another folder.
- **Optional:** `--ignore-settings`, which sets aside the Settings block at the top of the script, so values changed there for a Spyder run don't reach the
  app's builds. A checkout without it gets a Setup warning, and its Settings block applies to the app's builds too.

## What the app does

Each game runs the checkout's script, one game at a time:

```
<python> -u scripts/build_ipa_from_nsp.py <folder> -k <prod.keys> --platform mac-app --progress json [--ignore-settings] [-l <language>] [-p <version>] [--app-name …] [--bundle-id …] [--allow-damaged] [--env-file …] [--mac-sign …] [--survey-only]
```

How it runs:

- **Environment:** the login shell's environment plus the script's tool folders. An app opened from Finder gets no shell `PATH`.
- **Process group:** the script runs in one of its own. Cancel sends the group SIGINT, then SIGTERM and SIGKILL.
- **Progress:** the script's JSON events drive the stage list and the log.

The pages:

- **Convert**: the queue of game folders. A folder is scanned the way the script scans it (title ID, versions, DLC), then matched with nxnative's profiles: a
  tested version, an untested version, or no profile. Each game has its options (language, version, app name, bundle ID, damaged files, env file), its stages
  with counts and an estimate of the time left, and the log.
- **Library**: the nxnative game apps in the install folder, `/Applications` and `~/Applications`. Each shows the nxnative commit that built it and how far the
  checkout has moved since, and can be rebuilt with the current checkout. The Library also keeps the history of every conversion.
- **Ports**: the games handed to a coding agent (see [Ports](#ports)).
- **nxnative**: the checkout (see [Choosing the nxnative checkout](#choosing-the-nxnative-checkout)).
- **Setup**: what a conversion needs, each item with its fix. Install Missing runs the fixes that need neither a password nor administrator rights. The items:
  - Apple silicon, Xcode and its license, the Metal Toolchain;
  - Homebrew, git, zstd, spirv-cross, glslang;
  - the .NET 10 SDK, Python and its modules, nsz;
  - the nxnative checkout and `prod.keys`;
  - Claude Code and Codex, for ports.

When a conversion is done, the game's app goes to the install folder: `/Applications` by default, `~/Applications` or another, chosen in Settings, which also
chooses Move, Copy or Don't install.

- **Staging:** the new app is written beside its destination first. An app already there goes to the Trash only when it is an nxnative app of the same game;
  any other app of that name stops the install and is left alone.
- **Saves and logs:** they stay where nxnative's launcher keeps them, `~/Library/Application Support/nxnative/<title ID>/` and
  `~/Library/Logs/nxnative/<title ID>.log`.

### Ports

A game with no profile offers:

- **Survey Only**: runs the script with `--survey-only`, which writes `<folder>/<title ID>_survey/survey.md`;
- **Open Survey** and **Show Provisional Profile**;
- **Port with an Agent…**, which a failed conversion offers too.

A port hands the game to Claude Code or Codex. The agent works in a git worktree of the checkout of its own: branch `port/<title ID>`, in
`nxnative-ports/<title ID>` beside the nxnative folder unless Settings names another folder. Its prompt names:

- the game's files and the survey;
- the provisional profile and the last conversion's logs;
- the milestones: profile, frame loop, first frame, playable.

It also points the agent at nxnative's `AGENTS.md` and `docs/agents`. The agent doesn't commit, and closes with a JSON report that the Ports page shows: the
milestone it reached, what it changed, the next steps and anything blocking it. Build App on that page converts the game from the port's worktree.

Claude Code runs in its sandbox, which a run without it stops on:

- it can read everything except the key file;
- it can write only to the worktree, the game's folder, the game apps' log and save folders and the build tools' caches;
- it can reach only GitHub, PyPI, NuGet and the .NET downloads.

On top of the sandbox, a hook on every tool runs this app's own executable with `--keys-guard`. It blocks any file tool or command that would read the key
file, and fails closed when the app is missing. Codex runs sandboxed to the worktree and the game's folder, and is told not to read the key file.

What the agent reads (logs, disassembly, the survey, nxnative's code) is sent to Anthropic or OpenAI.

### Where the app keeps things

| What | Where |
|---|---|
| Settings | the user defaults of `org.nxnative.converter` |
| Conversion records | `~/Library/Application Support/nxnative Converter/library.json` |
| Ports | `ports.json`, and `ports/<title ID>/` beside it (transcripts, prompts, the agent's settings) |

The game's app carries its nxnative version in its Info.plist too, so the Library knows apps the script packed outside this app. A `library.json` or
`ports.json` that this version can't read is moved aside to `<name>.unreadable-<date>`, and a new one is started.

## Development

```
Package.swift               macOS 27, Swift 6
Sources/ConverterCore       the logic: scanning, profiles, the script's command and events, git, Setup's checks, ports, the keys guard
Sources/NXNativeConverter   the SwiftUI app
Tests/ConverterCoreTests    Swift Testing tests of ConverterCore
Icon/make_icon.swift        renders the app icon
scripts/build_app.py        builds and installs the app bundle; test_build_app.py tests it without a Swift build
```

```bash
swift build
```

```bash
swift test
```

Some tests check the app against an nxnative checkout's own files: its profiles, the script's options and tool folders, and the languages `dm/tools/nacp.py`
knows. They run when `NXNATIVE_REPO` names a checkout, and are skipped otherwise:

```bash
NXNATIVE_REPO=~/Projects/nxnative swift test
```

`CONVERTER_LIVE_AGENT_TESTS=1 swift test --filter LiveAgentTests` runs both agents once on a throwaway repository, which costs a few cents. Run `swift build`
first, for the guard. It checks:

- that the sandbox is on;
- that a script reading the key by a path the guard never sees is stopped;
- that the worktree is writable.

The build script's tests:

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'
```

CI (`.github/workflows/tests.yml`) runs all three on GitHub's `xcode-27` runner image, with `NXNATIVE_REPO` set to a checkout of nxnative's `main`. A weekly run
catches an nxnative change that the app needs to follow.
