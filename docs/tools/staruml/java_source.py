"""Reads the logical model - packages, classes, interfaces, enums, records, their
attributes, operations and dependencies - from Java sources, nested types included.

A class is a dict:
  name      key (Name, Outer.Inner, or pkg.Name when the simple name is in two packages)
  display   Name or Outer.Inner
  pkg       package relative to the base package ('' for the base package itself)
  kind      class | interface | enum | record
  abstract, final, doc, extends, implements, members, deps, imports, outer, src

`manual_classes()` turns classes described by hand in uml_config.py (for a
language the generator doesn't read) into the same dicts.
"""
import os
import re

LEXEME = re.compile(r'"""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])+\'|/\*.*?\*/|//[^\n]*', re.S)

MODIFIERS = {'public', 'protected', 'private', 'static', 'final', 'abstract', 'default',
             'synchronized', 'sealed', 'non-sealed', 'native', 'transient', 'volatile', 'strictfp'}

DECL = re.compile(r'(?:^|(?<=[;{}\s]))((?:(?:public|protected|private|static|final|abstract|sealed|non-sealed)\s+)*)'
                  r'(class|interface|record|enum)\s+(\w+)')

SKIPPED_DIRS = {'target', 'build', 'node_modules', '.git', '.idea', 'out', 'bin', 'generated', 'generated-sources'}


def strip_code(s):
    """The code without comments, with every string, text block and char literal emptied - in a single
    pass, so that "ws://…" is a string and not a comment, and a brace in a literal doesn't count."""
    def blank(m):
        t = m.group(0)
        if t.startswith('/*'):
            return ' ' * len(t)
        if t.startswith('//'):
            return ''
        return '\'\'' if t.startswith("'") else '""'
    return LEXEME.sub(blank, s)


def javadoc_before(raw, pos):
    """First paragraph of the Javadoc right before `pos`, as plain text."""
    before = raw[:pos].rstrip()
    before = re.sub(r'(@\w+(\([^)]*\))?\s*)+$', '', before).rstrip()
    m = re.search(r'/\*\*(.*?)\*/\s*$', before, re.S)
    if not m:
        return ''
    text = re.sub(r'^\s*\*\s?', '', m.group(1), flags=re.M).strip()
    text = text.split('\n\n')[0]
    text = re.sub(r'</?(p|b|i|em|strong|code|ul|ol|li|br|pre)\s*/?>', '', text)
    text = re.sub(r'\{@(?:link|linkplain|code)\s+([^}]*)\}', r'\1', text)
    return ' '.join(text.split())


def split_top(s, sep=','):
    """Splits on `sep` outside <>, () and []."""
    out, depth, buf = [], 0, ''
    for ch in s:
        if ch in '<([{':
            depth += 1
        elif ch in '>)]}':
            depth -= 1
        if ch == sep and depth == 0:
            out.append(buf)
            buf = ''
        else:
            buf += ch
    if buf.strip():
        out.append(buf)
    return [x.strip() for x in out]


def without_generics(s):
    """`s` without its type parameters and arguments: Foo<T extends Bar<U>> -> Foo."""
    prev = None
    while prev != s:
        prev, s = s, re.sub(r'<[^<>]*>', '', s)
    return s


def members_of(body):
    """Yields the depth-1 declarations of a type body (method bodies skipped)."""
    depth, seg, pending_field = 0, '', False
    for ch in body:
        if ch == '{':
            if depth == 0:
                if '=' in seg.split('(')[0] or pending_field or re.search(r'=\s*$', seg):
                    pending_field = True          # field initializer block / anonymous class
                else:
                    yield ('block', seg)
                    seg = ''
            depth += 1
        elif ch == '}':
            depth -= 1
        elif depth == 0:
            if ch == ';':
                yield ('stmt', seg)
                seg = ''
                pending_field = False
            else:
                seg += ch


