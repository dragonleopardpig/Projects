#!/usr/bin/env python3
"""Unit tests for modules/impermanence-clean-dev.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import stat
import sys
import tempfile
import unittest


def load_cleaner():
    script = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "modules/impermanence-clean-dev.py"
    spec = importlib.util.spec_from_file_location("impermanence_clean_dev", script)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


CLEANER = load_cleaner()


class CleanDevTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.projects = self.home / "Projects"
        self.outside = self.root / "outside"
        self.home.mkdir()
        self.projects.mkdir()
        self.outside.mkdir()

    def tearDown(self) -> None:
        # Ensure temp dir cleanup works even if a test keeps read-only items.
        for path in [self.home, self.outside]:
            if path.exists():
                for sub in path.rglob("*"):
                    if not sub.is_symlink():
                        try:
                            sub.chmod(stat.S_IRWXU)
                        except OSError:
                            pass
        self.tmp.cleanup()

    def touch(self, path: Path, data: bytes = b"x") -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_cleans_only_generated_artifacts_and_preserves_sources(self) -> None:
        # Removable Rust target (Cargo.toml sibling + read-only file)
        ro_file = self.touch(self.projects / "strata/Cargo.toml", b"[package]")
        self.assertTrue(ro_file.exists())
        ro_target_file = self.touch(self.projects / "strata/target/debug/libx.rlib", b"artifact")
        ro_target_file.chmod(0o444)
        (self.projects / "strata/target/debug").chmod(0o555)
        self.touch(self.projects / "strata/src/main.rs", b"fn main() {}")

        # Non-Rust folder named target must survive
        keep_target = self.touch(self.projects / "docs/target/keep.txt", b"important")

        # CACHEDIR.TAG directory
        self.touch(
            self.projects / "tool/.pytest_cache/CACHEDIR.TAG",
            b"Signature: 8a477f597d28d172789f06886806bc55\n",
        )
        self.touch(self.projects / "tool/.pytest_cache/v/cache/lastfailed", b"{}")

        # direnv / devenv / python / node / cmake / meson / sphinx
        self.touch(self.projects / ".direnv/flake-profile-1", b"link")
        self.touch(self.projects / "app/.devenv/state/venv/bin/python", b"bin")
        self.touch(self.projects / "app/.devenv.flake.nix", b"{}")
        self.touch(self.projects / "app/pkg/__pycache__/m.cpython-313.pyc", b"pyc")
        self.touch(self.projects / "app/pkg/module.py", b"print(1)")
        self.touch(self.projects / "app/loose.elc", b"elc")
        self.touch(self.projects / "app/.venv/pyvenv.cfg", b"home = /nix/store/python")
        self.touch(self.projects / "app/venv/handcrafted.py", b"# no pyvenv.cfg")
        self.touch(self.projects / "web/package.json", b"{}")
        self.touch(self.projects / "web/node_modules/pkg/index.js", b"js")
        self.touch(self.projects / "notes/node_modules/saved.txt", b"no package.json")
        self.touch(self.projects / "cpp/build_local/CMakeCache.txt", b"CMAKE")
        self.touch(self.projects / "cpp/build/source_template.txt", b"keep build script")
        self.touch(self.projects / "meson/build/meson-info/intro.json", b"{}")
        self.touch(self.projects / "meson/build/build.ninja", b"ninja")
        self.touch(self.projects / "optics/docs/build/doctrees/index.doctree", b"doc")
        self.touch(self.projects / "optics/docs/build/html/.buildinfo", b"sphinx")

        # Nix result symlinks vs ordinary result files
        (self.projects / "app/result").symlink_to("/nix/store/00000000000000000000000000000000-app")
        (self.projects / "app/result-bin").symlink_to("/nix/store/11111111111111111111111111111111-bin")
        self.touch(self.projects / "notes/result", b"experimental data")
        (self.projects / "notes/result-ref").symlink_to("../outside-ref")

        # Prebuilt emacs grammar and .git internals must survive
        self.touch(self.projects / "emacs/tree-sitter/rust.so", b"ELF")
        self.touch(self.projects / "strata/.git/objects/fake.pyc", b"git")

        # Symlinked directory outside Projects must NOT be entered
        self.touch(self.outside / "__pycache__/outside.pyc", b"outside")
        (self.projects / "ext-link").symlink_to(self.outside)

        # Home caches vs sensitive user files
        self.touch(self.home / ".cargo/registry/cache/crate.crate", b"crate")
        self.touch(self.home / ".cargo/git/db/repo", b"git")
        self.touch(self.home / ".cargo/.package-cache", b"lock")
        self.touch(self.home / ".cargo/binstall.toml", b"keep")
        self.touch(self.home / ".cache/nix/eval-cache.sqlite", b"nix")
        self.touch(self.home / ".cache/qtshadercache-x86_64-little_endian-lp64/s", b"qt")
        self.touch(self.home / ".cache/cliphist/db", b"clip")
        self.touch(self.home / ".cache/Proton/vfs", b"vfs")
        self.touch(self.home / ".local/share/uv/archive/wheel", b"uv")
        self.touch(self.home / ".local/share/Trash/files/old", b"trash")
        self.touch(self.home / ".local/share/keyrings/login.keyring", b"secret")
        self.touch(self.home / ".ssh/id_ed25519", b"key")

        # Dry-run must leave everything intact
        rc = CLEANER.main(["--home-dir", str(self.home), "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertTrue((self.projects / "strata/target").exists())
        self.assertTrue((self.home / ".cargo/registry").exists())

        # Real run
        rc = CLEANER.main(["--home-dir", str(self.home), "--verbose"])
        self.assertEqual(rc, 0)

        # Deleted artifacts
        for gone in [
            self.projects / "strata/target",
            self.projects / "tool/.pytest_cache",
            self.projects / ".direnv",
            self.projects / "app/.devenv",
            self.projects / "app/.devenv.flake.nix",
            self.projects / "app/pkg/__pycache__",
            self.projects / "app/loose.elc",
            self.projects / "app/.venv",
            self.projects / "web/node_modules",
            self.projects / "cpp/build_local",
            self.projects / "meson/build",
            self.projects / "optics/docs/build",
            self.home / ".cargo/registry",
            self.home / ".cargo/git",
            self.home / ".cargo/.package-cache",
            self.home / ".cache/nix",
            self.home / ".cache/qtshadercache-x86_64-little_endian-lp64",
            self.home / ".local/share/uv",
            self.home / ".local/share/Trash/files",
        ]:
            self.assertFalse(gone.exists(), f"expected removed: {gone}")

        self.assertFalse((self.projects / "app/result").is_symlink())
        self.assertFalse((self.projects / "app/result-bin").is_symlink())

        # Preserved files and directories
        for kept in [
            self.projects / "strata/Cargo.toml",
            self.projects / "strata/src/main.rs",
            keep_target,
            self.projects / "app/pkg/module.py",
            self.projects / "app/venv/handcrafted.py",
            self.projects / "notes/node_modules/saved.txt",
            self.projects / "cpp/build/source_template.txt",
            self.projects / "notes/result",
            self.projects / "emacs/tree-sitter/rust.so",
            self.projects / "strata/.git/objects/fake.pyc",
            self.outside / "__pycache__/outside.pyc",
            self.home / ".cargo/binstall.toml",
            self.home / ".cache/cliphist/db",
            self.home / ".cache/Proton/vfs",
            self.home / ".local/share/keyrings/login.keyring",
            self.home / ".ssh/id_ed25519",
        ]:
            self.assertTrue(kept.exists(), f"expected preserved: {kept}")

        self.assertTrue((self.projects / "notes/result-ref").is_symlink())
        self.assertTrue((self.projects / "ext-link").is_symlink())


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
