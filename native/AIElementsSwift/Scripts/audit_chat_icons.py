#!/usr/bin/env python3
"""Audit pinned upstream Chatbot sources + in-repo component dependencies.

Usage: python3 Scripts/audit_chat_icons.py AI_ELEMENTS_CHECKOUT LUCIDE_CHECKOUT
Writes the deterministic coverage manifest; copies any missing licensed SVGs.
No network access. External npm dependencies and application examples are excluded.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
AI_REV = '6a9d5b1822ffb10bba4bd97175f01edd7d8651cd'
LUCIDE_REV = '70562c1ee1c4fdcf736fe97bc893fb8511927934'
ai, lucide = (Path(p).resolve() for p in sys.argv[1:])
for checkout, revision in ((ai, AI_REV), (lucide, LUCIDE_REV)):
    assert subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip() == revision, 'Unexpected source revision'

components = sorted(p.stem for p in (ai / 'apps/docs/content/components/(chatbot)').glob('*.mdx'))
aliases = {}
for metadata in (lucide / 'icons').glob('*.json'):
    for alias in json.loads(metadata.read_text()).get('aliases', []):
        aliases[alias if isinstance(alias, str) else alias['name']] = metadata.stem

def resolve_icon(import_name):
    name = re.sub(r'Icon$', '', import_name)
    kebab = re.sub(r'(?<!^)(?=[A-Z0-9])', '-', name).lower()
    canonical = kebab if (lucide / 'icons' / f'{kebab}.svg').exists() else aliases[kebab]
    swift = canonical.split('-')[0] + ''.join(p.title() for p in canonical.split('-')[1:])
    return canonical, swift

pending = [ai / 'packages/elements/src' / f'{name}.tsx' for name in components]
visited = set()
files = []
while pending:
    file = pending.pop()
    if file in visited:
        continue
    visited.add(file)
    source = file.read_text()
    imports = []
    for match in re.finditer(r'import\s+(?!type\b)\{([^}]+)\}\s+from\s+[\'\"]lucide-react[\'\"]', source):
        for item in match[1].split(','):
            item = item.strip()
            if not item or item.startswith('type '):
                continue
            imported = item.split()[0]
            canonical, swift = resolve_icon(imported)
            svg = lucide / 'icons' / f'{canonical}.svg'
            target = ROOT / 'Upstream/Lucide' / svg.name
            if target.exists():
                assert target.read_bytes() == svg.read_bytes(), f'Artwork mismatch: {canonical}'
            else:
                shutil.copyfile(svg, target)
            imports.append({'import': imported, 'svg': canonical, 'swift': swift,
                            'sha256': hashlib.sha256(svg.read_bytes()).hexdigest()})
    files.append({'path': str(file.relative_to(ai)), 'icons': sorted(imports, key=lambda x: x['import'])})
    for module in re.findall(r'from\s+[\'\"]([^\'\"]+)[\'\"]', source):
        if module.startswith('@repo/shadcn-ui/components/'):
            dependency = ai / 'packages/shadcn-ui' / module.removeprefix('@repo/shadcn-ui/')
        elif module.startswith('./') or module.startswith('../'):
            dependency = file.parent / module
        else:
            continue
        candidates = [dependency.with_suffix('.tsx'), dependency.with_suffix('.ts')]
        resolved = next((p.resolve() for p in candidates if p.exists()), None)
        if resolved is None:
            raise ValueError(f'Unresolved component dependency: {module}')
        pending.append(resolved)

manifest = {'aiElementsRevision': AI_REV, 'lucideRevision': LUCIDE_REV,
            'chatbotComponents': components,
            'scope': 'Lucide value imports in the 19 upstream Chatbot component sources and recursively imported in-repository component dependencies. Excludes external npm internals, docs/examples, custom SVG artwork, other categories, and consumer-supplied icons.',
            'files': sorted(files, key=lambda x: x['path'])}
(ROOT / 'Upstream/chat-icon-coverage.json').write_text(json.dumps(manifest, indent=2) + '\n')
icons = {icon['svg'] for file in files for icon in file['icons']}
print(f'Audited {len(components)} Chatbot components, {len(files)} source files, {len(icons)} distinct Lucide icons')
