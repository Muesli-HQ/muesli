#!/usr/bin/env python3
"""Synthetic cache inventory only; tests never authenticate or delete real data."""
import unittest
from unittest.mock import patch

import ci_blacksmith_cache as backend
from test_ci_release_cache_cleanup import context


def entry(n, **changes):
    return {'type': 'actions', 'key': f"ci-release-v1-{'a' * 64}-{n:040x}",
            'version': 'version-1', 'scope': 'refs/heads/main', 'transparent_cache': True,
            'created_at': f'2026-10-01T12:00:{n:02}Z', 'size_bytes': 100, **changes}


def page(rows, total, current=1):
    last = max(1, (total + backend.PAGE_SIZE - 1) // backend.PAGE_SIZE)
    return {'entries': rows, 'bazel_entries': [], 'pagination': {
        'current_page': current, 'per_page': backend.PAGE_SIZE, 'total': total,
        'last_page': last, 'has_more_pages': current < last}}


class BlacksmithTests(unittest.TestCase):
    def setUp(self):
        quiet = patch('builtins.print')
        quiet.start()
        self.addCleanup(quiet.stop)

    def test_retains_three_and_narrows_each_delete(self):
        rows = [entry(n) for n in range(1, 9)]
        def remove(repo, item):
            rows[:] = [row for row in rows if backend.identity(row) != backend.identity(item)]
        with patch.object(backend, 'list_caches', side_effect=lambda repo: backend.normalize(rows)), \
             patch.object(backend, 'delete_cache', side_effect=remove) as delete:
            removed = backend.cleanup(context(), delete=True)
        self.assertEqual(len(removed), 5)
        self.assertEqual([row['key'] for row in rows], [entry(n)['key'] for n in (6, 7, 8)])
        self.assertEqual(delete.call_count, 5)

    def test_unrelated_caches_and_scopes_are_preserved(self):
        rows = [entry(1), entry(2, scope='refs/pull/698/merge'), entry(3, scope=None),
                entry(4, key='localvqe-test'), entry(5, type='bazel')]
        self.assertEqual([x['key'] for x in backend.normalize(rows)], [entry(1)['key']])

    def test_missing_metadata_or_duplicate_identity_fails_closed(self):
        for changes in ({'version': ''}, {'transparent_cache': None}, {'size_bytes': 0},
                        {'created_at': 'invalid'}, {'created_at': '2026-10-01T12:00:00'}):
            with self.subTest(changes=changes), self.assertRaises((ValueError, TypeError)):
                backend.normalize([entry(1, **changes)])
        with self.assertRaises(ValueError):
            backend.normalize([entry(1), entry(1)])

    def test_reads_complete_paginated_inventory_before_deleting(self):
        rows = [entry(1, key=f"ci-release-v1-{'a' * 64}-{n:040x}") for n in range(101)]
        with patch.object(backend, 'run_json', side_effect=[
                page(rows[:100], 101), page(rows[100:], 101, 2)]) as api:
            self.assertEqual(len(backend.list_caches('Muesli-HQ/muesli')), 101)
        self.assertEqual(api.call_count, 2)
        self.assertIn('2', api.call_args.args[0])

    def test_incomplete_or_changing_pagination_is_rejected(self):
        for response in (page([entry(1)], 2), page([], 2),
                         page([entry(1)], True), {'entries': 'wrong', 'pagination': {}}):
            with self.subTest(response=response), patch.object(backend, 'run_json', return_value=response), \
                 self.assertRaises(ValueError):
                backend.list_caches('Muesli-HQ/muesli')
        with patch.object(backend, 'run_json', side_effect=[
                page([entry(1)] * 100, 101), page([], 100, 2)]), \
             self.assertRaises(ValueError):
            backend.list_caches('Muesli-HQ/muesli')

    def test_empty_inventory_and_bad_pagination_flags(self):
        with patch.object(backend, 'run_json', return_value=page([], 0)):
            self.assertEqual(backend.list_caches('Muesli-HQ/muesli'), [])
        for fields in ({'current_page': 2}, {'has_more_pages': True}, {'last_page': 5},
                       {'per_page': 50}, {'total': -1}):
            response = page([entry(1)], 1)
            response['pagination'].update(fields)
            with self.subTest(fields=fields), patch.object(backend, 'run_json', return_value=response), \
                 self.assertRaises(ValueError):
                backend.list_caches('Muesli-HQ/muesli')

    def test_delete_uses_every_identity_dimension(self):
        with patch.object(backend.subprocess, 'run') as run:
            backend.delete_cache('Muesli-HQ/muesli', entry(1))
        command = run.call_args.args[0]
        for flag, value in [('--key', entry(1)['key']), ('--version', 'version-1'),
                            ('--scope', 'refs/heads/main'), ('--transparent-cache', 'true')]:
            self.assertEqual(command[command.index(flag) + 1], value)
        self.assertIn('--yes', command)
        self.assertEqual(run.call_args.kwargs['env']['BLACKSMITH_DISABLE_AUTO_UPDATE'], '1')

    def test_missing_replacement_and_untrusted_context_never_delete(self):
        for env, rows in [(context(), [entry(1)]),
                          (context(GITHUB_EVENT_NAME='pull_request'), [entry(1), entry(8)]),
                          (context(GITHUB_REPOSITORY='other/muesli'), [entry(1), entry(8)])]:
            with patch.object(backend, 'list_caches', return_value=backend.normalize(rows)), \
                 patch.object(backend, 'delete_cache') as delete, self.assertRaises(ValueError):
                backend.cleanup(env, delete=True)
            delete.assert_not_called()

    def test_replacement_disappears_during_revalidation(self):
        with patch.object(backend, 'list_caches', side_effect=[
                backend.normalize([entry(n) for n in range(1, 9)]), backend.normalize([entry(1)])]), \
             patch.object(backend, 'delete_cache') as delete, self.assertRaises(ValueError):
            backend.cleanup(context(), delete=True)
        delete.assert_not_called()

    def test_api_failure_stops_before_any_deletion(self):
        with patch.object(backend, 'list_caches', side_effect=RuntimeError('Unavailable')), \
             patch.object(backend, 'delete_cache') as delete, self.assertRaises(RuntimeError):
            backend.cleanup(context(), delete=True)
        delete.assert_not_called()

    def test_changed_or_disappeared_target_is_never_deleted(self):
        initial = backend.normalize([entry(n) for n in (1, 6, 7, 8)])
        for current in (backend.normalize([entry(n) for n in (6, 7, 8)]),
                        backend.normalize([entry(1, size_bytes=200)] + [entry(n) for n in (6, 7, 8)])):
            with patch.object(backend, 'list_caches', side_effect=[initial, current, current]), \
                 patch.object(backend, 'delete_cache') as delete:
                if len(current) == 3:
                    self.assertEqual(backend.cleanup(context(), delete=True), [])
                else:
                    with self.assertRaisesRegex(ValueError, 'changed before deletion'):
                        backend.cleanup(context(), delete=True)
            delete.assert_not_called()

    def test_deletion_failure_stops_further_deletions(self):
        with patch.object(backend, 'list_caches', return_value=backend.normalize([entry(n) for n in range(1, 9)])), \
             patch.object(backend, 'delete_cache', side_effect=RuntimeError('Unavailable')) as delete, \
             self.assertRaises(RuntimeError):
            backend.cleanup(context(), delete=True)
        self.assertEqual(delete.call_count, 1)

    def test_unsuccessful_deletion_is_reported(self):
        with patch.object(backend, 'list_caches', return_value=backend.normalize([entry(n) for n in range(1, 9)])), \
             patch.object(backend, 'delete_cache') as delete, self.assertRaisesRegex(ValueError, 'did not remove'):
            backend.cleanup(context(), delete=True)
        self.assertEqual(delete.call_count, 1)

    def test_dry_run_never_deletes(self):
        with patch.object(backend, 'list_caches', return_value=backend.normalize([entry(n) for n in range(1, 9)])), \
             patch.object(backend, 'delete_cache') as delete:
            self.assertEqual(backend.cleanup(context()), [])
        delete.assert_not_called()


if __name__ == '__main__':
    unittest.main()
