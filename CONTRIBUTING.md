# Contributing to MiragePlay

Thanks for your interest in MiragePlay. Bug reports, feature proposals and pull
requests are all welcome — for anything beyond a small fix, open an issue first
so the approach can be agreed before code is written. There is no CI yet.

## Reporting a bug

Open the report with the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml)
(`New issue → Bug report`). It asks for the same fields as the list below, and
every one of them is required:

- **MiragePlay version.** Copy it out of the bundle:
  `defaults read /Applications/MiragePlay.app/Contents/Info.plist CFBundleShortVersionString`
- **macOS version.** Apple menu → About This Mac.
- **CPU.** Apple menu → About This Mac. MiragePlay runs on Apple silicon only.
- **Device.** The iPhone or iPad model and the iOS version it runs.
- **Steps to reproduce.** Numbered 1-2-3, starting from a clean launch of the app.
- **Expected behaviour vs actual behaviour.** What you expected, then what happened.
- **PIN Protection.** Whether it is on (menu bar icon → Preferences).
- **The relevant lines of `~/Library/Application Support/com.ycchung.mirageplay/launch.log`.**
  That file is the receiver core's own output; the location is documented in
  [docs/configuration.md](docs/configuration.md).
- **A crash report** if the app crashed: Console → Crash Reports → the
  `MiragePlay-*.ips` file timestamped at the crash.

Paste the relevant excerpt of the log, never the whole file: the failing lines
plus the handful before them are enough, and a full dump buries the one line that
identifies the bug.

## Requesting a feature

The problem comes first, the solution second. Describe the situation you are in
and what makes it awkward today — which device, which window, what you had to do
instead — and only then what you want MiragePlay to do about it. Do not post the
conclusion on its own ("add a hotkey"): the problem is what gets discussed, and a
proposal that skips it is usually sent back to be restated.

Open it with the [feature request template](.github/ISSUE_TEMPLATE/feature_request.yml).
It asks for the problem, the proposed solution and the alternatives you
considered; the third field is not filler — it is how a proposal that looks
obvious gets weighed against the workarounds you already tried.

## Pull requests

A pull request is reviewed against this list. Each item is a gate, not a
suggestion: a missing item gets the PR sent back before the code is read.

- [ ] **An issue it closes.** Link the issue (`Closes #12`), or state in one line
      why a trivial fix has no issue behind it.
- [ ] **One subject.** The PR does one thing — no unrelated reformat, rename or
      dependency bump riding along. Code follows the single responsibility rule:
      one type or function does one thing, and a PR that mixes unrelated concerns
      will be asked to split.
- [ ] **What this changes.** The description lists the behaviour added or
      changed, item by item, each naming the file or the user-visible effect.
      A pasted diff, `fix bug` or `refactor` on its own is not a description.
- [ ] **Tests, run serially.** Every new or changed behaviour has a
      corresponding test in `scripts/tests/`; a behaviour change without one is
      not accepted. Run the suites one at a time — never in parallel — and paste
      each suite's exit status (`test-pin-chain.sh exit 0`, …).
- [ ] **Docs updated.** A behaviour change updates `README.md` or the matching
      page under `docs/`; name the file you touched.
- [ ] **Screenshots for UI changes.** Before and after, of the window or panel
      you changed.
- [ ] **Where you tested it.** Mac model and macOS version, plus the iPhone or
      iPad model and its iOS version.
- [ ] **Commit format.** `type(scope): summary`, with `type` one of `feat`,
      `fix`, `docs`, `chore`, `test`; one commit per subject.

## Build

Run everything from the repository root. The build has three stages and they
must run in this order:

```bash
# 1. Homebrew dependencies (cmake, openssl@3, libplist, gstreamer, librsvg)
./scripts/setup/deps.sh

# 2. Build the UxPlay core in embedded mode (first run fetches the pinned tree)
./scripts/build/build-core.sh --embedded

# 3. Assemble MiragePlay.app
./scripts/build/build-app.sh
```

The bundle lands in `_build/`. Requirements — macOS 15.0 or later,
Apple silicon, Xcode Command Line Tools, `git` and Homebrew — are listed in
[README.md](README.md#requirements).

## Test

The tests live in `scripts/tests/`. There are nine suites and one smoke script:

```bash
./scripts/tests/test-config-engine.sh
./scripts/tests/test-language.sh
./scripts/tests/test-pin-chain.sh
./scripts/tests/test-profile-ui.sh
./scripts/tests/test-sleep-notify.sh
./scripts/tests/test-trust.sh
./scripts/tests/test-ui-cp2.sh
./scripts/tests/test-ui-prefs.sh
./scripts/tests/test-wiring-e1.sh

./scripts/tests/smoke.sh   # semi-automated, asks you to mirror a device
```

`./scripts/tests/test-config-engine.sh` runs the `ConfigEngineSelfTest` suite — 743 checks.

**Run the suites one at a time — never in parallel.** They share the real
application state directory `~/Library/Application Support/com.ycchung.mirageplay`
(`settings.json`, `snapshot.rc`, `launch.log` and the identity material), so two
suites running at once overwrite each other's fixtures and produce false results.

The UI suites (`test-ui-cp2.sh`, `test-ui-prefs.sh`) drive the app with
synthetic events, so **do not touch the mouse or keyboard while they run** — a
stray click or keystroke lands in the app under test and fails the run.

## Licence of contributions

Contributions without an explicit license grant are not accepted. By opening a
pull request you confirm that you wrote the change (or have the right to submit
it) and that you agree to license it under **GPL-3.0-only**, the same license as
this project. If you cannot agree to those terms, please open an issue instead
of a pull request.

## Corresponding source

The corresponding source for the bundled UxPlay core is stated in [README.md](README.md#license).
