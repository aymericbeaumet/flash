#!/usr/bin/env python3
import hashlib
import json
import os
import platform
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path


DATA_DIR = Path(os.environ["FLASH_PLUGIN_DATA_DIR"])
BIN_DIR = DATA_DIR / "bin"
USER_AGENT = "flash-plugin-installer/1.0"


def info(message):
    print(f"==> {message}", file=sys.stderr)


def request(url):
    return urllib.request.Request(url, headers={"User-Agent": USER_AGENT})


def download(url, path):
    info(f"Downloading {url}")
    with urllib.request.urlopen(request(url), timeout=60) as response:
        path.write_bytes(response.read())


def latest_release(repo):
    with urllib.request.urlopen(
        request(f"https://api.github.com/repos/{repo}/releases/latest"), timeout=30
    ) as response:
        return json.loads(response.read().decode("utf-8"))


def latest_slack_version():
    with urllib.request.urlopen(
        request("https://docs.slack.dev/tools/metadata.json"), timeout=30
    ) as response:
        data = json.loads(response.read().decode("utf-8"))
    return data["slack-cli"]["releases"][0]["version"]


def machine():
    raw = platform.machine().lower()
    if raw in ("arm64", "arm64e", "aarch64"):
        return "arm64"
    return "x86_64"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path, checksum_path):
    checksum = checksum_path.read_text().split()[0]
    actual = sha256(path)
    if actual.lower() != checksum.lower():
        raise RuntimeError(f"checksum mismatch for {path.name}")


def verify_checksums_file(path, checksums_path):
    wanted = path.name
    for line in checksums_path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("./") == wanted:
            if sha256(path).lower() != parts[0].lower():
                raise RuntimeError(f"checksum mismatch for {wanted}")
            return
    raise RuntimeError(f"checksum missing for {wanted}")


def extract(archive, destination):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(destination)
        return
    with tarfile.open(archive) as tf:
        tf.extractall(destination)


def install_binary(extracted, binary_name, target_name=None):
    target_name = target_name or binary_name
    matches = [
        path
        for path in extracted.rglob(binary_name)
        if path.is_file() and not path.name.endswith((".sha256", ".txt"))
    ]
    if not matches:
        raise RuntimeError(f"binary not found: {binary_name}")
    source = matches[0]
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    target = BIN_DIR / target_name
    shutil.copy2(source, target)
    target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    info(f"Installed {target_name} to {target}")


def asset(release, predicate):
    for item in release["assets"]:
        if predicate(item["name"]):
            return item
    raise RuntimeError("release asset not found")


def install_spotify():
    arch = "aarch64" if machine() == "arm64" else "x86_64"
    release = latest_release("aome510/spotify-player")
    archive_name = f"spotify_player-{arch}-apple-darwin.tar.gz"
    archive_asset = asset(release, lambda name: name == archive_name)
    checksum_asset = asset(release, lambda name: name == f"{archive_name.removesuffix('.tar.gz')}.sha256")
    install_from_assets(archive_asset, checksum_asset, "spotify_player")


def install_github():
    arch = "arm64" if machine() == "arm64" else "amd64"
    release = latest_release("cli/cli")
    archive_asset = asset(release, lambda name: name.endswith(f"macOS_{arch}.zip"))
    checksum_asset = asset(release, lambda name: name.endswith("_checksums.txt"))
    install_from_assets(archive_asset, checksum_asset, "gh", checksum_list=True)


def install_linear():
    arch = "aarch64" if machine() == "arm64" else "x86_64"
    release = latest_release("schpet/linear-cli")
    archive_name = f"linear-{arch}-apple-darwin.tar.xz"
    archive_asset = asset(release, lambda name: name == archive_name)
    checksum_asset = asset(release, lambda name: name == f"{archive_name}.sha256")
    install_from_assets(archive_asset, checksum_asset, "linear")


def install_slack():
    version = latest_slack_version()
    arch = "arm64" if machine() == "arm64" else "amd64"
    url = f"https://downloads.slack-edge.com/slack-cli/slack_cli_{version}_macOS_{arch}.tar.gz"
    install_from_url(url, "slack")


def install_from_assets(archive_asset, checksum_asset, binary_name, checksum_list=False):
    install_from_url(
        archive_asset["browser_download_url"],
        binary_name,
        checksum_url=checksum_asset["browser_download_url"],
        checksum_list=checksum_list,
    )


def install_from_url(url, binary_name, checksum_url=None, checksum_list=False):
    with tempfile.TemporaryDirectory(prefix="flash-plugin-install-") as temp_raw:
        temp = Path(temp_raw)
        archive = temp / url.rsplit("/", 1)[-1]
        download(url, archive)
        if checksum_url:
            checksum = temp / checksum_url.rsplit("/", 1)[-1]
            download(checksum_url, checksum)
            if checksum_list:
                verify_checksums_file(archive, checksum)
            else:
                verify(archive, checksum)
        extracted = temp / "extracted"
        extracted.mkdir()
        extract(archive, extracted)
        install_binary(extracted, binary_name)


def main():
    installers = {
        "spotify": install_spotify,
        "github": install_github,
        "linear": install_linear,
        "slack": install_slack,
    }
    if len(sys.argv) != 2 or sys.argv[1] not in installers:
        raise SystemExit(f"usage: {sys.argv[0]} {'|'.join(sorted(installers))}")
    installers[sys.argv[1]]()


if __name__ == "__main__":
    main()
