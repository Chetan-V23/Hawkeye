#!/usr/bin/env python3
"""Build the portable application and embed its browser setup files."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def run(*arguments):
    subprocess.run(arguments, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", default="win-x64", choices=["win-x64", "win-arm64", "linux-x64", "linux-arm64"])
    parser.add_argument("--dotnet", default="dotnet")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    desktop = root / "Desktop"
    dist = root / "dist"
    dist.mkdir(exist_ok=True)
    windows = args.runtime.startswith("win-")
    suffix = ".exe" if windows else ""
    platform_name = "Windows" if windows else "Linux"
    name = f"Hawkeye-{platform_name}-{args.runtime.split('-')[1]}"
    common = ["-c", "Release", "-r", args.runtime, "--self-contained", "true",
              "-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true",
              "-p:EnableCompressionInSingleFile=true", "-p:PublishTrimmed=false", "-p:DebugType=None", "-p:DebugSymbols=false"]
    with tempfile.TemporaryDirectory(prefix="hawkeye-publish-") as temporary:
        work = Path(temporary)
        host = work / "browser-host"
        run(args.dotnet, "publish", str(desktop / "Hawkeye.BrowserHost/Hawkeye.BrowserHost.csproj"), *common, "-o", str(host))
        payload = work / "browser-payload.zip"
        with zipfile.ZipFile(payload, "w", zipfile.ZIP_DEFLATED) as archive:
            for file in host.rglob("*"):
                if file.is_file():
                    archive.write(file, "browser-host/" + file.relative_to(host).as_posix())
            extension = desktop / "browser-extension"
            for browser in ("chromium", "firefox"):
                manifest = "manifest.firefox.json" if browser == "firefox" else "manifest.json"
                archive.write(extension / manifest, f"browser-extension/{browser}/manifest.json")
                for file in ("background.js", "status.js", "status.html"):
                    archive.write(extension / file, f"browser-extension/{browser}/{file}")
            archive.write(extension / "README.md", "browser-extension/README.md")
        application = work / "application"
        run(args.dotnet, "publish", str(desktop / "Hawkeye.Desktop/Hawkeye.Desktop.csproj"), *common,
            "-p:BrowserPayload=" + str(payload), "-o", str(application))
        source = application / ("Hawkeye" + suffix)
        target = dist / (name + suffix)
        shutil.copy2(source, target)
        if not windows:
            target.chmod(0o755)
        digest = hashlib.file_digest(target.open("rb"), "sha256").hexdigest()
        (dist / (name + ".sha256")).write_text(f"{digest}  {target.name}\n")
        guide = root / "docs" / ("WINDOWS.md" if windows else "PORT_DESIGN.md")
        with zipfile.ZipFile(dist / (name + ".zip"), "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(target, target.name)
            if guide.exists():
                archive.write(guide, guide.name)
            archive.writestr("SHA256SUMS.txt", f"{digest}  {target.name}\n")
        receipt = {"runtime": args.runtime, "selfContained": True, "singleFile": True,
                   "nativeWindowsBrowserAccess": windows,
                   "browserPayloadEmbedded": True, "sha256": digest, "bytes": target.stat().st_size,
                   "sdk": subprocess.check_output([args.dotnet, "--version"], text=True).strip()}
        (dist / (name + ".build.json")).write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"Built {target} ({target.stat().st_size / 1048576:.1f} MiB)")


if __name__ == "__main__":
    main()
