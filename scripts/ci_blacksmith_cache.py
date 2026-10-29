#!/usr/bin/env python3
"""Strict adapter for Blacksmith CLI 0.5.3 Actions-cache management."""

import json
import os
import subprocess

from ci_release_cache_cleanup import KEY_PATTERN, MAIN_REF, NAMESPACE, cleanup_plan, timestamp, trusted_context

MAX_PAGES = 100
PAGE_SIZE = 100


def command(*args):
    # Do not allow shell interpolation or automatic CLI upgrades during deletion.
    return ['blacksmith', '--org', 'Muesli-HQ', 'cache', *args]


def run_json(args):
    result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=60,
                            env={**os.environ, 'BLACKSMITH_DISABLE_AUTO_UPDATE': '1'})
    return json.loads(result.stdout)


def identity(entry):
    return (entry['key'], entry['version'], entry['scope'], entry['transparent_cache'])


def list_caches(repo):
    """Read all pages before making any deletion; reject changing/incomplete lists."""
    entries = []
    expected_total = None
    for page in range(1, MAX_PAGES + 1):
        data = run_json(command('list', '--repo', repo, '--search', NAMESPACE,
                                '--sort-by', 'key', '--sort-direction', 'asc',
                                '--page', str(page), '--per-page', str(PAGE_SIZE), '--format', 'json'))
        if not isinstance(data, dict) or not isinstance(data.get('entries'), list):
            raise ValueError('Invalid Blacksmith cache-list response')
        pagination = data.get('pagination')
        if not isinstance(pagination, dict):
            raise ValueError('Missing Blacksmith pagination metadata')
        total = pagination.get('total')
        if type(total) is not int or total < 0 or total > MAX_PAGES * PAGE_SIZE:
            raise ValueError('Invalid Blacksmith cache-list total')
        last_page = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
        if (type(pagination.get('current_page')) is not int or pagination['current_page'] != page
                or type(pagination.get('per_page')) is not int or pagination['per_page'] != PAGE_SIZE
                or type(pagination.get('last_page')) is not int or pagination['last_page'] != last_page
                or type(pagination.get('has_more_pages')) is not bool
                or pagination['has_more_pages'] != (page < last_page)):
            raise ValueError('Inconsistent Blacksmith pagination metadata')
        if expected_total is not None and total != expected_total:
            raise ValueError('Blacksmith cache list changed during pagination; retry cleanup')
        expected_total = total
        rows = data['entries']
        if not rows or len(rows) > PAGE_SIZE:
            if not rows and len(entries) == total:
                return normalize(entries)
            raise ValueError('Incomplete Blacksmith cache-list page')
        entries.extend(rows)
        if len(entries) == total:
            return normalize(entries)
        if len(entries) > total or len(rows) != PAGE_SIZE:
            raise ValueError('Incomplete Blacksmith cache-list pagination')
    raise ValueError('Blacksmith cache-list page limit exceeded')


def normalize(rows):
    """Keep explicit main release entries; never invent a scope or cache version."""
    result = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('Invalid Blacksmith cache entry')
        if row.get('type') != 'actions' or not KEY_PATTERN.fullmatch(row.get('key', '')):
            continue
        if row.get('scope') not in ('main', MAIN_REF):
            continue
        if not isinstance(row.get('version'), str) or not row['version'].strip():
            raise ValueError('Missing Blacksmith cache version')
        if type(row.get('transparent_cache')) is not bool:
            raise ValueError('Missing Blacksmith cache variant')
        if type(row.get('size_bytes')) is not int or row['size_bytes'] <= 0:
            raise ValueError('Blacksmith cache is not fully populated')
        timestamp(row['created_at'])  # Never use last access time for snapshot age.
        key = identity(row)
        if key in seen:
            raise ValueError('Duplicate Blacksmith cache identity; refusing broad deletion')
        seen.add(key)
        result.append({**row, 'ref': MAIN_REF, 'size_in_bytes': row['size_bytes']})
    # Shared planner requires numeric IDs; synthetic IDs are used ONLY within
    # this list. The external identity is always key/version/scope/variant.
    result.sort(key=identity)
    return [{**row, 'id': index} for index, row in enumerate(result, 1)]


def delete_cache(repo, entry):
    subprocess.run(command('delete', '--repo', repo, '--key', entry['key'],
                           '--version', entry['version'], '--scope', entry['scope'],
                           '--transparent-cache', str(entry['transparent_cache']).lower(), '--yes'),
                   check=True, capture_output=True, text=True, timeout=60,
                   env={**os.environ, 'BLACKSMITH_DISABLE_AUTO_UPDATE': '1'})


def cleanup(env, delete=False):
    repo, key = trusted_context(env)
    if repo != 'Muesli-HQ/muesli':
        raise ValueError('Blacksmith retention is restricted to Muesli-HQ/muesli')
    victims = cleanup_plan(list_caches(repo), key)
    deleted = []
    for entry in victims:
        print(f"{'Candidate' if delete else 'Would delete'} Blacksmith main release cache: {entry['key']}")
        if not delete:
            continue
        current = cleanup_plan(list_caches(repo), key)
        target = next((item for item in current if identity(item) == identity(entry)), None)
        if target is None:
            continue
        if target['created_at'] != entry['created_at'] or target['size_bytes'] != entry['size_bytes']:
            raise ValueError('Blacksmith cache changed before deletion')
        delete_cache(repo, target)
        after = list_caches(repo)
        cleanup_plan(after, key)  # Replacement must still be present.
        if any(identity(item) == identity(target) for item in after):
            raise ValueError('Blacksmith deletion did not remove the exact cache variant')
        deleted.append(identity(target))
    if delete and cleanup_plan(list_caches(repo), key):
        raise ValueError('Blacksmith retention incomplete; retry cleanup')
    print(f'Blacksmith release cache cleanup: {len(deleted)} deleted; retention target 3 snapshots.')
    return deleted
