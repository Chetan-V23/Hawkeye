#!/usr/bin/env python3
"""Collect the foreground Safari/Chrome page every 10 seconds, up to 100 files.

macOS setup (run explicitly; this script never installs or changes permissions):
    python3 -m venv .venv-browser-collector
    .venv-browser-collector/bin/python -m pip install pyobjc-framework-ApplicationServices==12.2.2
    .venv-browser-collector/bin/python collect_browser_text.py
Allow the launching Terminal/IDE/Python in System Settings > Privacy & Security >
Accessibility, then run again. There are no command-line settings. Samples are
UTF-8 browser_text_samples/1.txt through 100.txt beside this script. Reruns fill
missing slots, preserve existing files, and never write a 101st sample. Ctrl-C
stops collection. Extend BROWSERS to add browser bundles with a supported AX tree.
Exposed text can contain private page content; secure AX subtrees are excluded.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import json
import math
import multiprocessing as mp
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field

OUTPUT_DIRECTORY = Path(__file__).resolve().parent / "browser_text_samples"
INTERVAL_SECONDS = 10.0
MAX_SAMPLES = 100
CAPTURE_SECONDS = 3.0
WORKER_SECONDS = 6.0
MAX_NODES = 12_000
MAX_DEPTH = 80
MAX_TEXT_BYTES = 1_000_000
CHILD_BATCH = 64
DIRECT_ROLES = {"AXStaticText", "AXTextField", "AXTextArea", "AXComboBox"}
SECURE_ROLES = {"AXSecureTextField", "AXProtectedTextField"}


@dataclass(frozen=True)
class BrowserSpec:
    bundle_id: str
    family: str
    document_url_fallback: bool = False


BROWSERS = {spec.bundle_id: spec for spec in (
    BrowserSpec("com.apple.Safari", "safari", True),
    BrowserSpec("com.google.Chrome", "chromium"),
)}


class CaptureError(Exception):
    pass


@dataclass
class TextNode:
    role: str
    subrole: str | None = None
    text: str = ""
    children: list[TextNode] = field(default_factory=list)


def secure(node):
    return node.role in SECURE_ROLES or node.subrole in SECURE_ROLES


def text_in(node):
    if secure(node):
        return ""
    if node.role in DIRECT_ROLES and node.text:
        return " ".join(node.text.split())
    if node.children:
        return "\n".join(value for child in node.children if (value := text_in(child)))
    return " ".join(node.text.split())


def extract(root, truncated=False):
    full_text = text_in(root)
    mains, articles = [], []

    def visit(node):
        if secure(node):
            return
        if "AXLandmarkMain" in (node.role, node.subrole):
            mains.append(node)
        if "AXDocumentArticle" in (node.role, node.subrole):
            articles.append(node)
        for child in node.children:
            visit(child)

    if truncated:
        return full_text, None
    visit(root)
    candidates = mains or articles
    if len(candidates) != 1 or not (body := text_in(candidates[0])):
        return full_text, None
    return full_text, {"source": "mainLandmark" if mains else "article", "text": body}


def utf8_prefix(text, limit):
    return text.encode("utf-8")[:max(0, limit)].decode("utf-8", errors="ignore")


class NativeAX:
    """Native imports and all native IPC live exclusively in the spawned worker."""
    def __init__(self, deadline):
        try:
            import ApplicationServices as ax
            import CoreFoundation as cf
            from AppKit import NSWorkspace
        except ImportError as error:
            raise CaptureError(f"dependencies: Install with {sys.executable} -m pip install "
                               "pyobjc-framework-ApplicationServices==12.2.2") from error
        self.ax, self.cf, self.workspace = ax, cf, NSWorkspace.sharedWorkspace()
        self.deadline = deadline
        if not ax.AXIsProcessTrusted():
            raise CaptureError("permission: Allow the launching Terminal/IDE/Python in "
                               "System Settings > Privacy & Security > Accessibility, then rerun.")

    def check(self):
        if time.monotonic() >= self.deadline:
            raise CaptureError("timed out")

    def prepare(self, element):
        self.check()
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise CaptureError("timed out")
        self.result(self.ax.AXUIElementSetMessagingTimeout(element, min(0.15, remaining)))

    def result(self, code, optional=False):
        if code == 0:
            return True
        if optional and code in (self.ax.kAXErrorAttributeUnsupported, self.ax.kAXErrorNoValue):
            return False
        self.check()
        raise CaptureError(f"AX request failed ({code})")

    def value(self, element, name):
        self.prepare(element)
        code, value = self.ax.AXUIElementCopyAttributeValue(element, name, None)
        return value if self.result(code, optional=True) else None

    def is_type(self, value, type_id):
        return value is not None and self.cf.CFGetTypeID(value) == type_id

    def string(self, element, name):
        value = self.value(element, name)
        return str(value) if self.is_type(value, self.cf.CFStringGetTypeID()) else None

    def boolean(self, element, name):
        value = self.value(element, name)
        return bool(value) if self.is_type(value, self.cf.CFBooleanGetTypeID()) else None

    def element(self, element, name):
        value = self.value(element, name)
        return value if self.is_type(value, self.ax.AXUIElementGetTypeID()) else None

    def url(self, element, name):
        value = self.value(element, name)
        if self.is_type(value, self.cf.CFURLGetTypeID()):
            return str(self.cf.CFURLGetString(value))
        return str(value) if self.is_type(value, self.cf.CFStringGetTypeID()) else None

    def child_count(self, element):
        self.prepare(element)
        code, count = self.ax.AXUIElementGetAttributeValueCount(element, "AXChildren", None)
        if not self.result(code, optional=True):
            return 0
        if not isinstance(count, int) or count < 0:
            raise CaptureError("invalid AX child count")
        return count

    def child_batch(self, element, offset, length):
        self.prepare(element)
        code, children = self.ax.AXUIElementCopyAttributeValues(
            element, "AXChildren", offset, length, None)
        self.result(code)
        if children is None or len(children) != length or any(
                not self.is_type(child, self.ax.AXUIElementGetTypeID()) for child in children):
            raise CaptureError("invalid AX children")
        return children

    def foreground(self):
        self.check()
        app = self.workspace.frontmostApplication()
        return (str(app.bundleIdentifier()), int(app.processIdentifier())) if app else None

    def application(self, pid, spec):
        self.check()
        app = self.ax.AXUIElementCreateApplication(pid)
        if spec.family == "chromium" and self.boolean(app, "AXEnhancedUserInterface") is not True:
            self.prepare(app)
            code = self.ax.AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface", True)
            if code not in (0, self.ax.kAXErrorAttributeUnsupported, self.ax.kAXErrorNotImplemented):
                self.result(code)
        return app

    def equal(self, first, second):
        return bool(self.cf.CFEqual(first, second))


class AXReader:
    def __init__(self, api):
        self.api = api
        self.visited = self.text_bytes = 0
        self.truncated = False

    def children(self, element, maximum, require_all=False):
        count = self.api.child_count(element)
        if count > maximum:
            if require_all:
                raise CaptureError("incomplete page discovery")
            self.truncated = True
        limit = min(count, max(0, maximum))
        for offset in range(0, limit, CHILD_BATCH):
            yield from self.api.child_batch(element, offset, min(CHILD_BATCH, limit - offset))

    def selected_page(self, window):
        roots = []
        count = 0

        def visit(element, depth):
            nonlocal count
            self.api.check()
            count += 1
            if count > 1500 or depth > 40:
                raise CaptureError("incomplete page discovery")
            if self.api.boolean(element, "AXHidden") is True or self.api.boolean(element, "AXVisible") is False:
                return
            role = self.api.string(element, "AXRole")
            if role is None:
                raise CaptureError("missing AX role")
            if role == "AXWebArea":
                roots.append(element)
                if len(roots) > 1:
                    raise CaptureError("ambiguous page")
                return
            for child in self.children(element, 1500 - count, True):
                visit(child, depth + 1)

        visit(window, 0)
        if len(roots) != 1:
            raise CaptureError("no page")
        return roots[0]

    def bounded_node(self, node, value):
        separator = int(self.text_bytes > 0)
        node.text = utf8_prefix(value, MAX_TEXT_BYTES - self.text_bytes - separator)
        if len(node.text.encode("utf-8")) < len(value.encode("utf-8")):
            self.truncated = True
        if node.text:
            self.text_bytes += len(node.text.encode("utf-8")) + separator
        return node

    def read(self, element, depth=0):
        self.api.check()
        if self.visited >= MAX_NODES or depth > MAX_DEPTH:
            self.truncated = True
            return TextNode("AXGroup")
        self.visited += 1
        role = self.api.string(element, "AXRole")
        if role is None:
            raise CaptureError("missing AX role")
        node = TextNode(role, self.api.string(element, "AXSubrole"))
        if secure(node) or self.api.boolean(element, "AXProtectedContent") is True:
            return TextNode("AXSecureTextField")
        if self.api.boolean(element, "AXHidden") is True:
            return node
        if role in DIRECT_ROLES:
            value = self.api.string(element, "AXValue")
            if value is not None:
                return self.bounded_node(node, value)
        count = self.api.child_count(element)
        maximum = MAX_NODES - self.visited if depth < MAX_DEPTH else 0
        if count > maximum:
            self.truncated = True
        for offset in range(0, min(count, maximum), CHILD_BATCH):
            if self.visited >= MAX_NODES or self.text_bytes >= MAX_TEXT_BYTES:
                self.truncated = True
                break
            batch = self.api.child_batch(element, offset, min(CHILD_BATCH, min(count, maximum) - offset))
            for child in batch:
                if self.visited >= MAX_NODES or self.text_bytes >= MAX_TEXT_BYTES:
                    self.truncated = True
                    break
                node.children.append(self.read(child, depth + 1))
        if count == 0:
            value = next((value for key in ("AXValue", "AXTitle", "AXDescription")
                          if (value := self.api.string(element, key)) is not None), "")
            return self.bounded_node(node, value)
        return node

    def metadata(self, page, window, spec):
        title = self.api.string(page, "AXTitle")
        if title is None:
            title = self.api.string(window, "AXTitle")
        url = self.api.url(page, "AXURL")
        if url is None and spec.document_url_fallback:
            url = self.api.url(window, "AXDocument")
        return title, url

    def capture(self):
        identity = self.api.foreground()
        if identity is None or identity[0] not in BROWSERS:
            return None
        bundle, pid = identity
        spec = BROWSERS[bundle]
        app = self.api.application(pid, spec)
        window = self.api.element(app, "AXFocusedWindow")
        if window is None or self.api.boolean(window, "AXMinimized") is True:
            raise CaptureError("no page")
        page = self.selected_page(window)
        metadata = self.metadata(page, window, spec)
        tree = self.read(page)
        current_window = self.api.element(app, "AXFocusedWindow")
        if current_window is None or not self.api.equal(window, current_window):
            raise CaptureError("page changed")
        current_page = self.selected_page(current_window)
        if (not self.api.equal(page, current_page)
                or self.metadata(current_page, current_window, spec) != metadata
                or self.api.foreground() != identity):
            raise CaptureError("page changed")
        self.api.check()
        full_text, main = extract(tree, self.truncated)
        if not full_text:
            return None
        return {"captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "browser_bundle_id": bundle, "browser_family": spec.family, "process_id": pid,
                "page_title": metadata[0], "page_url": metadata[1], "full_text": full_text,
                "main_content": main, "is_truncated": self.truncated}


def write_worker_result(path, result):
    temporary = path + ".tmp"
    with open(temporary, "x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False)
    os.replace(temporary, path)


def capture_worker(path):
    try:
        snapshot = AXReader(NativeAX(time.monotonic() + CAPTURE_SECONDS)).capture()
        result = {"snapshot": snapshot}
    except Exception as error:
        result = {"error": str(error), "fatal": str(error).startswith(("permission:", "dependencies:"))}
    write_worker_result(path, result)


def validate_snapshot(value):
    if not isinstance(value, dict):
        raise ValueError("invalid capture result")
    for key in ("captured_at", "browser_bundle_id", "browser_family", "full_text"):
        if not isinstance(value.get(key), str):
            raise ValueError("invalid capture text")
    if value["browser_bundle_id"] not in BROWSERS or value["browser_family"] != BROWSERS[value["browser_bundle_id"]].family:
        raise ValueError("invalid browser")
    if type(value.get("process_id")) is not int or value["process_id"] <= 0:
        raise ValueError("invalid process")
    if type(value.get("is_truncated")) is not bool:
        raise ValueError("invalid truncation flag")
    for key in ("page_title", "page_url"):
        if value.get(key) is not None and not isinstance(value[key], str):
            raise ValueError("invalid metadata")
    if not value["full_text"].strip() or len(value["full_text"].encode("utf-8")) > MAX_TEXT_BYTES:
        raise ValueError("empty or oversized text")
    main = value.get("main_content")
    if main is not None:
        if (value["is_truncated"] or not isinstance(main, dict)
                or main.get("source") not in ("mainLandmark", "article")
                or not isinstance(main.get("text"), str) or not main["text"].strip()
                or len(main["text"].encode("utf-8")) > MAX_TEXT_BYTES):
            raise ValueError("invalid main content")
    return value


def stop_worker(process):
    if process.is_alive():
        process.terminate()
        process.join(0.5)
    if process.is_alive():
        process.kill()
    process.join()


def run_attempt(worker=capture_worker, timeout=WORKER_SECONDS):
    with tempfile.TemporaryDirectory(prefix="browser-capture-") as directory:
        path = str(Path(directory) / "result.json")
        process = mp.get_context("spawn").Process(target=worker, args=(path,))
        process.start()
        try:
            process.join(timeout)
            if process.is_alive():
                return {"error": "capture worker timed out", "fatal": False}
            if process.exitcode != 0:
                return {"error": "capture worker failed", "fatal": False}
            if os.stat(path).st_size > 16 * MAX_TEXT_BYTES:
                raise ValueError("oversized worker result")
            result = json.loads(Path(path).read_text(encoding="utf-8"))
            if not isinstance(result, dict):
                raise ValueError("invalid worker result")
            if "error" in result:
                if not isinstance(result["error"], str) or type(result.get("fatal")) is not bool:
                    raise ValueError("invalid worker error")
                return result
            snapshot = result.get("snapshot")
            return {"snapshot": validate_snapshot(snapshot) if snapshot is not None else None}
        except (OSError, ValueError, KeyError) as error:
            return {"error": f"invalid capture result: {error}", "fatal": False}
        finally:
            stop_worker(process)
            process.close()


def render_sample(snapshot):
    main = snapshot["main_content"]
    metadata = {key: snapshot[key] for key in (
        "captured_at", "browser_bundle_id", "browser_family", "process_id", "page_title",
        "page_url", "is_truncated")}
    metadata["main_content_status"] = "available" if main else (
        "unavailable: partial capture" if snapshot["is_truncated"] else "unavailable: no unique nonempty main or article")
    metadata["main_content_source"] = main["source"] if main else None
    return (json.dumps(metadata, ensure_ascii=False, indent=2) + "\n\n=== ALL EXPOSED PAGE TEXT ===\n"
            + snapshot["full_text"] + "\n\n=== MAIN CONTENT ===\n" + (main["text"] if main else "") + "\n")


class SampleStore:
    def __init__(self, directory):
        directory.mkdir(mode=0o700, parents=False, exist_ok=True)
        self.fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.lock_fd = None
        try:
            os.fchmod(self.fd, 0o700)
            self.lock_fd = os.open(".collector.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
            if not stat.S_ISREG(os.fstat(self.lock_fd).st_mode):
                raise OSError("collector lock must be a regular file")
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def missing(self):
        result = []
        for number in range(1, MAX_SAMPLES + 1):
            try:
                info = os.stat(f"{number}.txt", dir_fd=self.fd, follow_symlinks=False)
            except FileNotFoundError:
                result.append(number)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
                raise ValueError(f"Sample slot {number}.txt is occupied by an invalid entry "
                                 "(expected a nonempty regular file); move it aside to resume.")
        return result

    def save(self, number, snapshot):
        if not 1 <= number <= MAX_SAMPLES:
            raise ValueError("sample number outside fixed range")
        name = f".sample-{uuid.uuid4().hex}.tmp"
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(render_sample(validate_snapshot(snapshot)))
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(name, f"{number}.txt", src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False)
            except FileExistsError:
                return False
            os.fsync(self.fd)
            return True
        finally:
            os.unlink(name, dir_fd=self.fd)


def next_tick(previous, now):
    return previous + max(1, math.floor((now - previous) / INTERVAL_SECONDS) + 1) * INTERVAL_SECONDS


def collect(store, attempt=run_attempt, monotonic=time.monotonic, sleep=time.sleep, report=print):
    scheduled = monotonic()
    while slots := store.missing():
        sleep(max(0, scheduled - monotonic()))
        started = monotonic()
        result = attempt()
        if "error" in result:
            report(result["error"])
            if result.get("fatal"):
                return 1
        elif result.get("snapshot") is not None:
            if store.save(slots[0], result["snapshot"]):
                report(f"Saved {slots[0]}.txt")
        if not store.missing():
            break
        scheduled = next_tick(started, monotonic())
    return 0


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if arguments in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if arguments:
        print("Usage: python collect_browser_text.py (fixed settings; no arguments)", file=sys.stderr)
        return 2
    store = None
    try:
        store = SampleStore(OUTPUT_DIRECTORY)
        if not store.missing():
            print("All 100 sample slots already exist.")
            return 0
        print(f"Saving browser text to {OUTPUT_DIRECTORY} every {INTERVAL_SECONDS:g} seconds "
              f"until slots 1–{MAX_SAMPLES} are filled. Bring Safari or Chrome to the foreground; "
              "press Ctrl-C to stop.")
        return collect(store)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 130
    except (OSError, ValueError) as error:
        print(f"Collector could not continue: {error}", file=sys.stderr)
        return 1
    finally:
        if store is not None:
            store.close()


if __name__ == "__main__":
    mp.freeze_support()
    raise SystemExit(main())
