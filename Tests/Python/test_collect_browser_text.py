import contextlib
import io
import json
import multiprocessing as mp
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import collect_browser_text as collector


def snapshot(text="Page text", main=None, truncated=False):
    return {"captured_at": "2026-11-02T00:00:00+00:00", "browser_bundle_id": "com.apple.Safari",
            "browser_family": "safari", "process_id": 1, "page_title": "Title", "page_url": "https://example.org",
            "full_text": text, "main_content": main, "is_truncated": truncated}


def large_worker(path):
    collector.write_worker_result(path, {"snapshot": snapshot("文" * 300_000)})


def hanging_worker(path):
    Path(path + ".pid").write_text(str(os.getpid()))
    time.sleep(60)


class FakeAX:
    def __init__(self, root):
        self.page = root
        self.window = {"AXRole": "AXWindow", "AXTitle": "Window title", "children": [root]}
        self.app = {"AXFocusedWindow": self.window}
        self.identity = ("com.apple.Safari", 1)
        self.foregrounds = 0
        self.change_foreground = False
        self.change_title = False

    def check(self):
        pass

    def string(self, element, key):
        value = element.get(key)
        return value if isinstance(value, str) else None

    def boolean(self, element, key):
        return element.get(key)

    def element(self, element, key):
        return element.get(key)

    def url(self, element, key):
        return element.get(key)

    def child_count(self, element):
        return len(element.get("children", []))

    def child_batch(self, element, offset, length):
        return element["children"][offset:offset + length]

    def foreground(self):
        self.foregrounds += 1
        if self.change_foreground and self.foregrounds > 1:
            return ("com.google.Chrome", 2)
        return self.identity

    def application(self, pid, spec):
        return self.app

    def equal(self, first, second):
        if self.change_title:
            self.page["AXTitle"] = "New title"
        return first is second


def leaf(text, role="AXStaticText", **attributes):
    return {"AXRole": role, "AXValue": text, **attributes}


class ExtractionTests(unittest.TestCase):
    def test_main_wins_over_article_and_aggregate_is_not_duplicated(self):
        node = collector.TextNode("AXWebArea", text="aggregate", children=[
            collector.TextNode("AXGroup", "AXLandmarkMain", children=[collector.TextNode("AXStaticText", text=" Main  body ")]),
            collector.TextNode("AXDocumentArticle", text="Article")])
        full, main = collector.extract(node)
        self.assertEqual(full, "Main body\nArticle")
        self.assertEqual(main, {"source": "mainLandmark", "text": "Main body"})

    def test_article_and_ambiguous_landmarks(self):
        article = collector.TextNode("AXDocumentArticle", text="Article")
        self.assertEqual(collector.extract(article)[1]["source"], "article")
        root = collector.TextNode("AXWebArea", children=[article, article])
        self.assertIsNone(collector.extract(root)[1])
        empty_main = collector.TextNode("AXLandmarkMain")
        root.children.append(empty_main)
        self.assertIsNone(collector.extract(root)[1])

    def test_partial_capture_never_produces_main(self):
        node = collector.TextNode("AXLandmarkMain", text="Partial")
        self.assertEqual(collector.extract(node, True), ("Partial", None))

    def test_secure_subtree_and_meaningful_repetition(self):
        node = collector.TextNode("AXWebArea", children=[
            collector.TextNode("AXSecureTextField", text="secret", children=[collector.TextNode("AXLandmarkMain", text="secret")]),
            collector.TextNode("AXStaticText", text="Repeat"), collector.TextNode("AXStaticText", text="Repeat")])
        self.assertEqual(collector.extract(node), ("Repeat\nRepeat", None))

    def test_direct_control_value_preserved_with_children(self):
        node = collector.TextNode("AXTextArea", text="Complete typed text", children=[collector.TextNode("AXStaticText", text="fragment")])
        self.assertEqual(collector.text_in(node), "Complete typed text")

    def test_utf8_prefix_preserves_codepoints(self):
        for limit in range(10):
            value = collector.utf8_prefix("a文😀end", limit)
            self.assertLessEqual(len(value.encode()), limit)
            self.assertTrue("a文😀end".startswith(value))


