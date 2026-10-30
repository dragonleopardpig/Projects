import argparse
from configparser import RawConfigParser
import filecmp
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time


class Consolidation:
    def __init__(self, home):
        self.home = Path(home)
        self.folder = self.home / "Scramble Private"
        self.state = self.home / ".local/state/scramble/consolidation"
        self.staging = self.state / "staging"
        self.ready = self.home / ".config/rclone/scramble-private-v2-ready"
        self.config = self.home / ".config/rclone/rclone.conf"
        self.hostname = socket.gethostname()
        self.progress = {}
        progress_file = self.state / "progress.json"
        if progress_file.is_file():
            self.progress = json.loads(progress_file.read_text())

    def save(self):
        temporary = self.state / "progress.json.tmp"
        temporary.write_text(json.dumps(self.progress, indent=2) + "\n")
        temporary.replace(self.state / "progress.json")

    def phase(self, message):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = self.state / "phase.tmp"
        temporary.write_text(message + "\n")
        temporary.replace(self.state / "phase")
        print(message, flush=True)

    def run(self, arguments, capture=False, check=True):
        return subprocess.run(arguments, check=check, text=True,
                              stdout=subprocess.PIPE if capture else None,
                              stderr=subprocess.PIPE if capture else None)

    def rclone(self, *arguments, capture=False):
        return self.run([
            "rclone", *map(str, arguments),
            "--config", str(self.config), "--webdav-encoding", "Colon",
            "--header-upload", "Content-Type: application/octet-stream",
            "--transfers", "1", "--checkers", "2", "--tpslimit", "2",
            "--contimeout", "10s", "--timeout", "30m", "--retries", "3",
            "--low-level-retries", "3", "--retries-sleep", "30s",
            "--stats", "30s", "--stats-one-line", "--stats-log-level", "NOTICE",
        ], capture=capture)

    def checkpoint(self, name, operation):
        if self.progress.get(name):
            return
        operation()
        self.progress[name] = True
        self.save()

    def validate_key(self):
        parser = RawConfigParser()
        parser.read(self.config)
        if (parser.get("scramble_private", "type", fallback="") != "crypt"
                or parser.get("scramble_private", "remote", fallback="") != "scramble_drive:EncryptedSync"
                or not parser.get("scramble_private", "password", fallback="")):
            raise RuntimeError("Import the existing Scramble crypt key before consolidating; no replacement key is generated.")
        self.rclone("cat", "scramble_private:Current/RCLONE_TEST", capture=True)

    def retire_legacy_services(self):
        timers = ["scramble-public-sync.timer", "scramble-private-sync.timer",
                  "scramble-references-download.timer"]
        self.run(["systemctl", "--user", "stop", *timers], check=False, capture=True)
        workers = ["scramble-public-sync.service", "scramble-private-sync.service",
                   "scramble-references-download.service"]
        for unit in workers:
            state = self.run(["systemctl", "--user", "show", "--value", "-p", "ActiveState", unit],
                             check=False, capture=True).stdout.strip()
            if state in {"active", "activating"}:
                self.run(["systemctl", "--user", "kill", "--kill-whom=main", "--signal=SIGINT", unit])
        deadline = time.monotonic() + 180
        for unit in workers:
            while self.run(["systemctl", "--user", "show", "--value", "-p", "ActiveState", unit],
                           check=False, capture=True).stdout.strip() in {"active", "activating", "deactivating"}:
                if time.monotonic() > deadline:
                    raise RuntimeError("A legacy sync is still finishing; consolidation will retry without moving its files.")
                time.sleep(1)
        self.run(["systemctl", "--user", "stop", "scramble-public-mount.service",
                  "scramble-private-mount.service"], check=False, capture=True)
        for folder in [self.folder, self.home / "Scramble Public"]:
            try:
                mounted = folder.is_mount()
            except OSError:
                mounted = True
            if mounted:
                self.run(["/run/wrappers/bin/fusermount3", "-u", str(folder)], check=False, capture=True)
            if folder.is_mount():
                raise RuntimeError(f"Close files using the cloud mount before consolidating: {folder}")
        if self.folder.is_symlink():
            raise RuntimeError("Scramble Private must be a real offline directory, not a symlink.")

    def backup(self):
        self.phase("Backing up the existing local folders and crypt configuration")
        shutil.copy2(self.config, self.state / "rclone.conf.before-consolidation")
        os.chmod(self.state / "rclone.conf.before-consolidation", 0o600)
        for source in [self.home / "Documents" / name for name in
                       ["Scramble Sync", "Scramble Public", "Scramble References"]] + [self.folder]:
            if source.is_symlink():
                raise RuntimeError(f"Refusing to move a symlinked legacy sync root: {source}")
            if source.is_dir():
                shutil.copytree(source, self.state / "local-before" / source.name,
                                dirs_exist_ok=True, symlinks=True)

    def conflict_path(self, destination, source, origin):
        digest = hashlib.sha256()
        if source.is_file():
            with source.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256")
        else:
            digest.update(str(source).encode())
        return destination.with_name(
            f"{destination.stem}.from-{origin}-{self.hostname}-{digest.hexdigest()[:10]}{destination.suffix}"
        )

    def merge(self, source, destination, prefer_source=False, origin="local"):
        if not source.exists() and not source.is_symlink():
            return
        if source.is_symlink():
            raise RuntimeError(f"A symlink inside sync data needs manual review: {source}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() and not destination.is_symlink():
            source.rename(destination)
            return
        if source.is_dir() and destination.is_dir() and not destination.is_symlink():
            for child in list(source.iterdir()):
                self.merge(child, destination / child.name, prefer_source, origin)
            source.rmdir()
            return
        if source.is_file() and destination.is_file() and filecmp.cmp(source, destination, shallow=False):
            source.unlink()
            return
        loser = destination if prefer_source else source
        conflict = self.conflict_path(destination, loser, "local" if prefer_source else origin)
        if conflict.exists():
            if loser.is_file() and conflict.is_file() and filecmp.cmp(loser, conflict, shallow=False):
                loser.unlink()
            else:
                raise RuntimeError(f"A preserved conflict already exists and needs review: {conflict}")
        else:
            loser.rename(conflict)
        if prefer_source:
            source.rename(destination)

    def move_local_folders(self):
        self.phase("Consolidating local files into ~/Scramble Private")
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.folder, 0o700)
        for name, destination in [
            ("Scramble Sync", self.folder),
            ("Scramble Public", self.folder),
            ("Scramble References", self.folder / "References"),
        ]:
            source = self.home / "Documents" / name
            if not source.is_dir():
                continue
            if name == "Scramble Public" and (source / "RCLONE_TEST").is_file():
                self.merge(source / "RCLONE_TEST", self.state / "public-access-marker")
            self.merge(source, destination)
        for name in [".Scramble Public History", ".Scramble Sync History"]:
            self.merge(self.home / "Documents" / name, self.state / "history" / name.lstrip("."))
        public_mount = self.home / "Scramble Public"
        if public_mount.is_dir():
            if any(public_mount.iterdir()):
                self.merge(public_mount, self.folder / "Recovered Public Files")
            else:
                public_mount.rmdir()
        self.update_links()

    def update_links(self):
        mappings = [
            (self.home / "Documents/Scramble References", self.folder / "References"),
            (self.home / "Documents/Scramble Public", self.folder),
            (self.home / "Documents/Scramble Sync", self.folder),
            (self.home / "Scramble Public/References", self.folder / "References"),
            (self.home / "Scramble Public/PublicSync/Current", self.folder),
            (self.home / "Scramble Public/Misc", self.folder / "Misc"),
        ]
        projects = self.home / "Projects"
        if projects.is_dir():
            for parent, directories, files in os.walk(projects, followlinks=False):
                directories[:] = [name for name in directories
                                  if name not in {".git", "node_modules", ".direnv", ".cache"}]
                for name in directories + files:
                    link = Path(parent) / name
                    if not link.is_symlink():
                        continue
                    target = Path(os.path.abspath(link.parent / os.readlink(link)))
                    for old, new in mappings:
                        if target.is_relative_to(old):
                            temporary = link.with_name(link.name + ".scramble-migration")
                            if temporary.is_symlink():
                                temporary.unlink()
                            temporary.symlink_to(new / target.relative_to(old))
                            temporary.replace(link)
                            break
        bookmarks = self.home / ".config/gtk-3.0/bookmarks"
        old_uris = {old.as_uri() for old, _ in mappings}
        old_uris.update({(self.home / "Scramble Public").as_uri(), self.folder.as_uri()})
        lines = bookmarks.read_text().splitlines() if bookmarks.exists() else []
        lines = [line for line in lines if not line.split() or line.split()[0] not in old_uris]
        lines.append(self.folder.as_uri() + " Scramble Private")
        bookmarks.parent.mkdir(parents=True, exist_ok=True)
        temporary = bookmarks.with_name(bookmarks.name + ".scramble-migration")
        temporary.write_text("\n".join(lines) + "\n")
        temporary.replace(bookmarks)

    def import_cloud(self, remote, name, destination, prefer_source=False):
        staging = self.staging / name
        self.phase(f"Importing {name} into Scramble Private; original cloud copies are retained")
        def download():
            staging.mkdir(parents=True, exist_ok=True)
            exclusions = [] if name == "private" else ["--exclude", "/RCLONE_TEST"]
            self.rclone("copy", remote, staging, *exclusions)
            if name == "private":
                self.progress.setdefault("uploaded-hashes", {}).update(self.hash_manifest(staging))
                self.save()
        self.checkpoint("download-" + name, download)
        self.checkpoint("merge-" + name, lambda: self.merge(staging, destination, prefer_source, "cloud"))

    def import_all_cloud(self):
        self.import_cloud("scramble_private:Current", "private", self.folder, prefer_source=True)
        listing = json.loads(self.rclone("lsjson", "scramble_drive:", "--max-depth", "1", capture=True).stdout)
        directories = {entry["Name"] for entry in listing if entry["IsDir"]}
        for name in sorted(directories - {"EncryptedSync", "PublicSync"}):
            self.import_cloud("scramble_drive:" + name, name, self.folder / name)
        if "PublicSync" in directories:
            self.import_cloud("scramble_drive:PublicSync/Current", "public-attachments", self.folder)
            public_dirs = self.rclone("lsf", "scramble_drive:PublicSync", "--dirs-only", "--max-depth", "1", capture=True).stdout.splitlines()
            if "History/" in public_dirs:
                self.phase("Encrypting the old public cloud history; originals are retained")
                self.checkpoint("public-history", lambda: self.rclone(
                    "copy", "scramble_drive:PublicSync/History", "scramble_private:History/LegacyPublic", "--ignore-existing"))
                self.checkpoint("verify-public-history", lambda: self.rclone(
                    "check", "scramble_drive:PublicSync/History", "scramble_private:History/LegacyPublic",
                    "--download", "--one-way"))
        if any(not entry["IsDir"] for entry in listing):
            def root_files():
                staging = self.staging / "root-files"
                self.rclone("copy", "scramble_drive:", staging, "--max-depth", "1")
                self.merge(staging, self.folder)
            self.checkpoint("root-files", root_files)

    def hash_manifest(self, root):
        hashes = {}
        for file in sorted(root.rglob("*")):
            if file.is_symlink():
                raise RuntimeError(f"Keep real files, not symlinks, inside the sync folder: {file}")
            if file.is_file():
                relative = file.relative_to(root).as_posix()
                if "\n" in relative or "\r" in relative:
                    raise RuntimeError("A filename containing a newline needs manual review.")
                with file.open("rb") as stream:
                    hashes[relative] = hashlib.file_digest(stream, "sha256").hexdigest()
        return hashes

    def upload(self):
        receipts = self.progress.setdefault("uploaded-hashes", {})
        while True:
            manifest = self.hash_manifest(self.folder)
            pending = [name for name, digest in manifest.items() if receipts.get(name) != digest]
            if not pending:
                return
            total = len(pending)
            completed = 0
            while pending:
                batch = []
                while pending and len(batch) < 25:
                    name = pending[0]
                    large = (self.folder / name).stat().st_size > 8 * 1024 * 1024
                    if large and batch:
                        break
                    batch.append(pending.pop(0))
                    if large:
                        break
                self.phase(f"Encrypting and uploading private files: {completed}/{total} in this pass")
                manifest_file = self.state / "upload-files.txt"
                manifest_file.write_text("\n".join(batch) + "\n")
                self.rclone("copy", self.folder, "scramble_private:Current", "--ignore-times",
                            "--files-from-raw", manifest_file,
                            "--backup-dir", f"scramble_private:History/Consolidation/{self.hostname}/{time.time_ns()}")
                receipts.update({name: manifest[name] for name in batch})
                self.save()
                completed += len(batch)

    def verify(self):
        self.phase("Verifying the encrypted cloud copy against every local file")
        self.rclone("check", self.folder, "scramble_private:Current", "--download")
        self.progress["cloud-verified"] = True
        self.save()

    def initialize_baseline(self):
        self.phase("Establishing the single private sync baseline")
        self.rclone("bisync", self.folder, "scramble_private:Current", "--resync", "--resync-mode", "path2",
                    "--compare", "size,checksum", "--download-hash", "--check-access", "--max-delete", "50",
                    "--exclude", "/References/**", "--exclude", "/Misc/**",
                    "--resilient", "--recover", "--max-lock", "10m",
                    "--backup-dir1", self.state / "history/baseline",
                    "--backup-dir2", "scramble_private:History/Consolidation")

    def execute(self):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.state / "migration.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            progress_file = self.state / "progress.json"
            if progress_file.is_file():
                self.progress = json.loads(progress_file.read_text())
            if self.ready.exists():
                self.run(["systemctl", "--user", "start", "--no-block", "scramble-private-sync.timer", "scramble-private-sync.service"])
                return
            self.phase("Checking the existing private encryption key")
            self.validate_key()
            self.retire_legacy_services()
            self.checkpoint("local-backup", self.backup)
            self.checkpoint("local-move", self.move_local_folders)
            self.import_all_cloud()
            self.upload()
            self.checkpoint("baseline", self.initialize_baseline)
            self.verify()
            self.ready.touch(mode=0o600)
            self.phase("Complete: one offline Scramble Private folder; legacy cloud originals retained for rollback")
            self.run(["systemctl", "--user", "reset-failed", "scramble-private-sync.service"], check=False)
            self.run(["systemctl", "--user", "start", "--no-block", "scramble-private-sync.timer", "scramble-private-sync.service"])


def main():
    parser = argparse.ArgumentParser(description="Safely consolidate Scramble into one encrypted offline folder.")
    parser.parse_args()
    os.umask(0o077)
    os.environ.pop("LD_LIBRARY_PATH", None)
    os.environ.pop("LD_PRELOAD", None)
    consolidation = Consolidation(Path.home())
    try:
        consolidation.execute()
    except (OSError, RuntimeError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        consolidation.phase(f"Consolidation paused safely: {error}")
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