def parse_decl(seg, kind, cls_name):
    seg = re.sub(r'@\w+(\.\w+)*(\([^)]*\))?', ' ', seg)
    seg = ' '.join(seg.split())
    if not seg or re.match(r'(.*\s)?(class|interface|enum|record)\s+\w+', seg.split('(')[0]):
        return None
    words = seg.split(' ')
    mods = set()
    while words and words[0] in MODIFIERS:
        mods.add(words.pop(0))
    rest = ' '.join(words)
    if kind == 'interface':
        if not mods & {'private'}:
            mods.add('public')
        if '(' not in rest:
            mods |= {'static', 'final'}
        elif 'default' not in mods and 'static' not in mods:
            mods.add('abstract')
    vis = 'public' if 'public' in mods else 'protected' if 'protected' in mods else \
        'private' if 'private' in mods else 'package'
    m = re.match(r'(?:<[^()]*?>\s+)?(.*?)\b(\w+)\s*\((.*)\)\s*(throws [\w., ]+)?\s*$', rest)
    if m and '=' not in rest.split('(')[0]:
        rtype, name, params = m.group(1).strip(), m.group(2), m.group(3)
        if not rtype and name != cls_name:
            return None
        ps = []
        for p in split_top(params):
            p = re.sub(r'\bfinal\s+', '', p).strip()
            if not p or ' ' not in p:
                continue
            ptype, pname = p.rsplit(' ', 1)
            ps.append((pname, ptype.strip()))
        return {'kind': 'ctor' if not rtype else 'op', 'name': name, 'type': rtype, 'params': ps,
                'visibility': vis, 'static': 'static' in mods, 'abstract': 'abstract' in mods}
    m = re.match(r'(.+?)\s+(\w+)\s*(=.*)?$', rest)
    if m:
        return {'kind': 'field', 'name': m.group(2), 'type': m.group(1).strip(), 'visibility': vis,
                'static': 'static' in mods, 'final': 'final' in mods,
                'default': (m.group(3) or '').lstrip('= ').strip()}
    return None


def type_body(src, brace):
    """End index of the body opened at `brace`."""
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return len(src)


def enum_constants(body):
    """The constants part of an enum body: up to the first ';' at depth 0."""
    depth = 0
    for i, ch in enumerate(body):
        if ch in '({[':
            depth += 1
        elif ch in ')}]':
            depth -= 1
        elif ch == ';' and depth == 0:
            return body[:i], body[i + 1:]
    return body, ''


def parse_type(key, display, pkg, kind, mods, header, body, doc, src):
    """One classifier: its supertypes, record components and members."""
    simple = display.split('.')[-1]
    plain = without_generics(header)
    ext = re.search(r'\bextends\s+([\w., ]+?)(?=\s+implements|\s+permits|\s*$)', plain)
    impl = re.search(r'\bimplements\s+([\w., ]+?)(?=\s+permits|\s*$)', plain)
    comps = []
    if kind == 'record':
        rc = re.search(simple + r'\s*(?:<.*?>)?\s*\((.*?)\)\s*(implements|\{|$)', header, re.S)
        for c in split_top(rc.group(1)) if rc and rc.group(1).strip() else []:
            c = re.sub(r'@\w+(\.\w+)*(\([^)]*\))?', ' ', c).strip()
            if ' ' not in c:
                continue
            ctype, cname = c.rsplit(' ', 1)
            comps.append({'kind': 'field', 'name': cname, 'type': ctype.strip(), 'visibility': 'private',
                          'static': False, 'final': True, 'default': ''})
    members = []
    if kind == 'enum':
        consts, body = enum_constants(body)
        members += [{'kind': 'literal', 'name': re.match(r'\w+', c.strip()).group(0)}
                    for c in split_top(consts) if re.match(r'^\w+', c.strip())]
    for _, seg in members_of(body):
        decl = parse_decl(seg, kind, simple)
        if decl:
            members.append(decl)
    return {
        'name': key, 'display': display, 'pkg': pkg, 'kind': kind, 'abstract': 'abstract' in mods,
        'final': 'final' in mods,
        'extends': split_top(ext.group(1)) if ext else [],
        'implements': split_top(impl.group(1)) if impl else [],
        'members': comps + members, 'doc': doc, 'src': src,
    }