class ReaderTests(unittest.TestCase):
    def test_native_adapter_flow_and_direct_controls(self):
        page = {"AXRole": "AXWebArea", "AXTitle": "Page", "children": [
            {"AXRole": "AXLandmarkMain", "children": [leaf("typed full value", "AXTextArea", children=[leaf("fragment")])]},
            leaf("secret", "AXGroup", AXProtectedContent=True), leaf("Footer")]}
        api = FakeAX(page)
        api.window["AXDocument"] = "https://example.org/fallback"
        result = collector.AXReader(api).capture()
        self.assertEqual(result["full_text"], "typed full value\nFooter")
        self.assertEqual(result["main_content"]["text"], "typed full value")
        self.assertEqual(result["page_url"], "https://example.org/fallback")

    def test_ambiguous_root_and_incomplete_discovery_rejected(self):
        api = FakeAX({"AXRole": "AXWebArea", "children": [leaf("text")]})
        api.window["children"].append({"AXRole": "AXWebArea"})
        with self.assertRaisesRegex(collector.CaptureError, "ambiguous"):
            collector.AXReader(api).capture()
        api.window["children"] = [{"AXRole": "AXGroup"}] * 1501
        with self.assertRaisesRegex(collector.CaptureError, "incomplete"):
            collector.AXReader(api).capture()

    def test_root_discovery_stops_at_web_area(self):
        page = {"AXRole": "AXWebArea", "children": [{"AXRole": "AXWebArea", "children": [leaf("nested")]}]}
        self.assertEqual(collector.AXReader(FakeAX(page)).capture()["full_text"], "nested")

    def test_page_metadata_or_foreground_change_rejected(self):
        for key in ("change_title", "change_foreground"):
            api = FakeAX({"AXRole": "AXWebArea", "AXTitle": "Old title", "children": [leaf("text")]})
            setattr(api, key, True)
            with self.subTest(key=key), self.assertRaisesRegex(collector.CaptureError, "page changed"):
                collector.AXReader(api).capture()

    def test_utf8_bound_keeps_partial_text_and_clears_main(self):
        api = FakeAX({"AXRole": "AXWebArea", "children": [{"AXRole": "AXLandmarkMain", "children": [leaf("文" * 20)]}]})
        with mock.patch.object(collector, "MAX_TEXT_BYTES", 10):
            result = collector.AXReader(api).capture()
        self.assertEqual(result["full_text"], "文文文")
        self.assertTrue(result["is_truncated"])
        self.assertIsNone(result["main_content"])

    def test_bounds_do_not_read_unbounded_children(self):
        api = FakeAX({"AXRole": "AXWebArea", "children": [leaf("one"), leaf("two"), leaf("three")]})
        with mock.patch.object(collector, "MAX_NODES", 2):
            result = collector.AXReader(api).capture()
        self.assertEqual(result["full_text"], "one")
        self.assertTrue(result["is_truncated"])


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name) / "samples"
        self.store = collector.SampleStore(self.directory)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.close)

    def test_exactly_100_successful_writes_failed_attempt_uses_no_slot(self):
        attempts = 0
        clock = [0.0]

        def attempt():
            nonlocal attempts
            attempts += 1
            return {"error": "failed", "fatal": False} if attempts == 1 else {"snapshot": snapshot(str(attempts))}

        def sleep(seconds):
            clock[0] += seconds

        self.assertEqual(collector.collect(self.store, attempt, lambda: clock[0], sleep, lambda _: None), 0)
        self.assertEqual(attempts, 101)
        self.assertEqual(self.store.missing(), [])
        self.assertFalse((self.directory / "101.txt").exists())
        self.assertIn("\n2\n", (self.directory / "1.txt").read_text())
        self.assertEqual(stat_mode(self.directory), 0o700)
        self.assertEqual(stat_mode(self.directory / "1.txt"), 0o600)

    def test_resume_no_overwrite_foreign_files_and_empty_main(self):
        (self.directory / "1.txt").write_text("foreign")
        (self.directory / "notes.txt").write_text("keep")
        self.assertEqual(self.store.missing()[0], 2)
        self.assertFalse(self.store.save(1, snapshot()))
        self.assertTrue(self.store.save(2, snapshot(truncated=True)))
        self.assertEqual((self.directory / "1.txt").read_text(), "foreign")
        self.assertEqual((self.directory / "notes.txt").read_text(), "keep")
        body = (self.directory / "2.txt").read_text()
        self.assertIn('"is_truncated": true', body)
        self.assertIn("unavailable: partial capture", body)
        self.assertTrue(body.endswith("=== MAIN CONTENT ===\n\n"))
        self.assertFalse(list(self.directory.glob(".sample-*.tmp")))
        with self.assertRaises(ValueError):
            self.store.save(101, snapshot())

    def test_single_collector_lock(self):
        with self.assertRaises(BlockingIOError):
            collector.SampleStore(self.directory)

    def test_symlink_output_rejected(self):
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.directory)
        with self.assertRaises(OSError):
            collector.SampleStore(link)

    def test_all_slots_skip_capture_and_native_dependencies(self):
        for number in range(1, 101):
            (self.directory / f"{number}.txt").write_text("existing sample")
        self.store.close()
        with mock.patch.object(collector, "OUTPUT_DIRECTORY", self.directory), mock.patch.object(collector, "collect", side_effect=AssertionError("must not capture")):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(collector.main([]), 0)

    def test_invalid_occupied_slots_are_preserved_and_reported(self):
        slot = self.directory / "1.txt"
        for kind in ("empty", "directory", "symlink"):
            with self.subTest(kind=kind):
                if kind == "empty":
                    slot.touch()
                elif kind == "directory":
                    slot.mkdir()
                else:
                    slot.symlink_to(self.directory / "notes.txt")
                with self.assertRaisesRegex(ValueError, "1.txt is occupied"):
                    self.store.missing()
                self.assertTrue(slot.exists() or slot.is_symlink())
                if kind == "directory":
                    slot.rmdir()
                else:
                    slot.unlink()

    def test_help_and_unexpected_arguments_do_not_start_collection(self):
        with mock.patch.object(collector, "SampleStore", side_effect=AssertionError("must not open output")):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(collector.main(["--help"]), 0)
            self.assertIn("every 10 seconds", output.getvalue())
            with contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(collector.main(["--settings"]), 2)
            self.assertIn("fixed settings", output.getvalue())

    def test_invalid_boundary_snapshot_rejected(self):
        for value in (snapshot(""), snapshot(main={"source": "article", "text": "text"}, truncated=True), {"full_text": "text"}):
            with self.assertRaises(ValueError):
                collector.validate_snapshot(value)


