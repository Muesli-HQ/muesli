#!/usr/bin/env python3
"""Exercise the actual runs-on expressions without installing CI dependencies."""
import ast
from copy import deepcopy
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {
    'ci.yml': 9,
    'ci-build-cache-experiment.yml': 2,
    'claude-code-review.yml': 2,
    'claude.yml': 1,
    'openhands-resolver.yml': 1,
    'update-download-link.yml': 1,
}


def evaluate(expression, context):
    """Evaluate only the boolean/identity subset used by runner selection.

    Read expressions from YAML, not a second implementation of the policy.
    Reject unsupported syntax rather than executing arbitrary Python.
    """
    def resolve(match):
        def walk(value, keys):
            if not keys:
                return True if isinstance(value, dict) else value
            key, *tail = keys
            if key == '*':
                return [walk(item, tail) for item in value] if isinstance(value, list) else []
            return walk(value.get(key) if isinstance(value, dict) else None, tail)
        return repr(walk(context, match.group().split('.')))

    expression = re.sub(r"\b(?:github|needs|inputs|vars|env)(?:\.[\w*-]+)+", resolve, expression)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression).strip()
    expression = re.sub(r'\b(true|false|null)\b', lambda m: {'true': 'True', 'false': 'False', 'null': 'None'}[m[0]], expression)

    def visit(node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not visit(node.operand)
        if isinstance(node, ast.BoolOp):
            value = visit(node.values[0])
            for operand in node.values[1:]:
                if isinstance(node.op, ast.And):
                    value = visit(operand) if value else value
                elif isinstance(node.op, ast.Or):
                    value = value if value else visit(operand)
                else:
                    raise ValueError('Unsupported boolean operator')
            return value
        if isinstance(node, ast.List):
            return [visit(item) for item in node.elts]
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            args = [visit(arg) for arg in node.args]
            if node.func.id == 'contains' and len(args) == 2:
                return any(str(value).casefold() == str(args[1]).casefold() for value in args[0])
            if node.func.id == 'always' and not args:
                return True
            if node.func.id == 'format':
                return args[0].format(*args[1:])
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
            left, right = visit(node.left), visit(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                left, right = left.casefold(), right.casefold()
            return (left == right) if isinstance(node.ops[0], ast.Eq) else (left != right)
        raise ValueError(f'Unsupported expression: {ast.dump(node)}')

    return visit(ast.parse(expression, mode='eval').body)


def context(event='pull_request', actor='pHequals7', labels=(), ref='refs/pull/698/merge',
            warm=False, action='synchronize', changed_label='ci:blacksmith', author='pHequals7'):
    return {'github': {'repository': 'Muesli-HQ/muesli', 'event_name': event, 'actor': actor,
                       'ref': ref, 'run_id': 123, 'event': {'action': action, 'label': {'name': changed_label},
                       'pull_request': {'user': {'login': author}, 'labels': [{'name': l} for l in labels]}}},
            'inputs': {'warm_blacksmith_cache': warm}}


class RunnerRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / '.github/workflows/ci.yml').read_text()

    def expression(self, key):
        match = re.search(r'^      ' + key + r': \$\{\{ (.+) \}\}$', self.workflow, re.M)
        self.assertIsNotNone(match, key)
        return match[1]

    def job(self, name):
        return re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [\w-]+:|\Z)', self.workflow, re.M | re.S)[1]

    def test_every_job_routes_only_explicit_opt_ins(self):
        scenarios = [
            ('unlabelled maintainer PR', context(), False),
            ('labelled maintainer PR', context(labels=['ci:blacksmith']), True),
            ('adding opt-in', context(labels=['ci:blacksmith'], action='labeled'), True),
            ('removing opt-in', context(action='unlabeled'), False),
            ('other label only', context(labels=['bug']), False),
            ('maintainer selects bot PR', context(labels=['ci:blacksmith'], author='blacksmith-sh[bot]'), True),
            ('maintainer selects community PR', context(labels=['ci:blacksmith'], author='contributor'), True),
            ('community update to opted-in PR', context(labels=['ci:blacksmith'], actor='contributor'), False),
            ('bot update to opted-in PR', context(labels=['ci:blacksmith'], actor='github-actions[bot]'), False),
            ('merge into main', context(event='push', ref='refs/heads/main'), False),
            ('push cannot spoof an opt-in', context(event='push', labels=['ci:blacksmith'], warm=True), False),
            ('ordinary manual main run', context(event='workflow_dispatch', ref='refs/heads/main'), False),
            ('manual main warm-up', context(event='workflow_dispatch', ref='refs/heads/main', warm=True), True),
            ('manual feature warm-up', context(event='workflow_dispatch', ref='refs/heads/feature', warm=True), False),
            ('contributor main warm-up', context(event='workflow_dispatch', ref='refs/heads/main', warm=True, actor='contributor'), False),
            ('missing actor', context(labels=['ci:blacksmith'], actor=None), False),
            ('issue comment', context(event='issue_comment', labels=['ci:blacksmith']), False),
        ]
        for filename, count in WORKFLOWS.items():
            text = (ROOT / '.github/workflows' / filename).read_text()
            if filename != 'ci.yml':
                self.assertNotIn('blacksmith-', text, filename)
                self.assertEqual(len(re.findall(r'^    runs-on: (ubuntu-latest|macos-26)$', text, re.M)), count)
                continue
            expressions = re.findall(r'^    runs-on: >-\n((?:      .+\n)+)', text, re.M)
            self.assertEqual(len(expressions), count)
            for block in expressions:
                expression = ' '.join(block.split()).removeprefix('${{').removesuffix('}}').strip()
                native = 'blacksmith-6vcpu-macos-26' in expression
                paid = 'blacksmith-6vcpu-macos-26' if native else 'blacksmith-4vcpu-ubuntu-2404'
                free = 'macos-26' if native else 'ubuntu-latest'
                for name, ctx, allowed in scenarios:
                    for rerunner in ('pHequals7', 'contributor'):
                        ctx['github']['triggering_actor'] = rerunner
                        with self.subTest(case=name, rerunner=rerunner, runner=paid):
                            self.assertEqual(evaluate(expression, ctx), paid if allowed else free)
                    fork = deepcopy(ctx)
                    fork['github']['repository'] = 'contributor/muesli'
                    self.assertEqual(evaluate(expression, fork), free)

    def test_main_cache_writes_require_push_or_authorized_warm_up(self):
        warm = self.expression('warm_blacksmith_cache')
        write = self.expression('cache_write_allowed')
        cases = [
            (context(event='push', ref='refs/heads/main'), False, True),
            (context(event='push', ref='refs/heads/feature'), False, False),
            (context(labels=['ci:blacksmith']), False, False),
            (context(event='workflow_dispatch', ref='refs/heads/main'), False, False),
            (context(event='workflow_dispatch', ref='refs/heads/main', warm=True), True, True),
            (context(event='workflow_dispatch', ref='refs/heads/feature', warm=True), False, False),
            (context(event='workflow_dispatch', ref='refs/heads/main', warm=True, actor='contributor'), False, False),
        ]
        for ctx, should_warm, should_write in cases:
            with self.subTest(context=ctx):
                self.assertEqual(bool(evaluate(warm, ctx)), should_warm)
                self.assertEqual(bool(evaluate(write, ctx)), should_write)
        validation = self.job('changes').split('      - name: Validate manual cache warm-up')[1].split('      - uses:')[0]
        self.assertIn('WARM_ALLOWED: ${{ ' + warm + ' }}', validation)
        self.assertIn('"$CACHE_DISABLED" == "true"', validation)
        self.assertIn('exit 1', validation)
        for name in ('test_shards', 'ai-elements', 'cli-smoke', 'update-flow'):
            condition = re.search(r'^    if: (.+)$', self.job(name), re.M)[1]
            for warm_mode in ('true', 'false'):
                ctx = {'needs': {'changes': {'outputs': {'native_or_packaging': 'true', 'full_ci': 'true', 'warm_blacksmith_cache': warm_mode}}}}
                self.assertEqual(bool(evaluate(condition, ctx)), warm_mode == 'false')

    def test_unrelated_labels_neither_replace_gate_nor_cancel_real_ci(self):
        self.assertIn('converted_to_draft, labeled, unlabeled]', self.workflow)
        group = re.search(r'^  group: (.+)$', self.workflow, re.M)[1]
        def render(template, ctx):
            return re.sub(r'\$\{\{ (.*?) \}\}', lambda m: str(evaluate(m[1], ctx)), template)
        normal = render(group, context())
        self.assertEqual(normal, 'ci-refs/pull/698/merge')
        gate_name = re.search(r'^    name: (.+)$', self.job('ci-gate'), re.M)[1]
        for action in ('labeled', 'unlabeled', 'synchronize'):
            for label in ('ci:blacksmith', 'bug'):
                ctx = context(action=action, changed_label=label)
                relevant = action == 'synchronize' or label == 'ci:blacksmith'
                for job in ('changes', 'classifier-tests', 'ci-gate'):
                    condition = re.search(r'^    if: >-\n((?:      .+\n)+)', self.job(job), re.M)[1]
                    self.assertEqual(bool(evaluate(' '.join(condition.split()), ctx)), relevant)
                self.assertEqual(render(gate_name, ctx), 'ci-gate' if relevant else 'ignored-label-event')
                self.assertEqual(render(group, ctx) == normal, relevant)
        main = context(event='push', ref='refs/heads/main')
        warming = context(event='workflow_dispatch', ref='refs/heads/main', warm=True)
        self.assertNotEqual(render(group, main), render(group, warming))
        self.assertEqual(render(gate_name, warming), 'blacksmith-cache-warm')
        self.assertEqual(render(gate_name, main), 'ci-gate')

    def test_regression_suite_is_registered(self):
        self.assertIn('run: python3 ./scripts/test_ci_runner_routing.py', self.workflow)


if __name__ == '__main__':
    unittest.main()
