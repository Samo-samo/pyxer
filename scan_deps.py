# scan_deps.py - Static import scanner for pyxer.
#
# Given an app source directory it lists every top-level third-party import
# the app needs, including *implicit* dependencies. pyxer uses that list to
# copy the required packages into the shared runtime's site-packages area.
#
# The scan is transitive: after collecting the app's own top-level imports we
# also parse the .py files of every imported third-party package and add any
# package *it* imports. That catches companions that the app never names
# directly - e.g. PySide6 imports shiboken6, pygame may pull numpy, and so on.
#
# Why AST instead of modulefinder:
#   * modulefinder executes/descends bytecode and can be slow or mis-fire on
#     optional imports guarded by try/except (they are real for us).
#     A static AST pass is fast, deterministic and exactly matches the
#     top-level packages we need to ship.
#
# Usage:
#   python scan_deps.py <app_source_dir>
#
# It prints one top-level third-party package name per line.
# Stdlib names come from sys.stdlib_module_names (3.10+); anything in the app
# folder itself (or inside a third-party package that is being expanded) is
# treated as local and skipped. Names that do not resolve to a real package
# under site-packages are skipped too, so optional imports that are not
# installed never reach the runtime.

import ast
import os
import sys
import sysconfig


SKIP_DIRS = ("__pycache__", ".git", "build", "dist", "test", "tests",
             "testing", "doc", "docs", "examples")


def iter_py_files(src_dir):
    for root, dirs, files in os.walk(src_dir):
        for skip in SKIP_DIRS:
            if skip in dirs:
                dirs.remove(skip)
        for f in files:
            if f.endswith(".py"):
                yield os.path.join(root, f)


def top_level_imports(src_dir):
    tops = set()
    for path in iter_py_files(src_dir):
        for top in top_level_imports_file(path):
            tops.add(top)
    return tops


def root_imports(pkg_dir):
    """Imports pulled in when *importing the package itself*.

    Transitive expansion reads only the package's __init__.py - the module
    Python actually loads for `import <pkg>`. That is exactly what catches
    companions like shiboken6 (imported from PySide6/__init__.py) while
    staying quiet about optional submodules (pygame.camera -> cv2, numpy,
    pytest, ...) that the app never imports.
    """
    init = os.path.join(pkg_dir, "__init__.py")
    if not os.path.isfile(init):
        return set()
    return top_level_imports_file(init)


def top_level_imports_file(path):
    tops = set()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            tree = ast.parse(fh.read(), filename=path)
    except (SyntaxError, OSError):
        return tops
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for n in node.names:
                tops.add(n.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.level:          # relative import -> local, skip
                continue
            if node.module:
                tops.add(node.module.split(".")[0])
    return tops


def package_dirs(purelib):
    """site-packages top-level names (packages and single-file modules)."""
    dirs = set()
    try:
        for name in os.listdir(purelib):
            path = os.path.join(purelib, name)
            if os.path.isdir(path):
                dirs.add(name)
            elif name.endswith(".py"):
                dirs.add(name[:-3])
    except OSError:
        pass
    return dirs


def resolve_to(dir_, top):
    """Does `top` resolve to a real package/module under site-packages?"""
    if os.path.isdir(os.path.join(dir_, top)):
        return True
    return os.path.isfile(os.path.join(dir_, top + ".py"))


def main():
    if len(sys.argv) < 2:
        print("usage: python scan_deps.py <app_source_dir>", file=sys.stderr)
        return 1
    src = sys.argv[1]
    if not os.path.isdir(src):
        print(f"scan_deps: not a directory: {src}", file=sys.stderr)
        return 2

    local = {os.path.splitext(os.path.basename(p))[0]
             for p in iter_py_files(src)}

    stdlib = set(sys.stdlib_module_names)
    purelib = sysconfig.get_paths()["purelib"]

    # App's own imports.
    needed = set()
    queue = []
    for top in top_level_imports(src):
        if top in local or top in stdlib:
            continue
        if not resolve_to(purelib, top):
            continue
        needed.add(top)
        queue.append(top)

    # Transitive expansion: root-module imports of the packages we already
    # need. Only the immediate companions are added; deep recursive descent
    # into installed web-of-dependencies is intentionally avoided (a static
    # scan of the whole forest would be slow and over-inclusive). The runtime
    # copy step afterwards merges every *top-level* package needed, so a few
    # extra names here just mean a couple of extra folders copied.
    visited = set()
    while queue:
        top = queue.pop()
        pkg_dir = os.path.join(purelib, top)
        if not os.path.isdir(pkg_dir) or pkg_dir in visited:
            continue
        visited.add(pkg_dir)
        for sub in root_imports(pkg_dir):
            if sub in local or sub in stdlib:
                continue
            if not resolve_to(purelib, sub):
                continue
            if sub not in needed:
                needed.add(sub)
                queue.append(sub)

    for name in sorted(needed):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())