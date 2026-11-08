"""Atomic publish retention (J10 / #186): after a release is switched in, the game keeps `current` plus the previous successful release, and
nothing else. Half copies left by a crash (`.partial`) are removed; anything outside `<game>/releases/` is never touched."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))

import build
from core import Failure


class RetainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm retain ")
        self.game = Path(self.tmp.name) / "games" / "0100000000000000"
        self.releases = self.game / "releases"
        self.releases.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def release(self, name, age):
        path = self.releases / name
        path.mkdir()
        (path / "S2ArmGame.app").mkdir()
        (path / "manifest.json").write_text("{}")
        stamp = time.time() - age
        os.utime(path, (stamp, stamp))
        return path

    def current(self, name):
        link = self.game / ".current-test"
        link.symlink_to(Path("releases") / name)
        os.replace(link, self.game / "current")

    def names(self):
        return sorted(p.name for p in self.releases.iterdir())

    def test_current_and_previous_are_kept_and_older_releases_go(self):
        self.release("old-1", 400)
        self.release("old-2", 300)
        self.release("previous", 200)
        self.release("current", 100)
        self.current("current")
        result = build.retain_releases(self.game)
        self.assertEqual(result["kept"][0], "current")          # the release `current` points at is never pruned
        self.assertEqual(sorted(result["kept"]), ["current", "previous"])
        self.assertEqual(sorted(result["removed"]), ["old-1", "old-2"])
        self.assertEqual(self.names(), ["current", "previous"])
        self.assertEqual((self.game / "current").resolve(), (self.releases / "current").resolve())

    def test_a_crash_half_copy_is_removed_and_never_counted_as_a_release(self):
        self.release("current", 100)
        self.release("previous", 200)
        self.release("20261025-new.partial", 1)
        self.current("current")
        result = build.retain_releases(self.game)
        self.assertEqual(result["stale"], ["20261025-new.partial"])
        self.assertEqual(result["removed"], [])                 # the pair itself stays, the half copy is not one of them
        self.assertEqual(self.names(), ["current", "previous"])

    def test_two_releases_are_left_alone(self):
        self.release("current", 100)
        self.release("previous", 200)
        self.current("current")
        self.assertEqual(build.retain_releases(self.game), dict(kept=["current", "previous"], removed=[], stale=[]))
        self.assertEqual(self.names(), ["current", "previous"])

    def test_an_unpublished_game_is_not_an_error(self):
        empty = Path(self.tmp.name) / "games" / "0100000000000001"
        empty.mkdir(parents=True)
        self.assertEqual(build.retain_releases(empty), dict(kept=[], removed=[], stale=[]))

    def test_symlinks_inside_releases_are_not_followed_or_deleted(self):
        self.release("current", 100)
        self.release("previous", 200)
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (outside / "keep-me").write_text("x")
        (self.releases / "linked").symlink_to(outside)
        self.current("current")
        build.retain_releases(self.game)
        self.assertTrue((outside / "keep-me").is_file())
        self.assertTrue((self.releases / "linked").is_symlink())

    def test_a_current_link_pointing_outside_releases_is_ignored(self):
        self.release("a", 200)
        self.release("b", 100)
        outside = Path(self.tmp.name) / "elsewhere"
        outside.mkdir()
        (outside / "keep-me").write_text("x")
        link = self.game / ".current-test"
        link.symlink_to(outside)
        os.replace(link, self.game / "current")
        result = build.retain_releases(self.game)
        self.assertEqual(sorted(result["kept"]), ["a", "b"])     # a foreign current keeps nothing; the two newest releases stay
        self.assertEqual(result["removed"], [])
        self.assertTrue((outside / "keep-me").is_file())

    def test_a_releases_directory_symlinked_outside_the_game_is_refused(self):
        # A release tree that has been replaced by a link to another disk must not become a delete target
        game = Path(self.tmp.name) / "games" / "0100000000000002"
        game.mkdir(parents=True)
        outside = Path(self.tmp.name) / "elsewhere2"
        (outside / "releases").mkdir(parents=True)
        (outside / "releases" / "keep").mkdir()
        (game / "releases").symlink_to(outside / "releases")
        with self.assertRaises(Failure):
            build.retain_releases(game)
        self.assertTrue((outside / "releases" / "keep").is_dir())


if __name__ == "__main__":
    unittest.main()
