#!/usr/bin/env python3
"""Extract localization keys from the CleanMac sources and emit the catalog.

    .verify/genstrings.py                 # audit only
    .verify/genstrings.py --write         # rewrite Localizable.xcstrings

Why this exists rather than relying on Xcode's extractor: `SWIFT_EMIT_LOC_STRINGS`
only harvests keys from `LocalizedStringKey` *literals*, and this app routes
nearly all of its copy through `L10n.string(...)` calls computed at runtime.
The catalog therefore has to be generated from the call sites themselves.

Unlike a line-based grep this walks whole files with a Swift-literal-aware
scanner, so it copes with keys wrapped onto a continuation line, nested quotes
inside string interpolation (`\\(x ?? "")`), and comments that merely mention
`L10n`. It also reports *dynamic* keys -- call sites whose first argument is
not a string literal -- because those can never be captured in a table and are
either a bug or a deliberate machine string that should not be translated.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC_DIR = os.path.join(ROOT, 'CleanMac')
CATALOG = os.path.join(SRC_DIR, 'Resources', 'Localizable.xcstrings')
CALL = re.compile(r'\bL10n\s*\.\s*(string|plural|verbatim)\s*\(')
# Only `%@`, positional `%1$@` and the literal `%%` are legal in this codebase.
# A numeric specifier (`%lld`, `%.1f`, ...) paired with a Swift `Int` or
# `Double` argument reads an object pointer and dies with SIGSEGV at runtime
# with no compile error, so the audit rejects them outright.
SPEC_OK = re.compile(r'%(?:\d+\$)?@|%%')
ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '\\': '\\', '"': '"', "'": "'"}


def skip_string(src, i):
    """Index just past the string literal that starts at src[i] == '"'."""
    n = len(src)
    i += 1
    while i < n:
        c = src[i]
        if c == '\\':
            i += 2
            continue
        if c == '"':
            return i + 1
        if src.startswith('\\(', i):          # interpolation hole: nested Swift
            depth, i = 0, i + 1
            while i < n:
                if src[i] == '(':
                    depth += 1
                elif src[i] == ')':
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                elif src[i] == '"':
                    i = skip_string(src, i)
                    continue
                i += 1
            continue
        i += 1
    return n


def strip_comments(src):
    """Blank out comments, preserving offsets so line numbers stay truthful."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        if src[i] == '"':
            i = skip_string(src, i)
        elif src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if src[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def read_literal(src, i):
    if i >= len(src) or src[i] != '"':
        return None, i
    j = skip_string(src, i)
    return src[i:j], j


def unescape(raw):
    body = raw[1:-1]
    out, i = [], 0
    while i < len(body):
        if body[i] == '\\' and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt == '(':                    # keep interpolation text verbatim
                depth, k = 0, i + 1
                while k < len(body):
                    if body[k] == '(':
                        depth += 1
                    elif body[k] == ')':
                        depth -= 1
                        if depth == 0:
                            break
                    k += 1
                out.append(body[i:k + 1])
                i = k + 1
                continue
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
            continue
        out.append(body[i])
        i += 1
    return ''.join(out)


def skip_ws(src, i):
    while i < len(src) and src[i] in ' \t\r\n':
        i += 1
    return i


def split_args(src, i):
    """Split a call's argument list. `i` is the index of the opening paren.

    Returns (arguments, index_after_close). Only commas at the call's own
    nesting level separate arguments, and string literals are copied across
    whole so that a comma or paren inside one -- or inside an interpolation
    hole -- cannot split the list in the wrong place. The outer parens are
    not part of any argument.
    """
    n = len(src)
    if i >= n or src[i] != '(':
        return [], i
    i += 1
    depth, args, cur = 1, [], []
    while i < n:
        c = src[i]
        if c == '"':
            j = skip_string(src, i)
            cur.append(src[i:j])
            i = j
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                args.append(''.join(cur))
                return args, i + 1
        elif c == ',' and depth == 1:
            args.append(''.join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    return args, n


def literal_of(arg):
    """The unescaped value of `arg` if it is a bare string literal, else None."""
    arg = arg.strip()
    if not arg.startswith('"'):
        return None
    raw, end = read_literal(arg, 0)
    if raw is None or end != len(arg):
        return None           # trailing junk: a compound expression, not a key
    if '\\(' in raw:
        return None           # interpolated key: value is decided at runtime
    return unescape(raw)


def bad_specs(key):
    """Every `%` that does not begin a permitted conversion specifier."""
    bad, i = [], 0
    while i < len(key):
        if key[i] == '%':
            m = SPEC_OK.match(key, i)
            if m:
                i = m.end()
                continue
            bad.append(key[i:i + 4])
        i += 1
    return bad


def collect():
    keys, dynamic, verbatim = {}, [], []
    for dirpath, _, filenames in os.walk(SRC_DIR):
        filenames.sort()
        for fn in filenames:
            if not fn.endswith('.swift'):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT)
            src = open(path, encoding='utf-8').read()
            clean = strip_comments(src)
            for m in CALL.finditer(clean):
                kind = m.group(1)
                line = clean.count('\n', 0, m.start()) + 1
                open_paren = skip_ws(clean, m.end() - 1)
                args, _ = split_args(clean, open_paren)
                # `string` and `plural` take their key(s) first; `plural` looks
                # up BOTH forms at runtime, so both must reach the catalog.
                # `verbatim` is counted but is deliberately never a key.
                slots = {'string': 1, 'plural': 2, 'verbatim': 1}[kind]
                for slot in range(slots):
                    arg = args[slot] if slot < len(args) else ''
                    # `verbatim` never contributes a key, and a non-literal
                    # argument there is the normal case (a path, an app name).
                    if kind == 'verbatim':
                        verbatim.append((rel, line, ' '.join(arg.split())))
                        continue
                    key = literal_of(arg)
                    if key is None:
                        snip = ' '.join((arg or src[m.start():m.start() + 70]).split())
                        dynamic.append((rel, line, kind, slot, snip))
                        continue
                    e = keys.setdefault(key, {'files': set(), 'kind': kind, 'uses': 0})
                    e['files'].add(rel)
                    e['uses'] += 1
    return keys, dynamic, verbatim


def write_catalog(keys):
    """Natural keys: the English text IS the key, so every entry's value equals
    its own key. That is not redundant -- it is what makes an untranslated
    entry correct, and what lets a translator see the source inline."""
    strings = {}
    for key in sorted(keys):
        strings[key] = {
            'extractionState': 'manual',
            'localizations': {
                'en': {'stringUnit': {'state': 'translated', 'value': key}}
            },
        }
    doc = {'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write('\n')


def main(argv):
    keys, dynamic, verbatim = collect()
    bad = [(k, bad_specs(k)) for k in keys if bad_specs(k)]
    empty = [k for k in keys if k.strip() == '']

    print('catalog            :', os.path.relpath(CATALOG, ROOT))
    print('distinct keys      :', len(keys))
    print('verbatim() sites   :', len(verbatim))
    print('dynamic keys       :', len(dynamic))
    for p, l, k, slot, s in dynamic:
        print('   %s:%d L10n.%s arg#%d  %s' % (p, l, k, slot, s))
    print('illegal %% specs    :', len(bad))
    for k, b in bad:
        print('   %r -> %r' % (k, b))
    print('empty keys         :', len(empty))

    if '--write' in argv:
        # Refuse to clobber a good catalog on a parse failure. A key that is
        # not a bare literal is either a genuine bug or a scanner regression;
        # writing anyway would silently delete every key it failed to read.
        if dynamic:
            print('refusing to write: %d unresolved key(s)' % len(dynamic))
            return 1
        write_catalog(keys)
        print('wrote %d entries' % len(keys))

    # Parity with whatever catalog is on disk, so drift is caught by CI.
    if os.path.exists(CATALOG):
        on_disk = set(json.load(open(CATALOG, encoding='utf-8'))
                      .get('strings', {}))
        missing = sorted(set(keys) - on_disk)
        stale = sorted(on_disk - set(keys))
        print('catalog entries    :', len(on_disk))
        print('missing from catalog:', len(missing))
        for k in missing[:20]:
            print('   -', repr(k))
        print('stale in catalog   :', len(stale))
        for k in stale[:20]:
            print('   -', repr(k))
        if missing or stale:
            return 1
    return 1 if (bad or empty) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
