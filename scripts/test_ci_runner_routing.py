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
        value = context
        for key in match.group().split('.'):
            value = value.get(key) if isinstance(value, dict) else None
        # GitHub objects are truthy, even when empty; missing properties are null.
        return repr(True if isinstance(value, dict) else value)

    expression = re.sub(r'\b(?:github|needs)(?:\.[\w-]+)+', resolve, expression)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression).strip()

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
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq):
            left, right = visit(node.left), visit(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                return left.casefold() == right.casefold()
            return left == right
        raise ValueError(f'Unsupported expression: {ast.dump(node)}')

    return visit(ast.parse(expression, mode='eval').body)


class RunnerRoutingTests(unittest.TestCase):
    def test_every_job_routes_ownership_and_rerun_scenarios(self):
        scenarios = [
            ('maintainer push', 'push', 'pHequals7', {}, True),
            ('community push', 'push', 'contributor', {}, False),
            ('bot push', 'push', 'github-actions[bot]', {}, False),
            ('maintainer PR', 'pull_request', 'pHequals7', {'pull_request': {'user': {'login': 'pHequals7'}}}, True),
            ('community PR', 'pull_request', 'contributor', {'pull_request': {'user': {'login': 'contributor'}}}, False),
            ('maintainer updates community PR', 'pull_request', 'pHequals7', {'pull_request': {'user': {'login': 'contributor'}}}, False),
            ('community updates maintainer PR', 'pull_request', 'contributor', {'pull_request': {'user': {'login': 'pHequals7'}}}, False),
            ('maintainer updates bot PR', 'pull_request', 'pHequals7', {'pull_request': {'user': {'login': 'blacksmith-sh[bot]'}}}, False),
            ('missing PR author', 'pull_request', 'pHequals7', {'pull_request': {}}, False),
            ('maintainer manual run', 'workflow_dispatch', 'pHequals7', {}, True),
            ('community manual run', 'workflow_dispatch', 'contributor', {}, False),
            ('maintainer requests own issue', 'issue_comment', 'pHequals7', {'issue': {'user': {'login': 'pHequals7'}}}, True),
            ('maintainer requests community issue or PR', 'issue_comment', 'pHequals7', {'issue': {'user': {'login': 'contributor'}}}, False),
            ('community requests maintainer issue', 'issue_comment', 'contributor', {'issue': {'user': {'login': 'pHequals7'}}}, False),
            ('maintainer reviews community PR', 'pull_request_review', 'pHequals7', {'pull_request': {'user': {'login': 'contributor'}}}, False),
            ('missing actor', 'push', None, {}, False),
        ]
        for filename, job_count in WORKFLOWS.items():
            text = (ROOT / '.github/workflows' / filename).read_text()
            expressions = re.findall(r'^    runs-on: >-\n((?:      .+\n)+)', text, re.M)
            self.assertEqual(len(expressions), job_count, filename)
            self.assertEqual(len(re.findall(r'^    runs-on:', text, re.M)), job_count, filename)
            for index, block in enumerate(expressions):
                expression = ' '.join(block.split()).removeprefix('${{').removesuffix('}}').strip()
                native = 'blacksmith-6vcpu-macos-26' in expression
                paid = 'blacksmith-6vcpu-macos-26' if native else 'blacksmith-4vcpu-ubuntu-2404'
                free = 'macos-26' if native else 'ubuntu-latest'
                for name, event_name, actor, event, allowed in scenarios:
                    context = {'github': {'repository': 'Muesli-HQ/muesli', 'event_name': event_name,
                                          'actor': actor, 'event': event}}
                    # Reruns must preserve the original route, regardless of who reruns.
                    for rerunner in ('pHequals7', 'contributor'):
                        context['github']['triggering_actor'] = rerunner
                        with self.subTest(workflow=filename, job=index, case=name, rerunner=rerunner):
                            self.assertEqual(evaluate(expression, context), paid if allowed else free)
                    fork = deepcopy(context)
                    fork['github']['repository'] = 'contributor/muesli'
                    with self.subTest(workflow=filename, job=index, case=name, fork=True):
                        self.assertEqual(evaluate(expression, fork), free)

    def test_regression_suite_is_registered(self):
        text = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('run: python3 ./scripts/test_ci_runner_routing.py', text)


if __name__ == '__main__':
    unittest.main()