class WorkerAndScheduleTests(unittest.TestCase):
    def test_delayed_wakeup_does_not_burst_capture_attempts(self):
        clock = [0.0]
        starts = []

        def sleep(seconds):
            clock[0] += seconds + (9 if not starts else 0)

        def attempt():
            starts.append(clock[0])
            return {"snapshot": snapshot()}

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(collector, "MAX_SAMPLES", 2):
            store = collector.SampleStore(Path(directory) / "samples")
            try:
                self.assertEqual(collector.collect(store, attempt, lambda: clock[0], sleep, lambda _: None), 0)
            finally:
                store.close()
        self.assertEqual(starts, [9, 19])

    def test_large_payload_file_ipc(self):
        result = collector.run_attempt(large_worker)
        self.assertEqual(result["snapshot"]["full_text"], "文" * 300_000)

    def test_timeout_reaps_worker(self):
        before = {process.pid for process in mp.active_children()}
        started = time.monotonic()
        result = collector.run_attempt(hanging_worker, timeout=0.5)
        self.assertIn("timed out", result["error"])
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual({process.pid for process in mp.active_children()}, before)

    def test_monotonic_schedule_skips_missed_ticks(self):
        self.assertEqual(collector.next_tick(0, 0.1), 10)
        self.assertEqual(collector.next_tick(0, 10), 20)
        self.assertEqual(collector.next_tick(0, 25), 30)
        self.assertEqual(collector.next_tick(10, 41), 50)


def stat_mode(path):
    return path.stat().st_mode & 0o777


if __name__ == "__main__":
    unittest.main()
