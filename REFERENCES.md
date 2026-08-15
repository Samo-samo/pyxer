# pyxer — Reference

Everything a builder needs beyond the README: every argument, the config
profile semantics, the produced layout, the onefile footer format, the build
log format, and the dependency scanner.

## 1. Command-line interface

`pyxer.ps1` is a thin frontend for `build.ps1`. Any action/switch below can
be mixed freely.

### pyxer.ps1 actions

| Command | Meaning |
|---|---|
| `.\pyxer.ps1 --help` (or `-h`) | show actions, options, profiles |
| `.\pyxer.ps1 apps` | list apps (name, source dir, default profile) |
| `.\pyxer.ps1 profiles` | list profiles and the switches they set |
| `.\pyxer.ps1 build <app>` | package one app using its default profile |
| `.\pyxer.ps1 build a,b,c` | package several apps in one run (shared runtime) |
| `.\pyxer.ps1 build all` | package every app declared in `apps` |
| `.\pyxer.ps1 build <app> -p gui` | use profile `gui` instead of the default |
| `.\pyxer.ps1 build <app> -SkipRuntime` | add the app to an existing `dist\` |

Notes:

- `build all` packages apps with their **first listed** profile unless you
  pass `-p`/`-Profile`, which is then used for all of them.
- When multiple apps are built, the first app builds the shared runtime and
  each following app is added with implied `-SkipRuntime`.
- Raw `build.ps1` switches passed on the command line **win over** profile
  values. A profile value of `false` is dropped, so the raw switch applies.
- Values that are not switches are passed through positionally; the rest of
  the command line is forwarded verbatim to `build.ps1`.

### build.ps1 switches

| Switch | Type | Default | Meaning |
|---|---|---|---|
| `-AppName` | string (csv) | `hello` | name(s) of the app to build; the exe is named after the first |
| `-Version` | string | `0.1` | version stamp for `runtime\app_version.txt` and the log |
| `-BuildNo` | int | `0` | force a specific build number (`0` = auto-increment) |
| `-SourceDir` | string (csv) | `src` | app source folder(s); must contain `main.py` |
| `-Upx` | switch | off | compress DLLs/EXEs/pyds with UPX (auto-downloaded) |
| `-NoSSL` | switch | off | drop `libssl`/`libcrypto`/`_ssl` (apps without TLS) |
| `-TrimPython` | switch | off | rewrite `python312.zip` without dev/std-lib extras |
| `-SkipRuntime` | switch | off | do not rebuild the runtime; just add the app to `dist\` |
| `-Onefile` | switch | off | also build `<App>_onefile.exe` (self-extracting, standalone, §5) |
| `-Windowed` | switch | off | compile the launcher with `subsystem:WINDOWS` (no console window) |
| `-NoConsole` | switch | off | GUI apps only: use `pythonw.exe` + `CREATE_NO_WINDOW` (no black console **at all**) |
| `-Manifest` | switch | off | embed `asInvoker` + `dpiAware(PerMonitorV2)` manifest (no UAC prompt) |
| `-Icon` | path | empty | embed an `.ico` resource into the launcher exe(s) |
| `-Checksum` | switch | off | write `checksums.md5` + `checksums.sha256` for the dist |
| `-Archive` | switch | off | zip the finished `dist\` as `releases\v<Version>\dist.zip` |
| `-VerboseUpx` | switch | off | print the full UPX log (default: only a summary) |

GUI tip: combine `-NoConsole` with `-Manifest`. `-NoConsole` implies
`subsystem:WINDOWS` (like `-Windowed`) but additionally uses `pythonw.exe`, so
no black terminal window ever appears next to your app.

## 2. Dependency discovery & trimming (trim.json)

There is **no** `-PySide6` switch. PySide6/shiboken6 are found by the
dependency scanner like any other package, merged into `site-packages`, and
trimmed by a data-driven rule in `trim.json`:

```json
{
  "PySide6": {
    "keep": ["__init__.py", "_config.py", "pyside6.abi3.dll",
             "Qt6Core.dll", "Qt6Gui.dll", "Qt6Widgets.dll",
             "QtCore.pyd", "QtGui.pyd", "QtWidgets.pyd", "..."],
    "dirs": {
      "plugins/platforms":    ["qwindows.dll"],
      "plugins/styles":       ["qmodernwindowsstyle.dll"],
      "plugins/imageformats": "*",
      "plugins/iconengines":  "*"
    }
  }
}
```

`keep` copies only those top-level files; each `dirs` relative path keeps a
whole sub-tree (`"*"`) or an explicit file list. Any package **without** a
rule is copied in full.

The shipped PySide6 rule keeps ~37 MB (Core/Gui/Widgets + the VC runtime
DLLs) instead of the full ~634 MB tree. The MSVC runtime DLLs
(`msvcp140*.dll`, `vcruntime140*.dll`, `concrt140.dll`) are also copied next
to `python.exe` by `Add-VcRuntime`, which is what C-extension packages
(numpy, ...) resolve at run time; wheels that ship their own DLLs in a
sibling `<pkg>.libs` folder (numpy, scipy, matplotlib) get that copy too.

## 3. Profiles (pyxer.config.json)

A profile is an object of build.ps1 switch names:

```json
"gui": {
  "Upx": true, "NoSSL": true,
  "TrimPython": true, "NoConsole": true,
  "Manifest": true, "Checksum": true
}
```

Semantics when merged with the command line:

1. Start with the profile's switches.
2. Overlay the raw command-line switches (raw wins).
3. Switch values set to `true` are passed as flags; `false` and `null` are
   dropped (so a raw `-Upx` can still turn it on); string/int values are
   passed as `-Name value`.

`apps` entries set the default profile per app:

```json
"apps": {
  "hello": { "source": "examples/hello", "profile": "minimal" }
}
```

`source` may be relative to the pyxer folder. It must contain `main.py`.

## 4. Output layout (onedir, shared runtime)

```
dist\
  app1.exe                       launcher (own name = app name)
  app2.exe                       another launcher, same runtime
  checksums.md5                  (with -Checksum)
  checksums.sha256
  runtime\
    python.exe  pythonw.exe  python312.dll  python312.zip  python312._pth
    app_version.txt              ("<Version>"; auto-generated)
    apps\
      app1\main.py ...           each app's copied sources
      app2\main.py ...
    site-packages\               packages merged by scan_deps + trim.json
                         (e.g. PySide6, shiboken6, pygame, numpy, numpy.libs)
    msvcp140*.dll, concrt140.dll (VC runtime, copied next to python.exe)
    ...
