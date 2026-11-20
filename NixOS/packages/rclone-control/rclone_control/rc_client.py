"""Rclone RC daemon client, CLI wrappers, and mount discovery for rclone-control."""

from __future__ import annotations

import base64
import configparser
from dataclasses import dataclass
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import socket
import subprocess
import time
from typing import Any
import urllib.error
import urllib.request

SYSTEMD_MOUNT_UNITS = (
    ("gdrive-mount.service", "Google Drive", "gdrive:"),
    ("protondrive-mount.service", "Proton Drive", "protondrive:"),
    ("mega-mount.service", "MEGA", "mega:"),
    ("scramble-cloud-mount.service", "Scramble Cloud", "scramble_private:Current"),
    ("filelu-mount.service", "FileLu", "filelu:"),
)


def _find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def format_bytes(num: int | float | None) -> str:
    if num is None or num < 0:
        return "—"
    value = float(num)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024.0 or unit == "TiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024.0
    return f"{num} B"


def split_fs_path(spec: str) -> tuple[str, str]:
    """Split 'remote:sub/path' -> ('remote:', 'sub/path') or local '/a/b' -> ('/', 'a/b')."""
    if ":" in spec and not spec.startswith("/"):
        remote, sub = spec.split(":", 1)
        return f"{remote}:", sub.lstrip("/")
    p = os.path.abspath(os.path.expanduser(spec))
    return "/", p.lstrip("/")


def join_fs_path(fs_root: str, sub: str) -> str:
    clean = sub.strip("/")
    if fs_root == "/":
        return f"/{clean}" if clean else "/"
    return f"{fs_root}{clean}" if clean else fs_root


@dataclass
class MountInfo:
    source: str
    mountpoint: str
    pid: int | None
    systemd_unit: str | None
    active_state: str
    rc_addr: str | None
    read_only: bool
    vfs_cache_mode: str


