#!/usr/bin/env python3
"""Assert that every susfs guard sits in the function it belongs to.

usage: assert_guard_sites.py <common-kernel-root>

apply_susfs.sh already checks that the susfs symbols reached the tree. That
catches a hunk that was dropped; it cannot catch one that was PLACED WRONGLY,
which is the failure mode of re-anchoring a hunk whose context no longer fits.
A guard in the wrong function links, boots, and quietly does nothing -- the same
class of bug apply_nomount_stack.sh documents for `patch` fuzz, where
ghost_notdir landed in path_parentat() instead of path_lookupat() on four kernel
versions with every check green.

So each site below names the function the guard has to be inside. A needle that
is absent from the file is not checked here (dropping a hunk is a different
failure, and some sites exist only on some kernel versions); a needle that is
present and NOT inside its function fails the build, and so does a function we
cannot locate, because an unverifiable site is a check that is not running.

`ph_<name>` counts as `<name>`. NoMount's pathhide takes the real body of
show_smap() and show_map() on 5.10/5.15/6.1 and renames it ph_show_smap() /
ph_show_map(), leaving a thin wrapper under the original name that guards and
then tail-calls it. susfs's guard belongs in the body, so that is where the
surgery puts it, and asserting the literal name fails 12 of the 26 matrix
targets on a tree that is in fact correct. 6.6 and 6.12 keep the single
function, so both shapes have to pass.
"""
import io
import re
import sys

# (file, function, needle)
SITES = [
    ('fs/proc/task_mmu.c', 'show_map_vma', 'susfs_sus_kstat_spoof_show_map_vma'),
    ('fs/proc/task_mmu.c', 'show_smap', 'SUSFS_IS_INODE_SUS_MAP'),
    ('fs/proc/task_mmu.c', 'show_smaps_rollup', 'bypass_orig_flow'),
    ('fs/proc/base.c', 'proc_map_files_readdir', 'SUSFS_IS_INODE_SUS_MAP'),
    ('fs/namei.c', 'do_o_path', 'susfs_open_redirect_spoof_do_sys_openat'),
    ('fs/stat.c', 'vfs_statx', 'ksu_handle_stat'),
]


def strip_noise(s):
    """Blank out comments and string/char literals, keeping length and newlines,
    so brace matching cannot be thrown by a brace inside either."""
    out = list(s)
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            j = s.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif c == '/' and i + 1 < n and s[i + 1] == '/':
            j = s.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            j = min(j + 1, n)
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def definition_span(clean, name):
    """Byte span of `name`'s function body, or None.

    A definition is `name(...)` whose closing paren is followed -- past
    whitespace and any attribute-free noise -- by `{`. That is what separates it
    from a prototype (`;` follows) and from a call site (`;`, `)` or `,` follows),
    without caring whether the brace is on its own line.
    """
    for m in re.finditer(r'\b' + re.escape(name) + r'\s*\(', clean):
        i, depth = m.end() - 1, 0
        while i < len(clean):
            if clean[i] == '(':
                depth += 1
            elif clean[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        else:
            continue
        j = i + 1
        while j < len(clean) and clean[j] in ' \t\n':
            j += 1
        if j >= len(clean) or clean[j] != '{':
            continue
        depth, k = 0, j
        while k < len(clean):
            if clean[k] == '{':
                depth += 1
            elif clean[k] == '}':
                depth -= 1
                if depth == 0:
                    return m.start(), k + 1
            k += 1
    return None


def functions_containing(clean, raw, needle):
    """Every function definition whose body holds `needle`. Only used to say
    where a misplaced guard actually went -- a guess is worse than a list."""
    out = []
    for m in re.finditer(r'^[A-Za-z_][A-Za-z0-9_ \t*]*\b([a-z_][a-z0-9_]*)\s*\(',
                         clean, re.M):
        sp = definition_span(clean, m.group(1))
        if sp and needle in raw[sp[0]:sp[1]] and m.group(1) not in out:
            out.append(m.group(1))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = sys.argv[1].rstrip('/')
    bad, checked = [], 0
    for path, func, needle in SITES:
        try:
            raw = io.open(root + '/' + path, encoding='utf-8', errors='replace').read()
        except IOError:
            continue
        if needle not in raw:
            continue
        clean = strip_noise(raw)
        names = [func, 'ph_' + func]
        spans = [(n, definition_span(clean, n)) for n in names]
        found = [(n, sp) for n, sp in spans if sp]
        if not found:
            bad.append('%s: cannot locate %s(), so %r cannot be verified'
                       % (path, '() or '.join(names), needle))
            continue
        checked += 1
        hit = next(((n, sp) for n, sp in found if needle in raw[sp[0]:sp[1]]), None)
        if hit:
            print('   guard site: %s %s() carries %s' % (path, hit[0], needle))
        else:
            bad.append('%s: %r is in the file but in none of %s -- it is in %s'
                       % (path, needle, ', '.join('%s()' % n for n, _ in found),
                          ', '.join('%s()' % n for n in functions_containing(clean, raw, needle))
                          or 'no function at all'))
    for line in bad:
        print('::error::apply_susfs: ' + line)
    if bad:
        return 1
    print('   %d guard site(s) verified in-function' % checked)
    return 0


if __name__ == '__main__':
    sys.exit(main())
