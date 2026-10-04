#!/usr/bin/env python3
"""Cleanup safety tests: all API calls are mocked; no real caches are deleted."""

import json
import unittest
from unittest.mock import patch

import ci_release_cache_cleanup as cleanup


def entry(number, **overrides):
    return {"id": number, "key": f"ci-release-v1-{'a' * 64}-{number:040x}",
            "ref": "refs/heads/main", "created_at": f"2026-10-01T12:00:{number:02}Z",
            "size_in_bytes": 1_600_000_000, **overrides}


def context(**overrides):
    return {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "Muesli-HQ/muesli", "GITHUB_SHA": f"{8:040x}",
            "CACHE_KEY": entry(8)["key"], "CACHE_SAVE_OUTCOME": "success", **overrides}


class CleanupTests(unittest.TestCase):
    def test_retains_newest_three_and_deletes_only_older_snapshots(self):
        entries = [entry(n) for n in range(1, 9)]
        victims = cleanup.cleanup_plan(entries, entry(8)["key"])
        self.assertEqual([e["id"] for e in victims], [5, 4, 3, 2, 1])

    def test_ignores_other_namespaces_branches_and_malformed_keys(self):
        foreign = [entry(20, key="localvqe-macos"), entry(21, key="experiment-spm-v1-test"),
                   entry(22, ref="refs/pull/558/merge"), entry(23, ref="refs/heads/feature"),
                   entry(24, key="ci-release-v1-not-a-complete-key")]
        entries = [entry(n) for n in range(1, 9)] + foreign
        self.assertEqual([e["id"] for e in cleanup.cleanup_plan(entries, entry(8)["key"])], [5, 4, 3, 2, 1])

    def test_retention_covers_namespace_across_compatibility_generations(self):
        entries = [entry(n, key=f"ci-release-v1-{n:064x}-{n:040x}") for n in range(1, 9)]
        self.assertEqual(len(cleanup.cleanup_plan(entries, entries[-1]["key"])), 5)

    def test_out_of_order_job_never_deletes_newer_snapshots(self):
        entries = [entry(n) for n in range(1, 9)]
        self.assertEqual([e["id"] for e in cleanup.cleanup_plan(entries, entry(3)["key"])], [2, 1])

    def test_missing_or_wrong_scope_replacement_prevents_deletion(self):
        for entries in ([entry(1)], [entry(8, ref="refs/pull/558/merge")]):
            with self.subTest(entries=entries), self.assertRaisesRegex(ValueError, "Replacement cache not visible"):
                cleanup.cleanup_plan(entries, entry(8)["key"])

    def test_invalid_metadata_prevents_all_deletion(self):
        for fields in ({"id": "1"}, {"id": True}, {"id": -1}, {"size_in_bytes": 0},
                       {"size_in_bytes": "10"}, {"created_at": "bad"},
                       {"created_at": "2026-10-01T12:00:01"}):
            with self.subTest(fields=fields), self.assertRaises((ValueError, TypeError)):
                cleanup.cleanup_plan([entry(1, **fields), entry(8)], entry(8)["key"])
        with self.assertRaises(ValueError):
            cleanup.cleanup_plan([entry(8), entry(8)], entry(8)["key"])

    def test_untrusted_context_bypass_and_failed_save_never_call_api(self):
        for fields in ({"GITHUB_ACTIONS": "false"}, {"GITHUB_EVENT_NAME": "pull_request"},
                       {"GITHUB_EVENT_NAME": "workflow_dispatch"}, {"GITHUB_REF": "refs/heads/other"},
                       {"CACHE_SAVE_OUTCOME": "failure"}, {"CACHE_SAVE_OUTCOME": "skipped"},
                       {"CACHE_DISABLED": "true"}, {"CACHE_KEY": ""},
                       {"GITHUB_SHA": f"{7:040x}"}, {"GITHUB_REPOSITORY": "../../other"}):
            with self.subTest(fields=fields), patch.object(cleanup, "list_caches") as api:
                with self.assertRaises(ValueError):
                    cleanup.cleanup(context(**fields), delete=True)
                api.assert_not_called()

    def test_dry_run_never_deletes(self):
        with patch.object(cleanup, "list_caches", return_value=[entry(n) for n in range(1, 9)]), \
                patch.object(cleanup, "delete_cache") as delete, patch("builtins.print"):
            self.assertEqual(cleanup.cleanup(context()), [])
            delete.assert_not_called()

    def test_replacement_evicted_between_plan_and_delete_stops_cleanup(self):
        with patch.object(cleanup, "list_caches", side_effect=[
                [entry(n) for n in range(1, 9)], [entry(n) for n in range(1, 8)]]), \
                patch.object(cleanup, "delete_cache") as delete, patch("builtins.print"):
            with self.assertRaises(ValueError):
                cleanup.cleanup(context(), delete=True)
            delete.assert_not_called()

    def test_only_revalidated_numeric_ids_are_deleted(self):
        entries = [entry(n) for n in range(1, 9)]
        with patch.object(cleanup, "list_caches", return_value=entries), \
                patch.object(cleanup, "delete_cache") as delete, patch("builtins.print"):
            self.assertEqual(cleanup.cleanup(context(), delete=True), [5, 4, 3, 2, 1])
            self.assertEqual([call.args for call in delete.call_args_list],
                             [("Muesli-HQ/muesli", n) for n in [5, 4, 3, 2, 1]])

    def test_list_failure_never_deletes(self):
        with patch.object(cleanup, "list_caches", side_effect=RuntimeError("API unavailable")), \
                patch.object(cleanup, "delete_cache") as delete:
            with self.assertRaises(RuntimeError):
                cleanup.cleanup(context(), delete=True)
            delete.assert_not_called()

    def test_delete_failure_stops_further_deletions(self):
        with patch.object(cleanup, "list_caches", return_value=[entry(n) for n in range(1, 9)]), \
                patch.object(cleanup, "delete_cache", side_effect=RuntimeError("API unavailable")) as delete, \
                patch("builtins.print"):
            with self.assertRaises(RuntimeError):
                cleanup.cleanup(context(), delete=True)
            delete.assert_called_once_with("Muesli-HQ/muesli", 5)

    def test_disappeared_target_is_not_deleted(self):
        entries = [entry(n) for n in range(5, 9)]
        with patch.object(cleanup, "list_caches", side_effect=[entries, entries[1:]]), \
                patch.object(cleanup, "delete_cache") as delete, patch("builtins.print"):
            self.assertEqual(cleanup.cleanup(context(), delete=True), [])
            delete.assert_not_called()

    def test_reads_all_pages_with_explicit_get_and_narrow_filters(self):
        pages = [{"actions_caches": [entry(1)]}, {"actions_caches": [entry(8)]}]
        with patch.object(cleanup.subprocess, "check_output", return_value=json.dumps(pages)) as api:
            self.assertEqual(cleanup.list_caches("Muesli-HQ/muesli"), [entry(1), entry(8)])
        command = api.call_args.args[0]
        for part in ("GET", "--paginate", "--slurp", "ref=refs/heads/main", "key=ci-release-v1-"):
            self.assertIn(part, command)


if __name__ == "__main__":
    unittest.main()
