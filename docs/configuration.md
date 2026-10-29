# Configuration

Everything the app persists lives in `~/Library/Application Support/com.ycchung.mirageplay/`

| Path | What it is |
|---|---|
| `settings.json` | the active settings group, written back on every change |
| `snapshot.rc` | the effective settings as an rc-style snapshot |
| `launch.log` | stdout/stderr of the receiver core |

`com.ycchung.mirageplay` is the app's bundle identifier — a fixed value in `app/Resources/Info.plist` that the build does not override, so a fork that changes it there gets its own directory.

The PIN and the trusted-devices list are managed from the panel and Preferences.
Identity material (the receiver keypair) stays in that directory with mode `600`
and never enters the repository.
