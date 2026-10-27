#!/usr/bin/env python3
"""Offline tests for release version/tag validation; no GitHub access or publishing."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_version", Path(__file__).with_name("release-version.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "3"}

    def test_manual_build_uses_source_version(self):
        self.assertEqual(release.release_version(self.info), "0.3.0")

    def test_matching_tag_and_prerelease(self):
        for tag in ["v0.3.0", "v0.3.0-beta.1"]:
            with self.subTest(tag=tag):
                self.assertEqual(release.release_version(self.info, tag), tag[1:])

    def test_mismatch_and_unsafe_tags_are_rejected(self):
        for tag in ["v0.4.0", "0.3.0", "v00.3.0", "v0.3.0-", "v0.3.0/other", "v0.3.0;echo bad", "v0.3.0\n"]:
            with self.subTest(tag=tag):
                with self.assertRaises(ValueError):
                    release.release_version(self.info, tag)

    def test_invalid_source_versions_are_rejected(self):
        for value in ["$(MARKETING_VERSION)", "0.3", "0.3.0-beta", "00.3.0", ""]:
            with self.subTest(version=value):
                info = dict(self.info, CFBundleShortVersionString=value)
                with self.assertRaises(ValueError):
                    release.release_version(info)
        with self.assertRaises(ValueError):
            release.release_version(dict(self.info, CFBundleVersion="invalid"))


if __name__ == "__main__":
    unittest.main()
