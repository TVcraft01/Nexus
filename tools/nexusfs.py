#!/usr/bin/env python3
"""Mount paired Nexus devices as folders in your file manager.

Each paired device becomes a folder under the mount point; opening a folder
lists that device's served files, opening a file streams it, and deleting a
file removes it on the device — all through the running Nexus app's localhost
gateway (which does the mesh encryption and addressing), so this daemon never
touches the crypto.

Requirements: fusepy (pip install --user --break-system-packages fusepy).

Usage:
    nexusfs.py MOUNTPOINT [--state PATH] [--umount]
"""

import argparse
import errno
import json
import os
import socket
import stat
import sys
import tempfile
import time
import uuid

try:
    import fuse
except ImportError:
    sys.stderr.write(
        "fusepy is not installed. Run:\n"
        "  pip3 install --user --break-system-packages fusepy\n")
    sys.exit(1)

DEFAULT_STATE = os.path.expanduser("~/.local/share/nexus/nexus/state.json")
DIR_MODE = 0o755  # owner-write so the file manager offers delete
FILE_MODE = 0o644
CACHE_TTL = 10.0  # seconds before a directory listing / device list is refetched


class GatewayError(Exception):
    pass


class Gateway:
    """Tiny client for the app's localhost gateway. Re-reads the token from
    the store on every request, so it stays in sync across app restarts."""

    def __init__(self, state_path):
        self.state_path = state_path

    def _info(self):
        try:
            with open(self.state_path) as f:
                state = json.load(f)
            settings = state.get("settings", {})
            token = settings.get("gatewayToken")
            port = int(settings.get("gatewayPort", 51823))
        except (OSError, ValueError, json.JSONDecodeError):
            raise GatewayError("cannot read app state — is the app installed?")
        if not token:
            raise GatewayError("the app is not running (no gateway token yet)")
        return token, port

    def request(self, req, timeout=10):
        token, port = self._info()
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
                payload = dict(req, token=token)
                s.sendall((json.dumps(payload) + "\n").encode())
                buf = b""
                while b"\n" not in buf:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                resp = json.loads(buf.split(b"\n", 1)[0])
        except (OSError, json.JSONDecodeError, ValueError):
            raise GatewayError("cannot reach the app gateway — is the app running?")
        if not resp.get("ok"):
            raise GatewayError(resp.get("error", "gateway error"))
        return resp


def sanitize(name):
    return name.replace("/", "-").replace("\\", "-")


