#!/usr/bin/env python3
"""Reconcile susfs4ksu's kernel-side patch with the tree being built.

usage: susfs_patch_surgery.py [--drop <file>]... <patch> <tree-root> [<file:hunk> ...]

--drop removes every hunk of that file from the patch: the tree keeps its own
version (selinuxfs.c, where the KSU side and NoMount already own the hiding).
Each <file:hunk> is a hunk `patch --dry-run` rejected. A rejected hunk is
dropped from the patch and its additions re-inserted into the tree. Two kinds
of drift are absorbed:

  * sublevel drift: susfs rebases the patch onto one GKI sublevel at a time,
    so a hunk's context may not exist on the sublevel being built. Those are
    handled by content-matched rules that know where the code belongs.
  * foreign insertions: a patch stack applied before susfs (NoMount) adds lines
    inside the same functions, which breaks the hunk's context without changing
    any line susfs anchors on. Purely additive hunks are re-applied by walking
    their context lines in order and skipping over the foreign lines.

Hunks are recognised by the content they add, never by @@ line numbers, which
every rebase renumbers. A reject with no resolution is a hard failure.
"""
import io
import re
import sys


def split_patch(text):
    out, pre, path, hunks, cur = [], [], None, [], None

    def flush():
        if path is not None:
            if cur:
                hunks.append(cur)
            out.append([pre, path, hunks])

    for line in text.split('\n'):
        if line.startswith('diff --git '):
            flush()
            pre, path, hunks, cur = [line], None, [], None
        elif line.startswith('+++ b/') and path is None:
            path = line[6:]
            pre.append(line)
        elif line.startswith('@@'):
            if cur:
                hunks.append(cur)
            cur = [line]
        elif cur is not None:
            cur.append(line)
        else:
            pre.append(line)
    flush()
    return out


def join_patch(sections):
    chunks = []
    for pre, _path, hunks in sections:
        chunks.append('\n'.join(pre))
        for h in hunks:
            chunks.append('\n'.join(h))
    return '\n'.join(chunks)


def body_lines(hunk):
    return [l for l in hunk[1:] if not l.startswith('\\')]


def added(hunk):
    return '\n'.join(l[1:] for l in body_lines(hunk) if l.startswith('+'))


def added_runs(hunk):
    runs, cur = [], []
    for l in body_lines(hunk):
        if l.startswith('+'):
            cur.append(l[1:])
        elif cur:
            runs.append('\n'.join(cur))
            cur = []
    if cur:
        runs.append('\n'.join(cur))
    return runs


def has_deletions(hunk):
    return any(l.startswith('-') and l[1:].strip() for l in body_lines(hunk))


def read(path):
    return io.open(path, encoding='utf-8').read()


def write(path, s):
    io.open(path, 'w', encoding='utf-8').write(s)


GUARD_MAP = '#ifdef CONFIG_KSU_SUSFS_SUS_MAP'
ENDIF_MAP = '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP'


def function_span(s, name):
    m = re.search(r'^[^\n;]*\b' + re.escape(name) + r'\s*\([^;{}]*\)\s*\n\{\n', s, re.M)
    if not m:
        return None
    start = m.end()
    end = s.find('\n}\n', start)
    if end < 0:
        return None
    return start, end + 1


def insert_after_include(path, marker, anchors, block):
    s = read(path)
    if marker in s:
        return 'already present'
    for anchor in anchors:
        if s.count(anchor) == 1:
            write(path, s.replace(anchor, anchor + block, 1))
            return 'inserted after ' + anchor.strip()
    return None


def insert_exec_include(tree):
    return insert_after_include(
        tree + '/fs/exec.c', 'susfs_def.h',
        ['#include <linux/ksm.h>\n', '#include <linux/rseq.h>\n'],
        '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n')


def insert_memory_include(tree):
    return insert_after_include(
        tree + '/mm/memory.c', 'susfs_def.h',
        ['#include <linux/vmalloc.h>\n', '#include <linux/mm.h>\n'],
        GUARD_MAP + '\n#include <linux/susfs_def.h>\n' + ENDIF_MAP + '\n')


def insert_show_smap_guard(tree):
    path = tree + '/fs/proc/task_mmu.c'
    s = read(path)
    span = function_span(s, 'show_smap')
    if not span:
        return None
    a, b = span
    body = s[a:b]
    if 'SUSFS_IS_INODE_SUS_MAP' in body:
        return 'already present'
    hits = list(re.finditer(r'^\tif \(!vma_(?:data_)?pages\(vma\)\)$', body, re.M))
    if len(hits) != 1:
        return None
    block = (GUARD_MAP + '\n'
             '\tif (vma->vm_file) {\n'
             '\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n'
             '\t\t\treturn 0;\n'
             '\t}\n'
             + ENDIF_MAP + '\n\n')
    i = hits[0].start()
    write(path, s[:a] + body[:i] + block + body[i:] + s[b:])
    return 'inserted before the vma_pages() check in show_smap()'