def java_files(source_roots):
    for root in source_roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = sorted(x for x in dirs if x not in SKIPPED_DIRS)
            for f in sorted(files):
                if f.endswith('.java') and f not in ('module-info.java', 'package-info.java'):
                    yield os.path.join(d, f)


def relative_package(full, base):
    if not base:
        return full
    if full == base:
        return ''
    return full[len(base) + 1:] if full.startswith(base + '.') else full


def read_classes(source_roots, base_package):
    """Every top-level type, and every non-private type nested in one (named Outer.Inner).
    A top-level name found in two packages is keyed pkg.Name, but displayed Name."""
    found = []
    for path in java_files(source_roots):
        name = os.path.basename(path)[:-5]
        raw = open(path, encoding='utf-8').read()
        src = strip_code(raw)
        pm = re.search(r'^\s*package\s+([\w.]+)\s*;', src, re.M)
        pkg = relative_package(pm.group(1) if pm else '', base_package)
        m = re.search(r'^[ \t]*(?:public\s+)?((?:[\w-]+\s+)*?)(class|interface|record|enum)\s+' + name + r'\b',
                      src, re.M)
        if not m:
            continue
        kind, mods = m.group(2), m.group(1)
        brace = src.index('{', m.end())
        end = type_body(src, brace)
        body = src[brace + 1:end]
        imports = re.findall(r'^import\s+(?:static\s+)?([\w.]+)\s*;', raw, re.M)
        top = len(found)
        found.append([name, name, pkg, kind, mods, src[m.start():brace], body, javadoc_before(raw, m.start()), src,
                      imports, None])
        own_src = src                     # the outer type's own text, without its nested types
        # nested types, at depth 0 of the body
        depth, dd = [0] * (len(body) + 1), 0
        for i, ch in enumerate(body):
            depth[i] = dd
            if ch == '{':
                dd += 1
            elif ch == '}':
                dd -= 1
        for n in DECL.finditer(body):
            if depth[n.start(2)] != 0 or 'private' in n.group(1) or '{' not in body[n.end():]:
                continue
            nb = body.index('{', n.end())
            nend = type_body(body, nb)
            own_src = own_src.replace(body[n.start(2):nend + 1], '')
            at = raw.find(body[n.start(2):nb].strip()[:40])
            found.append([f'{name}.{n.group(3)}', f'{name}.{n.group(3)}', pkg, n.group(2), n.group(1),
                          body[n.start(2):nb], body[nb + 1:nend], javadoc_before(raw, at) if at > 0 else '',
                          body[n.start(2):nend], imports, name])
        # an outer type contains its nested types: what they name is not its dependency
        found[top][8] = own_src
    counts = {}
    for t in found:
        counts[t[0]] = counts.get(t[0], 0) + 1
    classes = {}
    for key, display, pkg, kind, mods, header, body, doc, src, imports, outer in found:
        k = f'{pkg}.{key}' if counts[key] > 1 and pkg else key
        c = parse_type(k, display, pkg, kind, mods, header, body, doc, src)
        c['imports'], c['outer'] = imports, outer
        classes[k] = c
    compute_deps(classes, base_package)
    return classes


def compute_deps(classes, base_package):
    for c in classes.values():
        if 'deps' in c:
            continue
        # what the code names - not the import lines, which also serve the nested types
        code = re.sub(r'^\s*(?:import|package)\b[^;]*;', '', c['src'], flags=re.M)
        words = set(re.findall(r'\b([A-Z]\w*(?:\.[A-Z]\w*)?)\b', code))
        deps = set()
        for w in words:
            for part in ([w] + w.split('.')) if '.' in w else [w]:
                r = resolve(classes, part, c, base_package)
                if r and r != c['name']:
                    deps.add(r)
                    break
        if c['outer']:
            deps.discard(resolve(classes, c['outer'], c, base_package))
        # nor its own nested types: it contains them
        deps -= {k for k in deps if classes[k]['outer'] == c['display']}
        c['deps'] = sorted(deps)