class NexusFS(fuse.Operations):
    def __init__(self, gateway):
        self.gw = gateway
        self._devices = {}          # sanitized dir name -> device id
        self._devices_at = 0.0
        self._lists = {}            # fuse dir path -> (at, {name: entry})
        self._handles = {}           # integer handle -> staged local file
        self._next_handle = 1

    # ---- gateway helpers -------------------------------------------------

    def _refresh_devices(self):
        now = time.time()
        if self._devices and now - self._devices_at < CACHE_TTL:
            return
        resp = self.gw.request({"cmd": "devices"})
        by_name = {}
        for d in resp.get("devices", []):
            name = sanitize(d.get("name") or d.get("id", ""))
            if name in by_name:
                name = f"{name}-{d.get('id', '')[:6]}"
            by_name[name] = d.get("id")
        self._devices = by_name
        self._devices_at = now

    def _device_for(self, path):
        """Returns (device_id, peer_path) for a fuse path, or None."""
        parts = [p for p in path.split("/") if p]
        if not parts:
            return None
        self._refresh_devices()
        dev = self._devices.get(parts[0])
        if dev is None:
            return None
        if len(parts) == 1:
            return dev, ""
        # Walk the recorded listing of each directory, keyed by the fuse path
        # (never mix in peer paths), so we can find the entry's peer-side path.
        fuse_dir = "/" + parts[0]
        for i in range(1, len(parts)):
            entries = self._lists.get(fuse_dir, (0, {}))[1]
            entry = entries.get(parts[i])
            if entry is None:
                # Stale cache (listings expire) — refetch this directory once.
                entries = self._list(fuse_dir)
                entry = entries.get(parts[i])
            if entry is None:
                raise GatewayError("not found")
            if i == len(parts) - 1:
                return dev, entry["path"]
            fuse_dir = fuse_dir.rstrip("/") + "/" + parts[i]
        return dev, ""

    def _list(self, fuse_dir):
        """Returns {name: entry} for a fuse directory, caching briefly."""
        cached = self._lists.get(fuse_dir)
        now = time.time()
        if cached and now - cached[0] < CACHE_TTL:
            return cached[1]
        device = self._device_for(fuse_dir)
        if device is None:
            raise GatewayError("no such device")
        dev, peer_path = device
        resp = self.gw.request({"cmd": "list", "device": dev, "path": peer_path})
        entries = {}
        for e in resp.get("entries", []):
            entries[e.get("name") or "?"] = e
        self._lists[fuse_dir] = (now, entries)
        return entries

    def _stat(self, path):
        parts = [p for p in path.split("/") if p]
        if not parts:
            return self._dir_stat(time.time())
        self._refresh_devices()
        if len(parts) == 1:
            if parts[0] in self._devices:
                return self._dir_stat(time.time())
            raise fuse.FuseOSError(errno.ENOENT)
        parent = "/" + "/".join(parts[:-1])
        try:
            entries = self._list(parent)
        except GatewayError:
            raise fuse.FuseOSError(errno.EIO)
        entry = entries.get(parts[-1])
        if entry is None:
            raise fuse.FuseOSError(errno.ENOENT)
        try:
            mtime = time.mktime(
                time.strptime(entry.get("modified", "").split(".")[0], "%Y-%m-%dT%H:%M:%S"))
        except (ValueError, TypeError):
            mtime = time.time()
        if entry.get("dir"):
            return self._dir_stat(mtime)
        return {
            "st_mode": stat.S_IFREG | FILE_MODE,
            "st_size": int(entry.get("size", 0)),
            "st_nlink": 1,
            "st_mtime": mtime,
            "st_ctime": mtime,
            "st_uid": os.getuid(),
            "st_gid": os.getgid(),
        }

    def _dir_stat(self, mtime):
        return {
            "st_mode": stat.S_IFDIR | DIR_MODE,
            "st_size": 0,
            "st_nlink": 2,
            "st_mtime": mtime,
            "st_ctime": mtime,
            "st_uid": os.getuid(),
            "st_gid": os.getgid(),
        }

    # ---- FUSE ops --------------------------------------------------------

    def getattr(self, path, fh=None):
        return self._stat(path)

    def readdir(self, path, fh):
        names = [".", ".."]
        if path == "/":
            self._refresh_devices()
            names += list(self._devices.keys())
        else:
            try:
                names += list(self._list(path).keys())
            except GatewayError:
                names += []
        return names

    def open(self, path, flags):
        if not (flags & (os.O_WRONLY | os.O_RDWR)):
            return 0
        # FUSE writes arrive in arbitrary chunks. Stage them locally, then
        # upload the completed file to the exact peer path on release.
        tmp = tempfile.NamedTemporaryFile(prefix="nexusfs-", delete=False)
        tmp.close()
        handle = self._next_handle
        self._next_handle += 1
        destination = self._destination(path) if flags & os.O_CREAT else self._peer_path(path)
        self._handles[handle] = {"tmp": tmp.name, "destination": destination}
        return handle

    def create(self, path, mode, fi=None):
        return self.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC)

    def write(self, path, data, offset, fh):
        handle = self._handles.get(fh)
        if handle is None:
            raise fuse.FuseOSError(errno.EBADF)
        try:
            with open(handle["tmp"], "r+b") as f:
                f.seek(offset)
                f.write(data)
            return len(data)
        except OSError:
            raise fuse.FuseOSError(errno.EIO)

    def release(self, path, fh):
        handle = self._handles.pop(fh, None)
        if handle is None:
            return 0
        try:
            self.gw.request({
                "cmd": "put",
                "device": handle["destination"][0],
                "local": handle["tmp"],
                "destination": handle["destination"][1],
                "overwrite": True,
            }, timeout=120)
        except GatewayError as e:
            try:
                os.unlink(handle["tmp"])
            except OSError:
                pass
            raise fuse.FuseOSError(self._errno_for(e))
        try:
            os.unlink(handle["tmp"])
        except OSError:
            pass
        self._lists.pop(path.rsplit("/", 1)[0] or "/", None)
        return 0

    def _peer_path(self, path):
        device = self._device_for(path)
        if device is None:
            raise fuse.FuseOSError(errno.ENOENT)
        return device

    def _destination(self, path):
        parent = path.rsplit("/", 1)[0] or "/"
        name = path.rsplit("/", 1)[-1]
        dev, peer_parent = self._peer_path(parent)
        if not name:
            raise fuse.FuseOSError(errno.EINVAL)
        separator = "\\\\" if "\\\\" in peer_parent else "/"
        destination = f"{peer_parent.rstrip('/\\\\')}{separator}{name}" if peer_parent else name
        return dev, destination

    def _errno_for(self, e):
        msg = str(e).lower()
        if "no longer exists" in msg or "not found" in msg:
            return errno.ENOENT
        if "not empty" in msg:
            return errno.ENOTEMPTY
        if "access denied" in msg or "outside" in msg:
            return errno.EACCES
        if "already exists" in msg:
            return errno.EEXIST
        if "invalid" in msg:
            return errno.EINVAL
        return errno.EIO

    def _delete(self, path):
        device = self._device_for(path)
        if device is None:
            raise fuse.FuseOSError(errno.ENOENT)
        dev, peer_path = device
        try:
            self.gw.request({"cmd": "del", "device": dev, "path": peer_path})
        except GatewayError as e:
            raise fuse.FuseOSError(self._errno_for(e))
        # The parent's cached listing is now stale — drop it so the deleted
        # entry disappears on the next readdir.
        parent = path.rsplit("/", 1)[0] or "/"
        self._lists.pop(parent, None)

    def unlink(self, path):
        self._delete(path)

    def rmdir(self, path):
        self._delete(path)

    def mkdir(self, path, mode):
        try:
            dev, destination = self._destination(path)
            self.gw.request({
                "cmd": "op",
                "device": dev,
                "operation": "mkdir",
                "destination": destination,
            })
        except GatewayError as e:
            raise fuse.FuseOSError(self._errno_for(e))
        self._lists.pop(path.rsplit("/", 1)[0] or "/", None)
        return 0

    def rename(self, old, new):
        try:
            source_dev, source_path = self._peer_path(old)
            target_dev, destination = self._destination(new)
            if source_dev == target_dev:
                self.gw.request({
                    "cmd": "op",
                    "device": source_dev,
                    "operation": "move",
                    "source": source_path,
                    "destination": destination,
                })
            else:
                self.gw.request({
                    "cmd": "transfer",
                    "sourceDevice": source_dev,
                    "source": source_path,
                    "destinationDevice": target_dev,
                    "destination": destination,
                    "operation": "move",
                }, timeout=120)
        except GatewayError as e:
            raise fuse.FuseOSError(self._errno_for(e))
        self._lists.pop(old.rsplit("/", 1)[0] or "/", None)
        self._lists.pop(new.rsplit("/", 1)[0] or "/", None)
        return 0

    def read(self, path, size, offset, fh):
        device = self._device_for(path)
        if device is None:
            raise fuse.FuseOSError(errno.ENOENT)
        dev, peer_path = device
        try:
            resp = self.gw.request({
                "cmd": "get",
                "device": dev,
                "path": peer_path,
                "offset": offset,
                "length": size,
            }, timeout=30)
        except GatewayError:
            raise fuse.FuseOSError(errno.EIO)
        import base64
        return base64.b64decode(resp.get("data", ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mountpoint")
    parser.add_argument("--state", default=DEFAULT_STATE)
    parser.add_argument("--umount", action="store_true", help="unmount instead")
    args = parser.parse_args()

    if args.umount:
        for cmd in (("fusermount3", "-u"), ("fusermount", "-u")):
            import shutil
            if shutil.which(cmd[0]):
                os.execvp(cmd[0], [cmd[0], cmd[1], args.mountpoint])
        sys.exit("neither fusermount nor fusermount3 found")

    gateway = Gateway(args.state)
    try:
        gateway.request({"cmd": "devices"})
    except GatewayError as e:
        sys.exit(f"nexusfs: {e}")

    os.makedirs(args.mountpoint, exist_ok=True)
    fuse.FUSE(NexusFS(gateway), args.mountpoint,
              foreground=True, nothreads=True)


if __name__ == "__main__":
    main()
