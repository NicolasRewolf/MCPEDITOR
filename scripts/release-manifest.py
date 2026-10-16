#!/usr/bin/env python3
"""Identify the current delivery and verify its archives and extracted bundle.

Local integrity record, not an independent build attestation or a hardware test.
Verification never launches the application.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

APP_NAME = "MPC Kit Studio.app"
ARCHIVES = ("MPC-Kit-Studio-Apple-Silicon.zip", "MPC-Kit-Studio-Apple-Silicon.dmg")
RESOURCE = "Contents/Resources/KitStudio_MPCCore.bundle/Default.pgm"
MANIFEST = "release-manifest.json"


def command(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return {"bytes": path.stat().st_size, "sha256": h.hexdigest()}


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected symbolic link in app: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def create(dist):
    app = dist / APP_NAME
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    repo = pathlib.Path(command("git", "rev-parse", "--show-toplevel", cwd=dist.parent))
    scope = ("mac/KitStudio", ".github/workflows/kit-studio.yml",
             ".github/workflows/kit-studio-verify.yml")
    files = command("git", "ls-files", "--cached", "--others", "--exclude-standard", "--", *scope,
                    cwd=repo).splitlines()
    report = {
        "schema": 1,
        "createdUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sourceCommit": command("git", "rev-parse", "HEAD", cwd=repo),
        "sourceTree": command("git", "rev-parse", "HEAD^{tree}", cwd=repo),
        "sourceDirty": bool(command("git", "status", "--porcelain", "--", *scope, cwd=repo)),
        "sourceFiles": {name: digest(repo / name) for name in sorted(set(files))
                        if (repo / name).is_file()},
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimumMacOS": info["LSMinimumSystemVersion"],
        "architecture": command("lipo", "-archs", str(app / "Contents/MacOS/KitStudio")),
        "signature": "ad hoc; no Developer ID or notarization",
        "tools": {"swift": command("swift", "--version"),
                  "xcode": command("xcodebuild", "-version"),
                  "sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-version"),
                  "macOS": command("sw_vers")},
        "archives": {name: digest(dist / name) for name in ARCHIVES},
        "appFiles": inventory(app),
        "limits": "Local integrity only; no MPC test, power-loss guarantee or binary reproducibility claim."
    }
    (dist / MANIFEST).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"MANIFEST_CREATED: {report['version']} ({report['build']}), {report['sourceCommit']}, dirty={report['sourceDirty']}")


def verify_bundle(app, report):
    resource = app / RESOURCE
    if not resource.is_file() or resource.stat().st_size != 4608:
        raise ValueError("Missing or invalid Default.pgm resource")
    if inventory(app) != report["appFiles"]:
        raise ValueError("Extracted app files differ from the release manifest")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key, field in (("CFBundleShortVersionString", "version"), ("CFBundleVersion", "build"),
                       ("LSMinimumSystemVersion", "minimumMacOS")):
        if info[key] != report[field]:
            raise ValueError(f"Bundle {key} differs from the manifest")
    binary = app / "Contents/MacOS/KitStudio"
    if command("lipo", "-archs", str(binary)) != "arm64":
        raise ValueError("Expected an arm64 executable")
    subprocess.run(["plutil", "-lint", str(app / "Contents/Info.plist")], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def verify(dist, expected_commit=None, require_clean=False, extracted_app=None):
    report = json.loads((dist / MANIFEST).read_text())
    if report["schema"] != 1:
        raise ValueError("Unsupported manifest schema")
    if expected_commit and report["sourceCommit"] != expected_commit:
        raise ValueError("Archive source commit differs from the current job")
    if require_clean and report["sourceDirty"]:
        raise ValueError("Release was built from modified sources")
    for name in ARCHIVES:
        if digest(dist / name) != report["archives"][name]:
            raise ValueError(f"Archive differs from the manifest: {name}")
    subprocess.run(["unzip", "-tq", str(dist / ARCHIVES[0])], check=True)
    subprocess.run(["hdiutil", "verify", str(dist / ARCHIVES[1])], check=True,
                   stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix="kit-studio-verify-") as temporary:
        temporary = pathlib.Path(temporary)
        unpacked = temporary / "zip"
        subprocess.run(["ditto", "-x", "-k", str(dist / ARCHIVES[0]), str(unpacked)], check=True)
        verify_bundle(unpacked / APP_NAME, report)
        # Verify the DMG payload too. Mount an exact private copy so an already
        # mounted user/test image is never detached or reused implicitly.
        image_copy = temporary / "payload.dmg"
        shutil.copyfile(dist / ARCHIVES[1], image_copy)
        if digest(image_copy) != report["archives"][ARCHIVES[1]]:
            raise ValueError("Private image copy differs from the delivery")
        mount = temporary / "mounted"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                        "-mountpoint", str(mount), str(image_copy)], check=True,
                       stdout=subprocess.DEVNULL)
        try:
            verify_bundle(mount / APP_NAME, report)
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True,
                           stdout=subprocess.DEVNULL)
    if extracted_app is not None:
        verify_bundle(extracted_app, report)
    print(f"ARCHIVE_INTEGRITY_OK: {report['version']} ({report['build']}), {report['sourceCommit']}")
    print("Launch/window and MPC acceptance are separate checks.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "verify"))
    parser.add_argument("dist", type=pathlib.Path)
    parser.add_argument("--expect-commit")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--app", type=pathlib.Path, help="Also verify an already extracted app")
    args = parser.parse_args()
    try:
        if args.action == "create":
            create(args.dist.resolve())
        else:
            verify(args.dist.resolve(), args.expect_commit, args.require_clean, args.app)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"DELIVERY_CHECK_FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