```

The launcher:

- derives the app name from its **own file name**,
- sets `APP_DATA_DIR` to its own folder (so apps write their `.db` next to
  the exe, never into `runtime\`),
- forwards command-line arguments,
- starts `runtime\python.exe` (`pythonw.exe` with `-NoConsole`) running
  `runpy.run_path(apps\<app>\main.py)`.

During a build the payload is assembled under `work\payload_<app>\` and the
final layout is copied to `dist\`. `work\`, `dist\`, `releases\`, and the tool
caches are git-ignored.

## 5. Onefile variant (`-Onefile`)

In addition to the onedir build, `-Onefile` produces
`dist\<App>_onefile.exe`, a **self-extracting single exe**:

```
[ launcher_onefile.exe ] [ payload.zip ] [ 21-byte footer ]
```

| Field | Size | Content |
|---|---|---|
| exe | — | `launcher_onefile.c` compiled (self-extract logic) |
| payload.zip | — | the same shared `runtime\` as the onedir build, compressed |
| footer magic | 9 bytes | ASCII `MINI1FEXE` |
| reserved | 4 bytes | zeros |
| payload size | 8 bytes | little-endian `Int64` length of the zip part |

Footer total: 21 bytes. At run time the exe:

1. reads its own last 21 bytes to locate `payload.zip`,
2. extracts it to `%TEMP%\mini_<app>_<exeSize>\` using `tar.exe`,
3. places a `.done` marker so the next launch reuses the extracted folder,
4. sets `APP_DATA_DIR` to the exe's own folder (write area, not the temp
   folder), then launches the runtime.

Size: onedir 3 apps + shared runtime ~43 MB vs. PyInstaller's 131 MB.

## 6. Build log (releases\build_log.csv)

Semicolon-delimited, `#N` row numbers are auto-incremented from the last row
(+1). `-BuildNo N` can pin the number.

| Column | Example |
|---|---|
| datetime | `2026-08-15 00:35` |
| version | `v0.2` |
| apps | `hello, hello_gui` |
| size_mb | `42,99` (note comma decimal, Turkish locale) |
| duration_s | `21,46` |
| modes | `NoConsole Upx NoSSL TrimPython` |

## 7. Dependency scanning (scan_deps.py)

`build.ps1` runs `scan_deps.py <app_source_dir>` before each app is laid out.
It is an **AST-based static import scanner**:

- full parse of every `.py` file in the app folder (pure `ast`), collecting
  imported top-level names,
- stdlib names come from `sys.stdlib_module_names` (3.10+),
- anything inside the app folder is treated as local and skipped,
- transitive companions are added only when they appear in a package's own
  `__init__.py` (e.g. PySide6 pulls in shiboken6) — optional submodules
  (pygame.camera -> cv2, etc.) are deliberately ignored so installed-dev-only
  packages do not leak into the runtime,
- prints one third-party top-level package per line.

Why not `modulefinder`? It executes/descends bytecode and can mis-fire on
`try/except` optional imports, and is slow on large trees. The static pass is
fast, deterministic, and exactly matches the packages that must be shipped.

Each app's dependencies are merged into the shared runtime only if missing
(`Add-MissingDeps`): the package folder, its `<pkg>.libs` sibling (numpy's
OpenBLAS DLL), and — for packaged apps — the MSVC runtime DLLs. This is what
makes `-SkipRuntime` safe for apps with different dependency sets:

```powershell
.\pyxer.ps1 build hello_gui            # PySide6+shiboken6 merged (trimmed)
.\pyxer.ps1 build hello_pygame -SkipRuntime   # pygame+numpy merged on top
```

Use it standalone with:

```powershell
python scan_deps.py examples\hello_gui
# -> PySide6
python scan_deps.py examples\hello_pygame
# -> numpy
# -> pygame
```

## 8. Runtime cache & offline builds

- Embeddable CPython zip: cached in `work\_runtime_cache\`; re-downloaded
  only when missing. `-SkipRuntime` skips the download entirely.
- UPX 5.x: cached under `_upx_cache\`.
- The embeddable distribution already contains `_sqlite3.pyd`,
  `sqlite3.dll`, and the `sqlite3\` package, so SQLite apps need nothing extra.