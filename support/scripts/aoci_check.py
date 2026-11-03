#!/usr/bin/env python3
"""AOCI 索引校验。

只做两件事，都针对"会静默腐烂"的失败模式：

1. 索引里引用的每个路径必须真实存在（防止重构后链接指向空气）。
2. `aoci/index.md` 的 fork 插入点表里声明的文件，必须确实含 `[FORK]` 标记
   （防止钩子被上游合并掉却没人发现）。

用法（仓库根）：
    python support/scripts/aoci_check.py [-v]

退出码：0 = 通过；1 = 有问题。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AOCI = ROOT / 'aoci'

PATH_RE = re.compile(r'`([A-Za-z0-9_\-./]+?)(?::\d+(?:-\d+)?)?`')
VALID_ROOTS = ('app/', 'packages/', 'server/', 'cli/', 'support/', 'aoci/', 'fastlane/')
VALID_EXT = ('.dart', '.rs', '.json', '.yaml', '.yml', '.toml', '.md', '.sh', '.ps1', '.py', '.toml')


def iter_markdown():
    yield from sorted(AOCI.rglob('*.md'))


def check_paths(verbose: bool) -> list[str]:
    errors: list[str] = []
    checked = 0
    for md in iter_markdown():
        for line_no, line in enumerate(md.read_text(encoding='utf-8').splitlines(), 1):
            for match in PATH_RE.finditer(line):
                raw = match.group(1).rstrip('.,;')
                if '/' not in raw:
                    continue  # 短名引用（如 conversation_provider.dart:48）无法可靠定位，跳过
                if not raw.startswith(VALID_ROOTS):
                    continue
                is_dir = raw.endswith('/')
                if not is_dir and not raw.endswith(VALID_EXT):
                    continue
                target = ROOT / raw
                checked += 1
                ok = target.is_dir() if is_dir else target.is_file()
                if not ok:
                    rel = md.relative_to(ROOT).as_posix()
                    errors.append(f'{rel}:{line_no}  路径不存在 -> {raw}')
                elif verbose:
                    print(f'  ok  {raw}')
    if verbose:
        print(f'[路径] 检查 {checked} 处引用')
    return errors


def fork_table_files(index_md: Path) -> list[str]:
    """从 `## fork 插入点` 表格里抽出第一列的文件路径。"""
    text = index_md.read_text(encoding='utf-8')
    match = re.search(r'^##\s*fork 插入点\s*$(.*?)(?=^##\s|\Z)', text, re.M | re.S)
    if not match:
        return []
    files = []
    for line in match.group(1).splitlines():
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if not cells:
            continue
        first = cells[0].strip('`')
        if first.startswith(VALID_ROOTS) and first.endswith(VALID_EXT):
            files.append(first)
    return files


def check_fork_markers(verbose: bool) -> list[str]:
    index_md = AOCI / 'index.md'
    if not index_md.is_file():
        return ['aoci/index.md 缺失，无法校验 fork 插入点']
    declared = fork_table_files(index_md)
    if not declared:
        return ['aoci/index.md 未找到 "## fork 插入点" 表格或表格为空']

    errors: list[str] = []
    for rel in declared:
        path = ROOT / rel
        if not path.is_file():
            errors.append(f'fork 插入点文件不存在 -> {rel}')
            continue
        if '[FORK]' not in path.read_text(encoding='utf-8', errors='ignore'):
            errors.append(f'fork 插入点已无 [FORK] 标记（可能被上游合并覆盖）-> {rel}')
        elif verbose:
            print(f'  ok  {rel}')

    # 反向检查：有标记但没登记的文件，只提示不报错（新钩子可能还没补文档）
    actual = {
        p.relative_to(ROOT).as_posix()
        for p in (ROOT / 'app' / 'lib').rglob('*.dart')
        if '[FORK]' in p.read_text(encoding='utf-8', errors='ignore')
    }
    unlisted = sorted(actual - set(declared))
    if unlisted:
        print(f'[提示] {len(unlisted)} 个含 [FORK] 的文件未登记到 index.md：')
        for item in unlisted:
            print(f'       - {item}')
    if verbose:
        print(f'[FORK] 已登记 {len(declared)} 个，实际含标记 {len(actual)} 个')
    return errors


def main() -> int:
    verbose = '-v' in sys.argv or '--verbose' in sys.argv
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')

    if not AOCI.is_dir():
        print('aoci/ 目录不存在')
        return 1

    errors = check_paths(verbose) + check_fork_markers(verbose)
    if errors:
        print(f'\n发现 {len(errors)} 个问题：')
        for err in errors:
            print(f'  [X] {err}')
        return 1

    print('\nAOCI 校验通过')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
