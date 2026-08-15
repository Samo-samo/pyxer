# pyxer

Package small/medium Python apps into Windows executables — **Windows only**.

pyxer bundles your app with an embedded CPython runtime and produces an `.exe`
per app. The launchers are compiled from a tiny C file; there is no temporary
extract folder, no `sys._MEIPASS`, and **no setup dependency on PyInstaller**.

> pyxer targets small/medium internal and hobby projects. It is **not**
> a PyInstaller replacement — for complex dependency graphs, hidden imports,
> or full cross-platform support, stick with PyInstaller. pyxer is a simpler,
> lighter tool for the common case.

## Design overview

Instead of shipping one self-contained exe, pyxer ships:

- one or more small `.exe` launchers, and
- a shared `runtime\` folder with the Python runtime and your third-party
  packages.

Every exe in the same folder uses the same runtime, so three apps built by
pyxer total roughly the size of **one** PyInstaller `--onefile` build.

|                           | pyxer (3 apps) | PyInstaller --onefile (3 apps) |
|---------------------------|---------------|-------------------------------|
| Approximate total size    | ~43 MB        | ~131 MB                       |
| Per app                  | small launcher (~few hundred KB) + shared runtime | full exe each (44 MB) |
| Startup                  | launcher spawns `runtime\python.exe` | single exe unpacked to temp |

## Requirements

- Windows 10/11
- PowerShell 7+ (pwsh)
- The [MSVC](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
  C++ Build Tools standalone component (for `cl`, used to compile the launcher)
- Python 3.12+ for source-mode development (only needed locally when you
  `python` the app directly)

The embeddable Python is downloaded automatically at build time and cached
under `work\_runtime_cache\` (no admin rights needed).

## Quick start

```powershell
# list the apps and profiles defined in pyxer.config.json
.\pyxer.ps1 apps
.\pyxer.ps1 profiles

# package one app (uses its default profile)
.\pyxer.ps1 build hello

# package several apps in one run (shared runtime)
.\pyxer.ps1 build hello,hello_gui,hello_pygame

# build every app declared in the config
.\pyxer.ps1 build all

# use a named profile
.\pyxer.ps1 build hello_gui -p gui

# mix in raw build.ps1 switches (a raw switch wins over the profile)
.\pyxer.ps1 build hello_gui -SkipRuntime -Upx -Icon myicon.ico
```

The result lands in `dist\`:

```
dist\
  app1.exe
  app2.exe
  runtime\            (shared by every exe in dist, Python + deps)
```

`\pyxer.ps1 --help` always lists the current actions, profiles, and examples.

## Configure

`pyxer.config.json` has two sections.

### Apps

`apps` maps a short name to a source folder and a default profile:

```json
"apps": {
  "hello":      { "source": "examples/hello",      "profile": "minimal" },
  "hello_gui":  { "source": "examples/hello_gui",  "profile": "gui" },
  "hello_pygame": { "source": "examples/hello_pygame", "profile": "minimal" }
}
```

`source` must contain `main.py`. The folder is copied into the payload
(`__pycache__` and `*.db` excluded automatically).

### Profiles

`profiles` groups build.ps1 switches. Include a switch set to `true` to turn
it on; set it to `false` to force it off (a `false` is dropped, letting a raw
command-line switch win):

```json
"profiles": {
  "gui": {
    "Upx": true, "NoSSL": true,
    "TrimPython": true, "NoConsole": true,
    "Manifest": true, "Checksum": true
  },
  "minimal": { "NoConsole": true },
  "onefile":  { "Onefile": true }
}
```

No `-PySide6` switch exists: dependencies are found automatically. A `gui`
profile is just a preset of the common optimization switches.

## Examples

The `examples\` folder ships three tiny apps used by the smoke tests:

| App            | Kind    | What it checks                            |
|----------------|---------|-------------------------------------------|
| `examples/hello`        | console | packaged env: prints `sys.executable`, `APP_DATA_DIR`, argv |
| `examples/hello_gui`    | PySide6 | opens a QWidgets window; verifies dependency scanning + the PySide6 trim rule |
| `examples/hello_pygame` | pygame  | initialises pygame; verifies dependency scanning/merging |

Build all three with one command to see the shared-runtime and dependency-merge
behaviour:

```powershell
.\pyxer.ps1 build all
```

## How it works (short version)

1. `build.ps1` downloads (or reuses from cache) an embeddable CPython zip and
   lays it out under `runtime\`.
2. Third-party imports are discovered per app with `scan_deps.py` (see
   `REFERENCES.md`): each import plus its `__init__`-companions (e.g.
   shiboken6 for PySide6) is merged into the shared runtime site-packages.
   C-extension DLLs shipped in a sibling `<pkg>.libs` folder (numpy, ...) are
   copied with it, and the MSVC runtime DLLs are put next to `python.exe`.
3. Fat packages can be trimmed with data-driven rules from `trim.json` (the
   shipped PySide6 rule keeps ~37 MB of Core/Gui/Widgets instead of ~634 MB).
   Optional processing then runs in order: `-NoSSL`, `-TrimPython` std-lib
   trim, UPX compression, checksums.
4. The launcher C source is compiled with `cl` and placed next to the payload.
   At run time the launcher sets `APP_DATA_DIR` to its own folder (so your
   apps write `.db`/data next to the exe, never into the runtime) and starts
   `runtime\python.exe` with your `main.py`.

## Other commands

```powershell
# single-file self-extracting exe as well (apart from the onedir build)
.\pyxer.ps1 build hello -p onefile

# zip the finished dist\ and write checksums
.\pyxer.ps1 build hello -Archive -Checksum
```

For the full switch reference, the onefile footer layout, the build_log.csv
schema, and the dependency scanner details, see [REFERENCES.md](REFERENCES.md).

## License

MIT