class RcloneClient:
    """Manages an isolated rclone rcd instance and exposes RC + CLI helpers."""

    def __init__(self, config_path: Path | None = None, auto_start: bool = True) -> None:
        self.config_path = config_path or Path(os.environ.get("RCLONE_CONFIG") or (Path.home() / ".config/rclone/rclone.conf"))
        self.rclone_bin = shutil.which("rclone") or "rclone"
        self._port: int | None = None
        self._user = f"rc-{secrets.token_hex(6)}"
        self._password = secrets.token_urlsafe(24)
        self._auth_header = "Basic " + base64.b64encode(f"{self._user}:{self._password}".encode()).decode()
        self._proc: subprocess.Popen[bytes] | None = None
        if auto_start:
            self.ensure_started()

    @property
    def base_url(self) -> str:
        if self._port is None:
            raise RuntimeError("rclone rcd is not running")
        return f"http://127.0.0.1:{self._port}"

    def _base_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["RCLONE_CONFIG"] = str(self.config_path)
        return env

    def ensure_started(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return
        self._port = _find_free_port()
        env = self._base_env()
        env["RCLONE_RC_USER"] = self._user
        env["RCLONE_RC_PASS"] = self._password
        cmd = [
            self.rclone_bin,
            "rcd",
            f"--rc-addr=127.0.0.1:{self._port}",
            "--rc-enable-metrics=false",
            "--transfers=4",
            "--checkers=8",
        ]
        self._proc = subprocess.Popen(
            cmd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            if self._proc.poll() is not None:
                err = self._proc.stderr.read().decode("utf-8", "replace") if self._proc.stderr else ""
                raise RuntimeError(f"rclone rcd exited early: {err.strip()}")
            try:
                self.call("rc/noop", {}, timeout=1.0)
                return
            except Exception:
                time.sleep(0.08)
        raise RuntimeError("Timed out waiting for rclone rcd to listen")

    def shutdown(self) -> None:
        if self._proc is None:
            return
        if self._proc.poll() is None:
            try:
                self.call("core/quit", {}, timeout=1.5)
            except Exception:
                pass
            try:
                self._proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
                    self._proc.wait(timeout=1.0)
        if self._proc.stderr is not None:
            try:
                self._proc.stderr.close()
            except OSError:
                pass
        self._proc = None

    def call(self, endpoint: str, params: dict[str, Any] | None = None, timeout: float = 30.0) -> dict[str, Any]:
        return self.call_url(f"{self.base_url}/{endpoint.lstrip('/')}", params=params, auth_header=self._auth_header, timeout=timeout)

    @staticmethod
    def call_url(
        url: str,
        params: dict[str, Any] | None = None,
        auth_header: str | None = None,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        body = json.dumps(params or {}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if auth_header:
            headers["Authorization"] = auth_header
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(detail)
                msg = parsed.get("error") or detail
            except Exception:
                msg = detail or str(err)
            raise RuntimeError(f"rclone rc {url.rsplit('/', 1)[-1]} failed: {msg}") from err

    # ── Remotes & Config ──────────────────────────────────────────────────────

    def list_remotes(self) -> list[str]:
        res = self.call("config/listremotes")
        return sorted(str(r) for r in res.get("remotes", []))

    def config_dump(self) -> dict[str, dict[str, Any]]:
        return self.call("config/dump")

    def config_providers(self) -> list[dict[str, Any]]:
        res = self.call("config/providers")
        return list(res.get("providers", []))

    def config_create(self, name: str, rtype: str, parameters: dict[str, Any], obscure: bool = True) -> dict[str, Any]:
        return self.call("config/create", {
            "name": name,
            "type": rtype,
            "parameters": parameters,
            "opt": {"obscure": obscure, "nonInteractive": True},
        })

    def config_update(self, name: str, parameters: dict[str, Any], obscure: bool = True) -> dict[str, Any]:
        return self.call("config/update", {
            "name": name,
            "parameters": parameters,
            "opt": {"obscure": obscure, "nonInteractive": True},
        })

    def config_delete(self, name: str) -> dict[str, Any]:
        return self.call("config/delete", {"name": name})

    def rename_remote(self, old_name: str, new_name: str) -> None:
        cp = configparser.ConfigParser()
        cp.read(self.config_path, encoding="utf-8")
        if not cp.has_section(old_name):
            raise RuntimeError(f"Remote '{old_name}' not found")
        if cp.has_section(new_name):
            raise RuntimeError(f"Remote '{new_name}' already exists")
        items = dict(cp.items(old_name))
        cp.remove_section(old_name)
        cp.add_section(new_name)
        for k, v in items.items():
            cp.set(new_name, k, v)
        tmp = self.config_path.with_suffix(".conf.tmp")
        with tmp.open("w", encoding="utf-8") as stream:
            cp.write(stream)
        os.chmod(tmp, 0o600)
        tmp.replace(self.config_path)

    # ── Directory & File Operations ───────────────────────────────────────────

    def list_entries(self, spec: str, show_hidden: bool = False) -> list[dict[str, Any]]:
        if spec.startswith("/"):
            return self._list_local(Path(spec), show_hidden=show_hidden)
        fs_root, sub = split_fs_path(spec)
        res = self.call("operations/list", {"fs": fs_root, "remote": sub}, timeout=45.0)
        items = []
        for item in res.get("list", []):
            name = item.get("Name", "")
            if not show_hidden and name.startswith("."):
                continue
            items.append({
                "name": name,
                "path": item.get("Path", name),
                "size": int(item.get("Size", -1)),
                "mod_time": str(item.get("ModTime", "")),
                "is_dir": bool(item.get("IsDir", False)),
                "mime": str(item.get("MimeType", "")),
                "id": str(item.get("ID", "")),
            })
        return items

    @staticmethod
    def _list_local(path: Path, show_hidden: bool = False) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        with os.scandir(path) as it:
            for de in it:
                if not show_hidden and de.name.startswith("."):
                    continue
                try:
                    st = de.stat(follow_symlinks=False)
                    is_dir = de.is_dir(follow_symlinks=True)
                    size = -1 if is_dir else int(st.st_size)
                    mtime = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime))
                except OSError:
                    is_dir = de.is_dir()
                    size = -1
                    mtime = ""
                entries.append({
                    "name": de.name,
                    "path": str(de.path),
                    "size": size,
                    "mod_time": mtime,
                    "is_dir": is_dir,
                    "mime": "inode/directory" if is_dir else "",
                    "id": "",
                })
        return entries

    def about(self, remote_fs: str) -> dict[str, Any]:
        return self.call("operations/about", {"fs": remote_fs}, timeout=20.0)

    def fsinfo(self, remote_fs: str) -> dict[str, Any]:
        return self.call("operations/fsinfo", {"fs": remote_fs}, timeout=15.0)

    def mkdir(self, spec: str) -> None:
        if spec.startswith("/"):
            Path(spec).mkdir(parents=True, exist_ok=True)
            return
        fs_root, sub = split_fs_path(spec)
        self.call("operations/mkdir", {"fs": fs_root, "remote": sub})

    def stat_item(self, spec: str) -> dict[str, Any]:
        fs_root, sub = split_fs_path(spec)
        return self.call("operations/stat", {"fs": fs_root, "remote": sub})

    def dir_size(self, spec: str) -> dict[str, Any]:
        fs_root, sub = split_fs_path(spec)
        return self.call("operations/size", {"fs": fs_root, "remote": sub}, timeout=60.0)

    def hashsum_file(self, spec: str, hash_type: str = "md5") -> dict[str, Any]:
        fs_root, sub = split_fs_path(spec)
        return self.call("operations/hashsumfile", {"fs": fs_root, "remote": sub, "hashType": hash_type}, timeout=60.0)

    def public_link(self, spec: str) -> str:
        fs_root, sub = split_fs_path(spec)
        res = self.call("operations/publiclink", {"fs": fs_root, "remote": sub}, timeout=20.0)
        return str(res.get("url", ""))

    def rmdirs(self, spec: str, leave_root: bool = True) -> None:
        fs_root, sub = split_fs_path(spec)
        self.call("operations/rmdirs", {"fs": fs_root, "remote": sub, "leaveRoot": leave_root}, timeout=45.0)

    def rename_item(self, src_spec: str, dst_spec: str, is_dir: bool) -> dict[str, Any]:
        src_fs, src_sub = split_fs_path(src_spec)
        dst_fs, dst_sub = split_fs_path(dst_spec)
        if not is_dir:
            return self.call("operations/movefile", {
                "srcFs": src_fs, "srcRemote": src_sub,
                "dstFs": dst_fs, "dstRemote": dst_sub,
            }, timeout=60.0)
        # Directory rename via sync/move (server-side where supported).
        return self.call("sync/move", {
            "srcFs": src_spec, "dstFs": dst_spec, "deleteEmptySrcDirs": True,
        }, timeout=120.0)

    def delete_items(self, specs: list[tuple[str, bool]]) -> None:
        for spec, is_dir in specs:
            fs_root, sub = split_fs_path(spec)
            if is_dir:
                self.call("operations/purge", {"fs": fs_root, "remote": sub}, timeout=60.0)
            else:
                self.call("operations/deletefile", {"fs": fs_root, "remote": sub}, timeout=60.0)

    # ── Async Jobs, Stats & Bandwidth ─────────────────────────────────────────

    def start_transfer_job(
        self,
        operation: str,
        src_spec: str,
        dst_spec: str,
        dry_run: bool = False,
        transfers: int = 4,
        extra_config: dict[str, Any] | None = None,
        extra_params: dict[str, Any] | None = None,
    ) -> int:
        endpoint_map = {
            "copy": "sync/copy",
            "move": "sync/move",
            "sync": "sync/sync",
            "bisync": "sync/bisync",
            "check": "operations/check",
            "copyfile": "operations/copyfile",
            "movefile": "operations/movefile",
        }
        endpoint = endpoint_map[operation]
        cfg = {"DryRun": dry_run, "Transfers": int(transfers)}
        if extra_config:
            cfg.update(extra_config)

        if operation in ("copyfile", "movefile"):
            src_fs, src_sub = split_fs_path(src_spec)
            dst_fs, dst_sub = split_fs_path(dst_spec)
            payload: dict[str, Any] = {
                "srcFs": src_fs, "srcRemote": src_sub,
                "dstFs": dst_fs, "dstRemote": dst_sub,
                "_async": True, "_config": cfg,
            }
        elif operation == "bisync":
            payload = {
                "path1": src_spec, "path2": dst_spec,
                "_async": True, "_config": cfg,
            }
        else:
            payload = {
                "srcFs": src_spec, "dstFs": dst_spec,
                "_async": True, "_config": cfg,
            }
        if extra_params:
            payload.update(extra_params)

        res = self.call(endpoint, payload, timeout=15.0)
        return int(res["jobid"])

    def core_stats(self) -> dict[str, Any]:
        return self.call("core/stats", timeout=3.0)

    def core_transferred(self) -> list[dict[str, Any]]:
        res = self.call("core/transferred", timeout=3.0)
        return list(res.get("transferred", []))

    def job_status(self, jobid: int) -> dict[str, Any]:
        return self.call("job/status", {"jobid": jobid}, timeout=3.0)

    def job_stop(self, jobid: int) -> None:
        self.call("job/stop", {"jobid": jobid}, timeout=5.0)

    def set_bwlimit(self, rate: str) -> dict[str, Any]:
        return self.call("core/bwlimit", {"rate": rate}, timeout=5.0)

    # ── CLI Runners (Dry-run diff, Cat, Cryptdecode, Dedupe, Interactive) ────

    def run_cli(self, args: list[str], timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.rclone_bin, *args],
            env=self._base_env(),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def cat_preview(self, spec: str, max_bytes: int = 131072) -> str:
        res = self.run_cli(["cat", spec, "--count", str(max_bytes)], timeout=20.0)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or f"rclone cat exited {res.returncode}")
        return res.stdout

    def cryptdecode(self, remote_name: str, filenames: list[str]) -> str:
        res = self.run_cli(["cryptdecode", f"{remote_name.rstrip(':')}:", *filenames], timeout=15.0)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or f"cryptdecode exited {res.returncode}")
        return res.stdout

    def dry_run_preview(
        self,
        operation: str,
        src_spec: str,
        dst_spec: str,
        extra_flags: list[str] | None = None,
        timeout: float = 60.0,
    ) -> tuple[int, str]:
        args = [operation, src_spec, dst_spec, "--dry-run", "--stats=0"]
        if operation == "check":
            args = ["check", src_spec, dst_spec, "--combined", "-", "--stats=0"]
        else:
            args.append("-v")
        if extra_flags:
            args.extend(extra_flags)
        res = self.run_cli(args, timeout=timeout)
        combined = "\n".join(part for part in (res.stdout.strip(), res.stderr.strip()) if part)
        return res.returncode, combined

    def launch_interactive_config(self, args: list[str]) -> None:
        rclone_cmd = " ".join(shlex.quote(a) for a in [self.rclone_bin, *args])
        cfg = shlex.quote(str(self.config_path))
        shell_cmd = f"RCLONE_CONFIG={cfg} {rclone_cmd}; echo; read -p 'Press Enter to close...' _"
        for term in (os.environ.get("TERMINAL"), shutil.which("kitty"), shutil.which("foot")):
            resolved = shutil.which(term) if term else None
            if resolved:
                if os.path.basename(resolved) == "kitty":
                    cmd = [resolved, "--title", "Rclone Config", "-e", "bash", "-c", shell_cmd]
                else:
                    cmd = [resolved, "bash", "-c", shell_cmd]
                subprocess.Popen(cmd, start_new_session=True)
                return
        raise RuntimeError("No terminal found to run interactive rclone config")

    # ── FUSE Mount Discovery & Control ────────────────────────────────────────

    def discover_mounts(self) -> list[MountInfo]:
        mounts_by_path: dict[str, tuple[str, bool]] = {}
        try:
            for line in Path("/proc/mounts").read_text(encoding="utf-8", errors="replace").splitlines():
                parts = line.split()
                if len(parts) >= 4 and "fuse.rclone" in parts[2]:
                    mp = parts[1].replace("\\040", " ")
                    ro = "ro" in parts[3].split(",")
                    mounts_by_path[mp] = (parts[0], ro)
        except OSError:
            pass

        pid_by_mp: dict[str, tuple[int, str | None, str, bool]] = {}
        uid = os.getuid()
        for proc_dir in Path("/proc").glob("[0-9]*"):
            try:
                if proc_dir.stat().st_uid != uid:
                    continue
                raw = (proc_dir / "cmdline").read_bytes()
                if not raw:
                    continue
                args = [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a]
                if len(args) >= 4 and "rclone" in os.path.basename(args[0]) and "mount" in args[1:3]:
                    rc_addr = None
                    vfs_mode = "off"
                    ro_flag = "--read-only" in args
                    pos_args = [a for a in args[2:] if not a.startswith("-")]
                    for i, a in enumerate(args):
                        if a.startswith("--rc-addr="):
                            rc_addr = a.split("=", 1)[1]
                        elif a == "--rc-addr" and i + 1 < len(args):
                            rc_addr = args[i + 1]
                        elif a.startswith("--vfs-cache-mode="):
                            vfs_mode = a.split("=", 1)[1]
                        elif a == "--vfs-cache-mode" and i + 1 < len(args):
                            vfs_mode = args[i + 1]
                    if len(pos_args) >= 2:
                        pid_by_mp[pos_args[1]] = (int(proc_dir.name), rc_addr, vfs_mode, ro_flag)
            except (OSError, ValueError):
                continue

        results: list[MountInfo] = []
        seen_mps: set[str] = set()
        for unit, label, default_src in SYSTEMD_MOUNT_UNITS:
            props = self._systemd_unit_props(unit)
            if not props:
                continue
            active = props.get("ActiveState", "inactive")
            # Match typical home mountpoint.
            guess_mp = str(Path.home() / label)
            matched_mp = next((mp for mp, (src, _) in mounts_by_path.items() if src == default_src or mp == guess_mp), guess_mp)
            seen_mps.add(matched_mp)
            pid, rc_addr, vfs_mode, ro_flag = pid_by_mp.get(matched_mp, (None, None, "full", False))
            if matched_mp in mounts_by_path:
                ro_flag = mounts_by_path[matched_mp][1]
            results.append(MountInfo(
                source=default_src,
                mountpoint=matched_mp,
                pid=pid,
                systemd_unit=unit,
                active_state="mounted" if matched_mp in mounts_by_path else active,
                rc_addr=rc_addr,
                read_only=ro_flag,
                vfs_cache_mode=vfs_mode,
            ))

        for mp, (src, ro) in sorted(mounts_by_path.items()):
            if mp in seen_mps:
                continue
            pid, rc_addr, vfs_mode, _ = pid_by_mp.get(mp, (None, None, "off", ro))
            results.append(MountInfo(
                source=src,
                mountpoint=mp,
                pid=pid,
                systemd_unit=None,
                active_state="mounted",
                rc_addr=rc_addr,
                read_only=ro,
                vfs_cache_mode=vfs_mode,
            ))
        return results

    @staticmethod
    def _systemd_unit_props(unit: str) -> dict[str, str]:
        try:
            res = subprocess.run(
                ["systemctl", "--user", "show", unit, "-p", "LoadState,ActiveState"],
                capture_output=True, text=True, timeout=1.5, check=False,
            )
            props = {}
            for line in res.stdout.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    props[k] = v
            return props if props.get("LoadState") == "loaded" else {}
        except OSError:
            return {}

    def start_detached_mount(
        self,
        remote_spec: str,
        mountpoint: str,
        vfs_cache_mode: str = "full",
        read_only: bool = False,
        cache_max_size: str = "10G",
        dir_cache_time: str = "1m",
        extra_args: list[str] | None = None,
    ) -> int:
        mp = Path(os.path.expanduser(mountpoint))
        mp.mkdir(parents=True, exist_ok=True)
        rc_port = _find_free_port()
        cmd = [
            self.rclone_bin,
            "mount",
            remote_spec,
            str(mp),
            f"--vfs-cache-mode={vfs_cache_mode}",
            f"--vfs-cache-max-size={cache_max_size}",
            f"--dir-cache-time={dir_cache_time}",
            "--rc",
            "--rc-no-auth",
            f"--rc-addr=127.0.0.1:{rc_port}",
        ]
        if read_only:
            cmd.append("--read-only")
        if extra_args:
            cmd.extend(extra_args)
        proc = subprocess.Popen(
            cmd,
            env=self._base_env(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return proc.pid

    @staticmethod
    def unmount_path(mountpoint: str, lazy: bool = False) -> None:
        wrapper = Path("/run/wrappers/bin/fusermount3")
        fusermount = str(wrapper) if wrapper.is_file() else (shutil.which("fusermount3") or "fusermount3")
        args = [fusermount, "-uz" if lazy else "-u", mountpoint]
        res = subprocess.run(args, capture_output=True, text=True, timeout=10.0, check=False)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or f"fusermount3 exited {res.returncode}")

    @staticmethod
    def control_systemd_mount(unit: str, action: str) -> None:
        res = subprocess.run(
            ["systemctl", "--user", action, unit],
            capture_output=True, text=True, timeout=15.0, check=False,
        )
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or f"systemctl {action} {unit} failed")
