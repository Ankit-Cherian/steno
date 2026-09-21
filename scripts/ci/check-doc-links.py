#!/usr/bin/env python3
"""Check local inline Markdown link targets without making network requests."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def missing_links(root, files):
    errors = []
    for name in files:
        if not name.endswith('.md'):
            continue
        path = root / name
        text = re.sub(r'```.*?```|~~~.*?~~~', '', path.read_text(), flags=re.S)
        for match in re.finditer(r'\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\s*\)', text):
            target = match[1].strip('<>')
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            destination = (root if parsed.path.startswith('/') else path.parent) / unquote(parsed.path.lstrip('/'))
            if not destination.exists():
                errors.append(f'{name}: missing local link target {target}')
    return errors


def main():
    files = subprocess.check_output(['git', 'ls-files', '-z', '*.md'], text=True).split('\0')
    errors = missing_links(Path.cwd(), [name for name in files if name])
    for error in errors:
        print(error, file=sys.stderr)
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