def insert_rollup_bypass(tree):
    path = tree + '/fs/proc/task_mmu.c'
    s = read(path)
    span = function_span(s, 'show_smaps_rollup')
    if not span:
        return None
    a, b = span
    body = s[a:b]
    if 'bypass_orig_flow' in body:
        return 'already present'
    loop = '\n\tdo {\n'
    gather = '\n\t\tsmap_gather_stats(vma, &mss, 0);\n'
    i = body.find(loop)
    if i < 0 or body.find(loop, i + 1) >= 0:
        return None
    j = body.find(gather, i)
    if j < 0 or body.find(gather, j + 1) >= 0:
        return None
    k = j + len(gather)
    body = body[:k] + GUARD_MAP + '\nbypass_orig_flow:\n' + ENDIF_MAP + '\n' + body[k:]
    i += len(loop)
    body = (body[:i] + GUARD_MAP + '\n'
            '\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n'
            '\t\t\tgoto bypass_orig_flow;\n' + ENDIF_MAP + '\n' + body[i:])
    write(path, s[:a] + body + s[b:])
    return 'inserted at the show_smaps_rollup() loop head'


RULES = [
    ('fs/exec.c', '#include <linux/susfs_def.h>', insert_exec_include),
    ('mm/memory.c', '#include <linux/susfs_def.h>', insert_memory_include),
    ('fs/proc/task_mmu.c', 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;', insert_show_smap_guard),
    ('fs/proc/task_mmu.c', 'goto bypass_orig_flow;', insert_rollup_bypass),
    ('fs/proc/task_mmu.c', 'bypass_orig_flow:', insert_rollup_bypass),
]

WINDOW = 80


def reapply_additive(tree, path, hunk):
    if has_deletions(hunk):
        return None
    fpath = tree + '/' + path
    text = read(fpath)
    lines = text.split('\n')
    runs = added_runs(hunk)
    if runs and all(r in text for r in runs):
        return 'already present'
    body = body_lines(hunk)
    ctx = [l[1:] if l.startswith(' ') else l for l in body if not l.startswith('+') and not l.startswith('-')]
    if not ctx:
        return None
    old_start = int(re.match(r'@@ -(\d+)', hunk[0]).group(1)) - 1
    k = next((n for n, c in enumerate(ctx) if len(c.strip()) >= 8), 0)
    cands = [i for i, l in enumerate(lines) if l == ctx[k]]
    if not cands:
        return None
    cur = min(cands, key=lambda i: abs(i - (old_start + k)))
    for c in reversed(ctx[:k]):
        j = next((m for m in range(cur - 1, max(cur - WINDOW, -1), -1) if lines[m] == c), None)
        if j is None:
            return None
        cur = j
    out, i, pending = lines[:cur], cur, []
    for l in body:
        if l.startswith('+'):
            pending.append(l[1:])
            continue
        if l.startswith('-'):
            if i >= len(lines) or lines[i].strip():
                return None
            i += 1
            continue
        c = l[1:] if l.startswith(' ') else l
        if pending:
            out.extend(pending)
            pending = []
        j = next((k for k in range(i, min(i + WINDOW, len(lines))) if lines[k] == c), None)
        if j is None:
            return None
        out.extend(lines[i:j + 1])
        i = j + 1
    out.extend(pending)
    out.extend(lines[i:])
    new = '\n'.join(out)
    if not all(r in new for r in runs):
        return None
    write(fpath, new)
    return 'additions re-applied in context order from line %d' % (cur + 1)


def main():
    args, drop = [], set()
    it = iter(sys.argv[1:])
    for a in it:
        if a == '--drop':
            drop.add(next(it, ''))
        else:
            args.append(a)
    if len(args) < 2:
        sys.exit(__doc__)
    patch_path, tree = args[0], args[1].rstrip('/')
    wanted = set()
    for spec in args[2:]:
        f, _, n = spec.rpartition(':')
        wanted.add((f, int(n)))

    sections = split_patch(read(patch_path))
    done, failed = [], []

    for sec in sections:
        _pre, path, hunks = sec
        keep = []
        if path in drop:
            done.append('%s -> all %d hunk(s) dropped, this tree keeps its own' % (path, len(hunks)))
            sec[2] = keep
            continue
        for idx, hunk in enumerate(hunks, 1):
            if (path, idx) not in wanted:
                keep.append(hunk)
                continue
            content = added(hunk)
            seen, note = set(), None
            for p, marker, fn in RULES:
                if p == path and marker in content and fn not in seen:
                    seen.add(fn)
                    note = fn(tree)
                    if note is None:
                        break
            if note is None:
                note = reapply_additive(tree, path, hunk)
            if note is None:
                why = 'has deletions, cannot be re-applied' if has_deletions(hunk) else 'its context was not found in the tree'
                failed.append('%s hunk #%d: %s' % (path, idx, why))
                keep.append(hunk)
                continue
            done.append('%s hunk #%d -> %s' % (path, idx, note))
        sec[2] = keep

    for line in done:
        print('   reconciled: ' + line)
    for line in failed:
        print('   UNRESOLVED: ' + line)

    if failed:
        return 1

    write(patch_path, join_patch(sections))
    return 0


if __name__ == '__main__':
    sys.exit(main())
