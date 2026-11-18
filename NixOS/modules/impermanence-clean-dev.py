#!/usr/bin/env python3
"""Remove regenerable build, environment, and cache artifacts safely.

Runs on boot (before user login) or manually via `clean-dev-cache [--dry-run]`.
Never follows symlinks, never enters `.git`, and guards ambiguous directory
names (`target`, `.venv`, `venv`, `node_modules`, `build*`, `result*`) with
tool-specific markers so actual source and data files stay untouched.

With --keep-environments, dependency environments (`.devenv`, `.direnv`,
`.venv`/`venv`, `node_modules`) are kept and not entered; only the stale
`.devenv/shell-*.sh` scripts devenv leaves behind on every evaluation are
pruned (the newest one is kept).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import stat
import sys

CACHEDIR_TAG_PREFIX = b"Signature: 8a477f597d28d172789f06886806bc55"

# Dependency environments: costly to rebuild, so hosts can keep them
# (--keep-environments).  .venv/venv/node_modules additionally need a marker,
# see is_environment_dir().
ENVIRONMENT_DIRS = frozenset({".devenv", ".direnv"})
ENVIRONMENT_FILES = frozenset({".devenv.flake.nix"})

UNCONDITIONAL_PROJECT_DIRS = frozenset({
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".hypothesis",
    ".tox",
    ".nox",
    ".svelte-kit",
    ".next",
    ".nuxt",
    ".turbo",
    ".parcel-cache",
    ".vite",
    ".cache",
})

PROJECT_GENERATED_SUFFIXES = (".elc",)
DEVENV_SHELL_PREFIX = "shell-"
DEVENV_SHELL_SUFFIX = ".sh"

NODE_MODULES_MARKERS = (".package-lock.json", ".yarn-integrity", ".modules.yaml", ".pnpm")

HOME_CACHE_DIRS = (
    ".cargo/registry",
    ".cargo/git",
    ".npm/_cacache",
    ".bun/install/cache",
    ".cache/nix",
    ".cache/pip",
    ".cache/uv",
    ".cache/pre-commit",
    ".cache/yarn",
    ".cache/npm",
    ".cache/pnpm",
    ".cache/go-build",
    ".cache/ccache",
    ".cache/sccache",
    ".cache/ruff",
    ".cache/mypy",
    ".cache/pytest_cache",
    ".cache/mozilla",
    ".cache/thumbnails",
    ".cache/mesa_shader_cache",
)

HOME_CACHE_FILES = (
    ".cargo/.package-cache",
    ".cargo/.package-cache-mutate",
    ".cargo/.global-cache",
)


@dataclass
class CleanStats:
    """Counters for removed or candidate artifacts."""

    dirs_removed: int = 0
    files_removed: int = 0
    bytes_freed: int = 0
    errors: int = 0

    def add_path(self, path: Path, dry_run: bool) -> None:
        """Remove one path; a failure is logged and counted, never fatal."""
        size = measure_size(path)
        is_dir = path.is_dir() and not path.is_symlink()
        try:
            if not dry_run:
                if is_dir:
                    rmtree_force(path)
                else:
                    unlink_force(path)
        except OSError as exc:
            self.errors += 1
            print(f"error: cannot remove {path}: {exc}", file=sys.stderr)
            return
        if is_dir:
            self.dirs_removed += 1
        else:
            self.files_removed += 1
        self.bytes_freed += size


def measure_size(path: Path) -> int:
    """Return total logical size in bytes without following symlinks."""
    try:
        st = os.lstat(path)
    except OSError:
        return 0
    if not stat.S_ISDIR(st.st_mode):
        return st.st_size

    total = st.st_size
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as it:
                for entry in it:
                    try:
                        est = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    total += est.st_size
                    if stat.S_ISDIR(est.st_mode):
                        stack.append(Path(entry.path))
        except OSError:
            continue
    return total


def unlink_force(path: Path) -> None:
    """Unlink a file or symlink, relaxing parent write bits if needed."""
    try:
        os.unlink(path)
    except PermissionError:
        parent = os.path.dirname(path)
        os.chmod(parent, stat.S_IRWXU)
        os.unlink(path)


def rmtree_force(root: Path) -> None:
    """Recursively remove a directory even when read-only files/dirs exist."""

    def handle_exc(func, failed_path: str, exc: BaseException) -> None:
        if not isinstance(exc, PermissionError):
            raise exc
        parent = os.path.dirname(failed_path)
        if Path(parent) != root.parent and os.path.exists(parent):
            os.chmod(parent, stat.S_IRWXU)
        if os.path.exists(failed_path) and not os.path.islink(failed_path):
            os.chmod(failed_path, stat.S_IRWXU)
        func(failed_path)

    shutil.rmtree(root, onexc=handle_exc)


def has_cachedir_tag(dir_path: Path) -> bool:
    """Check whether dir_path starts with a standard CACHEDIR.TAG header."""
    tag = dir_path / "CACHEDIR.TAG"
    if tag.is_symlink() or not tag.is_file():
        return False
    try:
        with tag.open("rb") as f:
            return f.read(len(CACHEDIR_TAG_PREFIX)) == CACHEDIR_TAG_PREFIX
    except OSError:
        return False


def is_nix_result_symlink(path: Path) -> bool:
    """Return True only for `result`/`result-*` symlinks pointing into /nix/store."""
    name = path.name
    if not (name == "result" or name.startswith("result-")):
        return False
    if not path.is_symlink():
        return False
    try:
        return os.readlink(path).startswith("/nix/store/")
    except OSError:
        return False


def is_environment_dir(dir_path: Path, siblings: set[str]) -> bool:
    """Return True if dir_path is a regenerable dependency environment."""
    name = dir_path.name
    if name in ENVIRONMENT_DIRS:
        return True
    if name in {".venv", "venv"}:
        return (dir_path / "pyvenv.cfg").is_file()
    if name == "node_modules":
        return "package.json" in siblings or any((dir_path / m).exists() for m in NODE_MODULES_MARKERS)
    return False


def is_generated_project_dir(dir_path: Path, siblings: set[str]) -> bool:
    """Return True if dir_path inside ~/Projects is a safely regenerable build output or cache."""
    name = dir_path.name
    if name in UNCONDITIONAL_PROJECT_DIRS:
        return True
    if has_cachedir_tag(dir_path):
        return True
    if name == "target":
        return "Cargo.toml" in siblings or (dir_path / ".rustc_info.json").is_file()
    if (dir_path / "CMakeCache.txt").is_file():
        return True
    if (dir_path / "meson-info").is_dir() and (dir_path / "build.ninja").is_file():
        return True
    if (dir_path / "doctrees").is_dir() and (dir_path / "html" / ".buildinfo").is_file():
        return True
    return False


def prune_devenv_shells(devenv_dir: Path, stats: CleanStats, dry_run: bool, verbose: bool) -> None:
    """Delete stale .devenv/shell-*.sh scripts, keeping the newest one."""
    shells: list[tuple[float, Path]] = []
    try:
        with os.scandir(devenv_dir) as it:
            for entry in it:
                if (
                    entry.name.startswith(DEVENV_SHELL_PREFIX)
                    and entry.name.endswith(DEVENV_SHELL_SUFFIX)
                    and entry.is_file(follow_symlinks=False)
                ):
                    try:
                        shells.append((entry.stat(follow_symlinks=False).st_mtime, Path(entry.path)))
                    except OSError:
                        continue
    except OSError:
        return
    shells.sort()
    for _, shell in shells[:-1]:
        if verbose:
            print(f"remove file {shell}")
        stats.add_path(shell, dry_run)


def clean_projects_tree(
    projects_dir: Path,
    stats: CleanStats,
    dry_run: bool,
    verbose: bool,
    keep_environments: bool = False,
) -> None:
    """Sweep regenerable artifacts under projects_dir without entering .git or symlinks."""
    if not projects_dir.is_dir() or projects_dir.is_symlink():
        return

    for dirpath, dirnames, filenames in os.walk(projects_dir, topdown=True, followlinks=False):
        current = Path(dirpath)
        siblings = set(dirnames) | set(filenames)
        kept_dirs: list[str] = []

        for dname in dirnames:
            if dname == ".git":
                continue
            dpath = current / dname
            if dpath.is_symlink():
                if is_nix_result_symlink(dpath):
                    if verbose:
                        print(f"remove symlink {dpath}")
                    stats.add_path(dpath, dry_run)
                continue
            if is_environment_dir(dpath, siblings):
                if keep_environments:
                    # Kept, and not entered: a venv or node_modules holds many
                    # build/.cache/__pycache__ names that belong to it.
                    if dname == ".devenv":
                        prune_devenv_shells(dpath, stats, dry_run, verbose)
                    continue
                if verbose:
                    print(f"remove dir {dpath}")
                stats.add_path(dpath, dry_run)
                continue
            if is_generated_project_dir(dpath, siblings):
                if verbose:
                    print(f"remove dir {dpath}")
                stats.add_path(dpath, dry_run)
                continue
            kept_dirs.append(dname)

        dirnames[:] = kept_dirs

        for fname in filenames:
            fpath = current / fname
            if fpath.is_symlink():
                if is_nix_result_symlink(fpath):
                    if verbose:
                        print(f"remove symlink {fpath}")
                    stats.add_path(fpath, dry_run)
                continue
            if (fname in ENVIRONMENT_FILES and not keep_environments) or fname.endswith(PROJECT_GENERATED_SUFFIXES):
                if verbose:
                    print(f"remove file {fpath}")
                stats.add_path(fpath, dry_run)


def clean_home_caches(home_dir: Path, stats: CleanStats, dry_run: bool, verbose: bool) -> None:
    """Clear selected tool cache directories and lock files directly under home_dir."""
    if not home_dir.is_dir() or home_dir.is_symlink():
        return

    targets: list[Path] = [home_dir / rel for rel in HOME_CACHE_DIRS]
    cache_root = home_dir / ".cache"
    if cache_root.is_dir() and not cache_root.is_symlink():
        try:
            with os.scandir(cache_root) as it:
                for entry in it:
                    if entry.name.startswith("qtshadercache-") and entry.is_dir(follow_symlinks=False):
                        targets.append(Path(entry.path))
        except OSError:
            pass

    for target in targets:
        if target.is_dir() and not target.is_symlink():
            if verbose:
                print(f"remove dir {target}")
            stats.add_path(target, dry_run)

    for rel in HOME_CACHE_FILES:
        target = home_dir / rel
        if (target.is_file() or target.is_symlink()) and not target.is_dir():
            if verbose:
                print(f"remove file {target}")
            stats.add_path(target, dry_run)


def format_bytes(num_bytes: int) -> str:
    """Format byte counts concisely for journald logs."""
    value = float(num_bytes)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024.0 or unit == "TiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{num_bytes} B"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home-dir", type=Path, default=Path.home())
    parser.add_argument("--projects-dir", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--keep-environments",
        action="store_true",
        help="keep .devenv/.direnv/.venv/venv/node_modules (prune stale devenv shell scripts only)",
    )
    args = parser.parse_args(argv)

    home_dir = args.home_dir
    projects_dir = args.projects_dir if args.projects_dir is not None else (home_dir / "Projects")

    stats = CleanStats()
    clean_projects_tree(
        projects_dir,
        stats,
        dry_run=args.dry_run,
        verbose=args.verbose or args.dry_run,
        keep_environments=args.keep_environments,
    )
    clean_home_caches(home_dir, stats, dry_run=args.dry_run, verbose=args.verbose or args.dry_run)

    prefix = "[dry-run] " if args.dry_run else ""
    print(
        f"{prefix}clean-dev-cache: "
        f"{stats.dirs_removed} dirs, {stats.files_removed} files/links, "
        f"{format_bytes(stats.bytes_freed)} freed, {stats.errors} errors"
    )
    # Non-zero only after the whole sweep ran, so the unit shows as failed.
    return 1 if stats.errors else 0


if __name__ == "__main__":
    sys.exit(main())