def resolve(classes, word, ctx, base_package=''):
    """The class key that `word` (Name, Outer.Name or pkg.Name) designates from class `ctx`, or None."""
    if word in classes and ('.' in word or ctx is None):
        return word                                   # a key written out
    if ctx is None:
        cands = [k for k, c in classes.items() if c['display'] == word]
        return cands[0] if len(cands) == 1 else None
    outer = ctx.get('outer') or ctx['display'].split('.')[0]
    if f'{outer}.{word}' in classes:
        return f'{outer}.{word}'                      # a sibling nested type
    cands = [k for k, c in classes.items() if c['display'] == word or c['display'].endswith('.' + word)]
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0]
    top = [k for k in cands if classes[k]['display'] == word]
    same = [k for k in top if classes[k]['pkg'] == ctx['pkg']]
    if same:
        return same[0]
    prefix = base_package + '.' if base_package else ''
    for k in top:
        full = prefix + classes[k]['pkg'] if classes[k]['pkg'] else base_package
        if any(i == f'{full}.{word}' or i == f'{full}.*' for i in ctx.get('imports', [])):
            return k
    for k in cands:                                   # imported nested type (import …Outer.Name)
        if any(i.endswith('.' + classes[k]['display']) for i in ctx.get('imports', [])):
            return k
    return None


# ============================================================================ classes described by hand

def parse_member(text, kind):
    """'name: Type' -> field, 'name(p: T, q: U): R' -> operation, LITERAL -> enum literal."""
    text = text.strip()
    vis = {'+': 'public', '-': 'private', '#': 'protected', '~': 'package'}.get(text[:1])
    if vis:
        text = text[1:].strip()
    vis = vis or ('private' if kind == 'record' else 'public')
    m = re.match(r'^(\w+)\s*\((.*)\)\s*(?::\s*(.+))?$', text)
    if m:
        ps = []
        for p in split_top(m.group(2)):
            pn, _, pt = p.partition(':')
            ps.append((pn.strip(), pt.strip() or 'Object'))
        return {'kind': 'op', 'name': m.group(1), 'type': (m.group(3) or 'void').strip(), 'params': ps,
                'visibility': 'public' if kind != 'record' or vis == 'private' else vis,
                'static': False, 'abstract': kind == 'interface'}
    if kind == 'enum' and re.fullmatch(r'\w+', text):
        return {'kind': 'literal', 'name': text}
    n, _, t = text.partition(':')
    return {'kind': 'field', 'name': n.strip(), 'type': t.strip() or 'Object', 'visibility': vis,
            'static': False, 'final': kind == 'record', 'default': ''}


def manual_classes(described, relations, classes):
    """Adds to `classes` the MANUAL_CLASSES of uml_config.py:
    (package, name, kind, stereotype, [attributes], [operations], documentation),
    and their MANUAL_RELATIONS: (generalization | realization | dependency, source, target)."""
    for pkg, name, kind, stereo, attrs, ops, doc in described:
        record = stereo == 'record'
        members = [parse_member(a, 'record' if record else kind) for a in attrs]
        members += [parse_member(o, kind) for o in ops]
        classes[name] = {'name': name, 'display': name, 'pkg': pkg, 'kind': 'record' if record else kind,
                         'abstract': False, 'final': False, 'doc': doc, 'extends': [], 'implements': [],
                         'members': members, 'deps': [], 'imports': [], 'outer': None, 'src': '',
                         'stereotype': None if record else stereo}
    for kind, a, b in relations:
        c = classes[a]
        if kind == 'generalization':
            c['extends'].append(b)
        elif kind == 'realization':
            c['implements'].append(b)
        elif b not in c['deps']:
            c['deps'].append(b)
    return classes
