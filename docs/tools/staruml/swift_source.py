"""Reads the logical model of a Swift project - types, members, conformances, dependencies -
together with its Metal shaders and the frameworks and Swift packages it uses.

A class is the same dict as in java_source.py (builder.py doesn't know the language):
  name      key (Name, Outer.Inner, or pkg.Name when the simple name is in two packages)
  display   Name or Outer.Inner
  pkg       package relative to the base package: the module (target), then its folders
  kind      class | interface | enum
  stereotype struct, actor, view, app, observable, metal, metal struct… (None for a plain class)
  abstract, final, doc, extends, implements, members, deps, imports, outer, src
Swift-only keys: frameworks (modules imported by its file), strings (string literals of its body),
file (path relative to the project root).

Mapping
  protocol -> interface ; enum -> enumeration ; class, struct, actor -> class (stereotype)
  extension of a project type -> its members and conformances are added to that type
  `: A, B` -> superclass (first item of a class, when A is a class) or realizations; marker
  protocols (Sendable, Equatable, Identifiable…) are left out (IGNORED_CONFORMANCES)
  private / fileprivate -> private ; internal, package, public, open -> public
  let -> read-only attribute ; static / class -> static ; init -> «create» operation
  .metal file -> class «metal» named <Stem>Shaders, kernel / vertex / fragment functions as
  operations, its structs as nested classes «metal struct» ; a Swift type that names a shader
  function in a string ("topple") or mirrors a shader struct (same name) depends on it.
"""
import os
import re

from java_source import split_top, without_generics, resolve

SKIPPED_DIRS = {'build', 'DerivedData', '.build', '.swiftpm', 'Pods', 'Carthage', 'node_modules', '.git',
                'docs', 'Docs', 'fastlane'}

# Conformances that say little about the design: left out of the diagrams
IGNORED_CONFORMANCES = {
    'Sendable', 'Equatable', 'Hashable', 'Identifiable', 'CaseIterable', 'Codable', 'Encodable', 'Decodable',
    'Comparable', 'CustomStringConvertible', 'CustomDebugStringConvertible', 'RawRepresentable',
    'BitwiseCopyable', 'Copyable', 'Escapable', 'AnyObject', 'Error', 'ExpressibleByStringLiteral',
    'ExpressibleByIntegerLiteral', 'ExpressibleByArrayLiteral', 'Strideable', 'Observable',
    # raw types of enums
    'String', 'Int', 'Int8', 'Int16', 'Int32', 'Int64', 'UInt', 'UInt8', 'UInt16', 'UInt32', 'UInt64',
    'Double', 'Float', 'Character', 'Bool',
}

# Framework classes a project class can inherit from (any other external supertype is a protocol)
KNOWN_SUPERCLASSES = {
    'NSObject', 'NSView', 'NSViewController', 'NSWindowController', 'NSWindow', 'NSDocument', 'NSResponder',
    'NSApplication', 'NSControl', 'NSImageView', 'NSTableCellView', 'MTKView', 'UIView', 'UIViewController',
    'UIResponder', 'UIApplication', 'UITableViewCell', 'UICollectionViewCell', 'CALayer', 'CAMetalLayer',
    'SKScene', 'SKNode', 'SKSpriteNode', 'SCNView', 'SCNNode', 'Operation', 'Thread', 'XCTestCase',
    'NSManagedObject', 'ARView', 'Entity',
}

# Conformances already told by the stereotype: not drawn as realizations
ROLE_ONLY = {'App', 'View', 'Scene', 'ViewModifier', 'Shape', 'Widget'}

# Stereotype given by a conformance or an attribute (first match wins, before struct / actor)
ROLE_CONFORMANCES = {'App': 'app', 'View': 'view', 'Scene': 'scene', 'NSViewRepresentable': 'view',
                     'UIViewRepresentable': 'view', 'ViewModifier': 'view modifier', 'Shape': 'shape',
                     'ObservableObject': 'observable', 'Widget': 'widget'}
ROLE_ATTRIBUTES = {'Observable': 'observable', 'Model': 'model', 'main': 'main'}

KEYWORDS = r'(?:class|struct|enum|protocol|actor|extension)'
MODS = r'(?:(?:public|open|internal|package|fileprivate|private|final|indirect|nonisolated|override|' \
       r'static|class|lazy|weak|unowned|mutating|nonmutating|convenience|required|dynamic|optional|' \
       r'distributed|consuming|borrowing)(?:\([\w]+\))?\s+)*'
ATTRS = r'(?:@[\w.]+(?:\((?:[^()]|\([^()]*\))*\))?\s*)*'

TYPE_DECL = re.compile(r'(' + ATTRS + r')(' + MODS + r')(' + KEYWORDS + r')\s+([A-Za-z_][\w.]*)([^{]*?)\{')
FUNC = re.compile(r'(' + ATTRS + r')(' + MODS + r')func\s+([^\s(<]+)\s*(<[^(]*?>)?\s*\(')
INIT = re.compile(r'(' + ATTRS + r')(' + MODS + r')(init[?!]?)\s*(<[^(]*?>)?\s*\(')
SUBSCRIPT = re.compile(r'(' + ATTRS + r')(' + MODS + r')subscript\s*\(')
PROP = re.compile(r'(' + ATTRS + r')(' + MODS + r')(var|let)\s+(\w+)\s*(?::\s*([^={\n;]+?))?\s*(=|\{|;|\n|$)')
CASE = re.compile(r'(?:indirect\s+)?case\s+([^\n]+)')


# ============================================================================ lexing

def lex(raw):
    """(code, strings): `code` is `raw` with comments blanked and string contents (interpolations
    included) replaced by spaces - same length, so positions match the raw text; `strings` are the
    string literals as (start, end, text)."""
    out = list(raw)
    strings = []
    i, n = 0, len(raw)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '

    while i < n:
        c = raw[i]
        if raw.startswith('//', i):
            j = raw.find('\n', i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif raw.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if raw.startswith('/*', j):
                    depth, j = depth + 1, j + 2
                elif raw.startswith('*/', j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == '#' and re.match(r'#+"', raw[i:])):
            hashes = len(re.match(r'#*', raw[i:]).group(0))
            q = i + hashes
            multi = raw.startswith('"""', q)
            delim = ('"""' if multi else '"') + '#' * hashes
            j = q + (3 if multi else 1)
            start = j
            text = []
            while j < n:
                if raw[j] == '\\' and raw.startswith('#' * hashes, j + 1):
                    k = j + 1 + hashes
                    if k < n and raw[k] == '(':          # interpolation: skip to the matching ')'
                        depth, k = 1, k + 1
                        while k < n and depth:
                            if raw[k] == '(':
                                depth += 1
                            elif raw[k] == ')':
                                depth -= 1
                            elif raw[k] == '"':          # nested string inside the interpolation
                                k2 = k + 1
                                while k2 < n and raw[k2] != '"':
                                    k2 += 2 if raw[k2] == '\\' else 1
                                k = k2
                            k += 1
                        j = k
                        continue
                    text.append(raw[j:k + 1])
                    j = k + 1
                    continue
                if raw.startswith(delim, j):
                    break
                if not multi and raw[j] == '\n':
                    break
                text.append(raw[j])
                j += 1
            strings.append((i, j, ''.join(text)))
            blank(start, j)
            i = j + len(delim)
        else:
            i += 1
    return ''.join(out), strings


def depths(code, a, b):
    """depth[i - a] = nesting depth of (), [] and {} at position i of code[a:b]."""
    d, out = 0, []
    for ch in code[a:b]:
        if ch in '{([':
            out.append(d)
            d += 1
        elif ch in '})]':
            d -= 1
            out.append(d)
        else:
            out.append(d)
    return out


def matching(code, i, open_ch='{', close_ch='}'):
    """Index of the bracket closing the one at i."""
    depth = 0
    for k in range(i, len(code)):
        if code[k] == open_ch:
            depth += 1
        elif code[k] == close_ch:
            depth -= 1
            if depth == 0:
                return k
    return len(code)


def doc_before(raw, pos):
    """First paragraph of the /// (or /** */) documentation right before the line of `pos`,
    attribute lines (@MainActor…) skipped."""
    line_start = raw.rfind('\n', 0, pos) + 1
    lines = raw[:line_start].split('\n')[:-1]
    block = []
    while lines:
        s = lines[-1].strip()
        if s.startswith('///'):
            block.insert(0, s[3:].strip())
            lines.pop()
        elif s.startswith('@') and not block:
            lines.pop()
        else:
            break
    if not block:
        m = re.search(r'/\*\*(.*?)\*/\s*$', '\n'.join(lines), re.S)
        if not m:
            return ''
        block = [re.sub(r'^\s*\*\s?', '', x) for x in m.group(1).split('\n')]
    text = '\n'.join(block).strip().split('\n\n')[0]
    text = re.sub(r'^\s*-\s+(Parameter|Returns|Throws).*$', '', text, flags=re.M)
    text = re.sub(r'``?([^`]+)``?', r'\1', text)
    return ' '.join(text.split())


# ============================================================================ members

def visibility(mods):
    if re.search(r'\b(private|fileprivate)\b(?!\()', mods):
        return 'private'
    return 'public'


def infer_type(default, attrs):
    """The type of a property declared without one: from its wrapper or initial value."""
    m = re.search(r'@\w+\(\s*([A-Z][\w.]*)\.self', attrs)
    if m:
        return m.group(1)
    d = default.strip()
    m = re.match(r'([A-Z][\w]*(?:<[^()]*>)?)\s*\(', d)
    if m:
        return m.group(1)
    if re.fullmatch(r'-?[\d_]+', d):
        return 'Int'
    if re.fullmatch(r'-?[\d_]*\.[\d_]+(e-?\d+)?', d):
        return 'Double'
    if re.fullmatch(r'-?[\d_]+\s*\.\.\.\s*-?[\d_]+', d):
        return 'ClosedRange<Int>'
    if re.fullmatch(r'-?[\d_]+\s*\.\.<\s*-?[\d_]+', d):
        return 'Range<Int>'
    if re.fullmatch(r'\[\s*-?[\d_]+(\s*,\s*-?[\d_]+)*\s*,?\s*\]', d):
        return '[Int]'
    if re.fullmatch(r'\[\s*"[^"]*"(\s*,\s*"[^"]*")*\s*,?\s*\]', d):
        return '[String]'
    if d in ('true', 'false'):
        return 'Bool'
    if d.startswith('"'):
        return 'String'
    m = re.match(r'\[\s*([A-Z]\w*)\s*\]\s*\(\)', d)
    if m:
        return f'[{m.group(1)}]'
    return ''


def parse_params(text):
    out = []
    for p in split_top(text):
        p = re.sub(r'@\w+(\([^)]*\))?\s*', '', p).strip()
        if ':' not in p:
            continue
        names, _, ptype = p.partition(':')
        ptype = ptype.split('=')[0].strip()
        words = names.split()
        name = words[0] if words and words[0] != '_' else (words[-1] if words else '')
        out.append((name, ptype))
    return out


def signature_tail(code, close):
    """Return type after the parameter list closed at `close`: '-> T' up to '{', 'where' or end of line."""
    rest = code[close + 1:]
    m = re.match(r'[^\n{]*', rest)
    tail = m.group(0)
    tail = re.split(r'\bwhere\b', tail)[0]
    r = re.search(r'->\s*(.+)$', tail)
    return r.group(1).strip() if r else 'void'


def type_members(code, raw, a, b, kind):
    """Members declared at depth 0 of the type body code[a:b], in source order."""
    dep = depths(code, a, b)
    found = []

    def top(m):
        return dep[m.start() - a] == 0 if a <= m.start() < b else False

    body = code
    for m in PROP.finditer(body, a, b):
        if not top(m):
            continue
        attrs, mods, kw, name, ptype, end = m.groups()
        if ptype and ptype.rstrip().endswith('{'):
            ptype = ptype.rstrip()[:-1]
        default = ''
        if end == '=':
            line_end = body.find('\n', m.end())
            default = body[m.end():line_end if line_end >= 0 else b]
            # up to a ';' or a '}' closing the enclosing body, outside brackets
            depth = 0
            for i, ch in enumerate(default):
                if ch in '([{':
                    depth += 1
                elif ch in ')]}':
                    if depth == 0:
                        default = default[:i]
                        break
                    depth -= 1
                elif ch == ';' and depth == 0:
                    default = default[:i]
                    break
        t = (ptype or '').strip() or infer_type(default, attrs)
        static = bool(re.search(r'\b(static|class)\b', mods))
        found.append((m.start(), {'kind': 'field', 'name': name, 'type': t, 'visibility': visibility(mods),
                                  'static': static, 'final': kw == 'let', 'default': default.strip()[:40]}))
    for rx, kind_name in ((FUNC, 'op'), (INIT, 'ctor'), (SUBSCRIPT, 'op')):
        for m in rx.finditer(body, a, b):
            if not top(m):
                continue
            mods = m.group(2)
            open_paren = m.end() - 1
            close = matching(body, open_paren, '(', ')')
            params = parse_params(body[open_paren + 1:close])
            if kind_name == 'ctor':
                name, rtype = 'init', ''
            elif rx is SUBSCRIPT:
                name, rtype = 'subscript', signature_tail(body, close)
            else:
                name, rtype = m.group(3), signature_tail(body, close)
            found.append((m.start(), {'kind': kind_name, 'name': name, 'type': rtype, 'params': params,
                                      'visibility': visibility(mods),
                                      'static': bool(re.search(r'\b(static|class)\b', mods)),
                                      'abstract': kind == 'interface'}))
    if kind == 'enum':
        for m in CASE.finditer(body, a, b):
            if not top(m):
                continue
            for item in split_top(m.group(1)):
                lm = re.match(r'`?(\w+)`?', item)
                if lm:
                    found.append((m.start(), {'kind': 'literal', 'name': lm.group(1)}))
    found.sort(key=lambda x: x[0])
    return [m for _, m in found]


# ============================================================================ files

def swift_files(roots):
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = sorted(x for x in dirs if x not in SKIPPED_DIRS and not x.startswith('.')
                             and not x.endswith(('.xcodeproj', '.xcassets', '.xcworkspace')))
            for f in sorted(files):
                if f.endswith(('.swift', '.metal')) and f != 'Package.swift':
                    yield root, os.path.join(d, f)


def package_of(root, path, modules, base):
    module = modules.get(root) or os.path.basename(os.path.normpath(root))
    sub = os.path.relpath(os.path.dirname(path), root)
    parts = [module] + ([] if sub == '.' else [re.sub(r'\W', '_', p) for p in sub.split(os.sep)])
    full = '.'.join(parts)
    if not base:
        return full
    if full == base:
        return ''
    return full[len(base) + 1:] if full.startswith(base + '.') else full


def conformances(header):
    """Names after ':' in a type header, without generics or where clause."""
    h = without_generics(header)
    h = re.split(r'\bwhere\b', h)[0]
    if ':' not in h:
        return []
    names = []
    for item in split_top(h.split(':', 1)[1]):
        item = item.strip()
        for part in item.split('&'):          # protocol composition
            part = re.sub(r'^@\w+\s+', '', part.strip())   # @unchecked Sendable, @MainActor P
            if re.fullmatch(r'[\w.]+', part):
                names.append(part)
    return names


def read_swift_file(root, path, modules, base, project_root, found, extensions):
    raw = open(path, encoding='utf-8', errors='replace').read()
    code, strings = lex(raw)
    pkg = package_of(root, path, modules, base)
    frameworks = sorted(set(re.findall(r'^\s*(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|'
                                       r'var|let|typealias)\s+)?(\w+)', code, re.M)))
    rel = os.path.relpath(path, project_root)

    def visit(a, b, outer, outer_private):
        """Type declarations at depth 0 of code[a:b]."""
        dep = depths(code, a, b)
        for m in TYPE_DECL.finditer(code, a, b):
            if dep[m.start(3) - a] != 0:
                continue
            attrs, mods, kw, name, header = m.groups()
            if name in ('func', 'var', 'let', 'subscript', 'init'):
                continue                       # class func / class var
            brace = m.end() - 1
            end = matching(code, brace)
            private = outer_private or visibility(mods) == 'private'
            body_strings = [s for s in strings if brace < s[0] < end]
            if kw == 'extension':
                extensions.append({'target': name, 'header': header, 'code': code, 'raw': raw,
                                   'a': brace + 1, 'b': end, 'frameworks': frameworks, 'strings': body_strings,
                                   'pkg': pkg, 'file': rel})
                visit(brace + 1, end, name, False)
                continue
            display = f'{outer}.{name}' if outer else name
            kind = {'protocol': 'interface', 'enum': 'enum'}.get(kw, 'class')
            confs = conformances(header)
            stereo = None
            for c in confs:
                if c in ROLE_CONFORMANCES:
                    stereo = ROLE_CONFORMANCES[c]
                    break
            if not stereo:
                for at in re.findall(r'@(\w+)', attrs):
                    if at in ROLE_ATTRIBUTES:
                        stereo = ROLE_ATTRIBUTES[at]
                        break
            if not stereo and kw in ('struct', 'actor'):
                stereo = kw
            # own source: the body without nested type bodies
            own = code[m.start():end + 1]
            for n in TYPE_DECL.finditer(code, brace + 1, end):
                if n.group(3) != 'extension' and n.group(4) not in ('func', 'var', 'let'):
                    nb = n.end() - 1
                    own = own.replace(code[n.start():matching(code, nb) + 1], '')
            found.append({
                'key': display, 'display': display, 'pkg': pkg, 'kind': kind, 'stereotype': stereo,
                'abstract': False, 'final': bool(re.search(r'\bfinal\b', mods)) or kw in ('struct', 'enum'),
                'doc': doc_before(raw, m.start()),
                'conformances': confs, 'is_class': kw == 'class',
                'members': type_members(code, raw, brace + 1, end, kind),
                'src': own, 'frameworks': frameworks, 'strings': body_strings, 'outer': outer,
                'private': private, 'file': rel, 'imports': [],
            })
            visit(brace + 1, end, display, private)

    visit(0, len(code), None, False)


METAL_FUNC = re.compile(r'(?:\[\[\s*(kernel|vertex|fragment|visible|object|mesh)\s*\]\]|'
                        r'\b(kernel|vertex|fragment))\s+([\w:<>,\s]+?)\s+(\w+)\s*\(')
METAL_STRUCT = re.compile(r'\bstruct\s+(\w+)\s*\{')


def metal_params(text):
    out = []
    for p in split_top(text):
        binding = re.search(r'\[\[\s*([^\]]+?)\s*\]\]', p)
        p = re.sub(r'\[\[[^\]]*\]\]', '', p).strip()
        m = re.match(r'(.*?)([\w]+)\s*$', p)
        if not m:
            continue
        ptype = ' '.join(m.group(1).replace('*', ' * ').replace('&', ' & ').split()).replace(' *', '*') \
            .replace(' &', '&')
        if binding:
            ptype += f' [{binding.group(1)}]'
        out.append((m.group(2), ptype))
    return out


def read_metal_file(root, path, modules, base, project_root, found, name_pattern):
    raw = open(path, encoding='utf-8', errors='replace').read()
    code, _ = lex(raw)
    pkg = package_of(root, path, modules, base)
    stem = os.path.splitext(os.path.basename(path))[0]
    cname = name_pattern.format(stem=re.sub(r'\W', '', stem))
    rel = os.path.relpath(path, project_root)
    # File doc: the leading // comment block, after #include / using lines
    lead = []
    for line in raw.split('\n'):
        s = line.strip()
        if s.startswith('//'):
            lead.append(s.lstrip('/ ').strip())
        elif s and not s.startswith(('#', 'using')) and lead:
            break
        elif s and not s.startswith(('#', 'using')):
            break
    members = []
    for m in METAL_FUNC.finditer(code):
        role = m.group(1) or m.group(2)
        open_paren = m.end() - 1
        close = matching(code, open_paren, '(', ')')
        members.append({'kind': 'op', 'name': m.group(4), 'type': ' '.join(m.group(3).split()),
                        'params': metal_params(raw[open_paren + 1:close]), 'visibility': 'public',
                        'static': False, 'abstract': False, 'stereotype': role})
    functions = [m['name'] for m in members]
    found.append({'key': cname, 'display': cname, 'pkg': pkg, 'kind': 'class', 'stereotype': 'metal',
                  'abstract': False, 'final': True,
                  'doc': (f'Shaders Metal ({os.path.basename(path)}). ' + ' '.join(lead[:3])).strip(),
                  'conformances': [], 'is_class': False, 'members': members,
                  'src': re.sub(r'\bstruct\s+\w+\s*\{[^}]*\}', '', code), 'frameworks': ['Metal'], 'strings': [],
                  'outer': None, 'private': False, 'file': rel, 'imports': [], 'shader_functions': functions,
                  'shader_file': os.path.basename(path)})
    for m in METAL_STRUCT.finditer(code):
        brace = m.end() - 1
        end = matching(code, brace)
        fields = []
        for line in code[brace + 1:end].split(';'):
            binding = re.search(r'\[\[\s*([^\]]+?)\s*\]\]', line)
            line = re.sub(r'\[\[[^\]]*\]\]', '', line).strip()
            fm = re.match(r'(.+?)\s+([\w,\s]+?)(\[\d+\])?$', ' '.join(line.split()))
            if not fm:
                continue
            for fname in fm.group(2).split(','):
                t = fm.group(1) + (fm.group(3) or '') + (f' [{binding.group(1)}]' if binding else '')
                fields.append({'kind': 'field', 'name': fname.strip(), 'type': t, 'visibility': 'public',
                               'static': False, 'final': False, 'default': ''})
        display = f'{cname}.{m.group(1)}'
        found.append({'key': display, 'display': display, 'pkg': pkg, 'kind': 'class',
                      'stereotype': 'metal struct', 'abstract': False, 'final': True,
                      'doc': doc_before(raw, m.start()) or f'Structure du shader {os.path.basename(path)}.',
                      'conformances': [], 'is_class': False, 'members': fields, 'src': '', 'frameworks': [],
                      'strings': [], 'outer': cname, 'private': False, 'file': rel, 'imports': [],
                      'mirror_of': m.group(1)})


# ============================================================================ the model

def read_classes(source_roots, base_package, modules=None, project_root='.', shaders=True,
                 shader_name='{stem}Shaders', ignored=(), superclasses=(), include_private_types=False):
    """Every type of the Swift (and Metal) sources under `source_roots`."""
    modules = modules or {}
    found, extensions = [], []
    for root, path in swift_files(source_roots):
        if path.endswith('.swift'):
            read_swift_file(root, path, modules, base_package, project_root, found, extensions)
        elif shaders:
            read_metal_file(root, path, modules, base_package, project_root, found, shader_name)
    found = [t for t in found if include_private_types or not t['private']]

    counts = {}
    for t in found:
        counts[t['key']] = counts.get(t['key'], 0) + 1
    classes = {}
    for t in found:
        k = f"{t['pkg']}.{t['key']}" if counts[t['key']] > 1 and t['pkg'] else t['key']
        t['name'] = k
        classes[k] = t

    # Extensions of project types: their members, conformances, strings and source
    for e in extensions:
        k = resolve(classes, e['target'], None, base_package) or \
            next((x for x, c in classes.items() if c['display'] == e['target']), None)
        if not k:
            continue
        c = classes[k]
        c['members'] += type_members(e['code'], e['raw'], e['a'], e['b'], c['kind'])
        c['conformances'] += [x for x in conformances(e['header']) if x not in c['conformances']]
        c['strings'] += e['strings']
        c['src'] += '\n' + e['code'][e['a']:e['b']]
        c['frameworks'] = sorted(set(c['frameworks']) | set(e['frameworks']))

    ignored = set(IGNORED_CONFORMANCES) | ROLE_ONLY | set(ignored)
    known_super = set(KNOWN_SUPERCLASSES) | set(superclasses)
    for c in classes.values():
        c['extends'], c['implements'] = [], []
        for i, sup in enumerate(c.pop('conformances')):
            simple = sup.split('.')[-1]
            if simple in ignored:
                continue
            k = resolve(classes, sup, c, base_package)
            if k:
                target = classes[k]
                is_super = c['is_class'] and i == 0 and target['kind'] == 'class' and target.get('is_class')
            else:
                is_super = c['is_class'] and i == 0 and simple in known_super
            if c['kind'] == 'interface':
                c['extends'].append(sup)          # protocol inheritance
            elif is_super:
                c['extends'].append(sup)
            else:
                c['implements'].append(sup)

    # Properties without a type, initialized with a case of a project enum: `= DisplayMode.colorOnly`
    for c in classes.values():
        for m in c['members']:
            if m['kind'] == 'field' and not m['type']:
                em = re.match(r'([A-Z][\w.]*)\.\w+$', m.get('default', ''))
                k = em and resolve(classes, em.group(1), c, base_package)
                if k and classes[k]['kind'] == 'enum':
                    m['type'] = em.group(1)

    compute_deps(classes, base_package)
    return classes


def compute_deps(classes, base_package):
    """Types named in the code of each type, plus shader links: a Swift type that names a shader
    function in a string, or mirrors a shader struct, depends on it."""
    functions = {}
    for k, c in classes.items():
        for f in c.get('shader_functions', []):
            functions[f] = k
    mirrors = {}
    for k, c in classes.items():
        if c.get('mirror_of'):
            mirrors.setdefault(c['mirror_of'], []).append(k)
    for c in classes.values():
        words = set(re.findall(r'\b([A-Z]\w*(?:\.[A-Z]\w*)?)\b', c['src']))
        deps = set()
        for w in words:
            for part in ([w] + w.split('.')) if '.' in w else [w]:
                r = resolve(classes, part, c, base_package)
                if r and r != c['name']:
                    deps.add(r)
                    break
        if c.get('stereotype') not in ('metal', 'metal struct'):
            for _, _, text in c.get('strings', []):
                if text in functions:
                    deps.add(functions[text])
            for m in mirrors.get(c['display'], []):
                deps.add(m)
        if c['outer']:
            deps.discard(resolve(classes, c['outer'], c, base_package))
        deps -= {k for k in deps if classes[k]['outer'] == c['display']}
        deps.discard(c['name'])
        c['deps'] = sorted(deps)


# ============================================================================ dependencies

APPLE_FRAMEWORKS = {
    'SwiftUI': 'Interface déclarative.', 'AppKit': 'Interface macOS.', 'UIKit': 'Interface iOS.',
    'Foundation': 'Types de base, dates, fichiers, préférences.', 'Observation': 'Macro @Observable.',
    'Combine': 'Flux d’événements.', 'Metal': 'Calcul et rendu sur le GPU.', 'MetalKit': 'MTKView et textures.',
    'MetalPerformanceShaders': 'Noyaux GPU optimisés.', 'simd': 'Vecteurs et matrices.',
    'Charts': 'Graphiques Swift Charts.', 'CoreGraphics': 'Dessin 2D et images.',
    'CoreImage': 'Traitement d’images.', 'QuartzCore': 'Core Animation.', 'SwiftData': 'Persistance.',
    'CoreData': 'Persistance.', 'AVFoundation': 'Audio et vidéo.', 'Accelerate': 'Calcul vectoriel.',
    'SpriteKit': 'Jeux 2D.', 'SceneKit': 'Scènes 3D.', 'RealityKit': 'Réalité augmentée et 3D.',
    'ARKit': 'Réalité augmentée.', 'MapKit': 'Cartes.', 'CoreLocation': 'Localisation.',
    'Network': 'Réseau bas niveau.', 'os': 'Journalisation.', 'Dispatch': 'Files d’exécution.',
    'GameplayKit': 'Logique de jeu.', 'CoreML': 'Apprentissage automatique.', 'Vision': 'Vision par ordinateur.',
    'StoreKit': 'Achats intégrés.', 'WidgetKit': 'Widgets.', 'AppIntents': 'Intentions et raccourcis.',
    'UniformTypeIdentifiers': 'Types de fichiers.', 'CryptoKit': 'Cryptographie.',
    'Testing': 'Swift Testing.', 'XCTest': 'Tests XCTest.',
}
NOISE_MODULES = {'Foundation', 'Swift', 'Observation', 'Dispatch', 'os', 'Darwin', 'Testing', 'XCTest'}


def project_packages(root):
    """Swift packages declared by the project: {name: url}, from Package.swift, project.yml (XcodeGen)
    and *.xcodeproj (XCRemoteSwiftPackageReference)."""
    out = {}
    path = os.path.join(root, 'Package.swift')
    if os.path.exists(path):
        for url in re.findall(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"([^"]+)"',
                              open(path, encoding='utf-8').read()):
            out[re.sub(r'\.git$', '', url.rstrip('/').split('/')[-1])] = url
    path = os.path.join(root, 'project.yml')
    if os.path.exists(path):
        text = open(path, encoding='utf-8').read()
        m = re.search(r'^packages:\s*\n((?:[ \t]+.*\n?)+)', text, re.M)
        if m:
            for name, block in re.findall(r'^[ \t]{2}(\w[\w-]*):\s*\n((?:[ \t]{4,}.*\n?)+)', m.group(1), re.M):
                u = re.search(r'url:\s*(\S+)', block)
                out[name] = u.group(1) if u else ''
    for d in os.listdir(root):
        if d.endswith('.xcodeproj'):
            pbx = os.path.join(root, d, 'project.pbxproj')
            if os.path.exists(pbx):
                for url in re.findall(r'repositoryURL = "([^"]+)"', open(pbx, encoding='utf-8').read()):
                    out.setdefault(re.sub(r'\.git$', '', url.rstrip('/').split('/')[-1]), url)
    return out


# Framework of the external supertypes most often met (the others are drawn «externe»)
EXTERNAL_TYPES = {
    'NSObject': ('Foundation', False), 'LocalizedError': ('Foundation', True), 'Error': ('Swift', True),
    'ObservableObject': ('Combine', True), 'View': ('SwiftUI', True), 'App': ('SwiftUI', True),
    'Scene': ('SwiftUI', True), 'NSViewRepresentable': ('SwiftUI', True), 'UIViewRepresentable': ('SwiftUI', True),
    'ViewModifier': ('SwiftUI', True), 'Shape': ('SwiftUI', True), 'MTKView': ('MetalKit', False),
    'MTKViewDelegate': ('MetalKit', True), 'NSView': ('AppKit', False), 'NSViewController': ('AppKit', False),
    'NSApplicationDelegate': ('AppKit', True), 'NSWindowDelegate': ('AppKit', True), 'UIView': ('UIKit', False),
    'UIViewController': ('UIKit', False), 'UIApplicationDelegate': ('UIKit', True), 'CALayer': ('QuartzCore', False),
    'SKScene': ('SpriteKit', False), 'SKNode': ('SpriteKit', False), 'XCTestCase': ('XCTest', False),
    'AsyncSequence': ('Swift', True), 'Sequence': ('Swift', True), 'Collection': ('Swift', True),
}


def auto_dependencies(config, classes, root):
    """Fills, when uml_config.py leaves them empty, COMPONENTS and COMPONENT_USES (one component per
    first-level package, uses from the dependencies between their classes) and adds LIBRARIES and
    LIBRARY_USES for the imported frameworks and packages and for the Metal shader files."""
    pkg_docs = getattr(config, 'PACKAGE_DOCS', {}) or {}
    base = getattr(config, 'BASE_PACKAGE', '')
    config.EXTERNAL = {**EXTERNAL_TYPES, **(getattr(config, 'EXTERNAL', {}) or {})}

    def comp_of(c):
        return (c['pkg'].split('.')[0] if c['pkg'] else (base.split('.')[-1] if base else 'racine'))

    def key(s):
        return re.sub(r'\W+', '_', s)

    if getattr(config, 'AUTO_COMPONENTS', True) and not getattr(config, 'COMPONENTS', {}):
        comps, uses = {}, set()
        for c in classes.values():
            name = comp_of(c)
            doc = pkg_docs.get(c['pkg'].split('.')[0] if c['pkg'] else '', '') or f'Le paquet {name}.'
            comps.setdefault(key(name), (name, 'module', doc, [], []))
        for c in classes.values():
            a = key(comp_of(c))
            targets = list(c['deps']) + [t for t in c['extends'] + c['implements']]
            for m in c['members']:
                if m['kind'] == 'field':
                    targets += re.findall(r'[\w.]+', m['type'])
            for t in targets:
                k = t if t in classes else resolve(classes, t, c, base)
                if k:
                    b = key(comp_of(classes[k]))
                    if a != b:
                        uses.add((a, b))
        # Interfaces: the protocols a component declares and some type implements are provided;
        # the protocols of other components that its types implement or use are required
        provided, required = {}, {}
        for c in classes.values():
            a = key(comp_of(c))
            for t in c['implements'] + c['deps']:
                k = t if t in classes else resolve(classes, t, c, base)
                if not k or classes[k]['kind'] != 'interface':
                    continue
                b = key(comp_of(classes[k]))
                if t in c['implements']:
                    provided.setdefault(b, set()).add(k)
                if a != b:
                    required.setdefault(a, set()).add(k)
        for k, (name, stereo, doc, _, _) in list(comps.items()):
            comps[k] = (name, stereo, doc, sorted(provided.get(k, ())), sorted(required.get(k, ())))
        config.COMPONENTS = comps
        config.COMPONENT_USES = sorted(uses)

    if not getattr(config, 'AUTO_LIBRARIES', True):
        return
    libraries = dict(getattr(config, 'LIBRARIES', {}) or {})
    library_uses = list(getattr(config, 'LIBRARY_USES', []) or [])
    comps = getattr(config, 'COMPONENTS', {})
    comp_key = {}
    for k, (name, *_rest) in comps.items():
        comp_key[name] = k
        comp_key[k] = k
    packages = project_packages(root)
    noise = NOISE_MODULES | set(getattr(config, 'IGNORED_MODULES', []))
    own_modules = set((getattr(config, 'SWIFT_MODULES', {}) or {}).values()) | {base.split('.')[0]}
    seen = {(u[0], u[1]) for u in library_uses}
    matched = set()                              # packages reached through an imported module
    for c in classes.values():
        comp = comp_key.get(comp_of(c)) or comp_key.get(key(comp_of(c)))
        if not comp:
            continue
        for fw in c.get('frameworks', []):
            if fw in noise or fw in own_modules:
                continue
            lk = 'lib_' + key(fw)
            if lk not in libraries:
                if fw in APPLE_FRAMEWORKS:       # named as on disk: never the same name as a package
                    libraries[lk] = (f'{fw}.framework', 'library', APPLE_FRAMEWORKS[fw])
                else:
                    norm = fw.lower()
                    pkg_name = fw if fw in packages else next(
                        (n for n in packages if norm in n.lower().replace('-', '').replace('_', '')), None)
                    url = packages.get(pkg_name, '') if pkg_name else ''
                    if pkg_name:
                        matched.add(pkg_name)
                    libraries[lk] = (fw, 'library', f'Module du paquet Swift {pkg_name} ({url}).' if url
                                     else f'Module {fw}.')
            if (comp, lk) not in seen:
                library_uses.append((comp, lk))
                seen.add((comp, lk))
        if c.get('stereotype') == 'metal':
            lk = 'file_' + key(c['shader_file'])
            libraries.setdefault(lk, (c['shader_file'], 'file',
                                      'Shaders : ' + ', '.join(c['shader_functions']) + '.'))
            if (comp, lk) not in seen:
                library_uses.append((comp, lk))
                seen.add((comp, lk))
    # Components whose Swift code loads a shader function: uses the shader file
    for c in classes.values():
        comp = comp_key.get(key(comp_of(c)))
        if not comp or c.get('stereotype') in ('metal', 'metal struct'):
            continue
        for d in c['deps']:
            t = classes.get(d)
            fk = 'file_' + key(t['shader_file']) if t and t.get('stereotype') == 'metal' else None
            if fk and (comp, fk) not in seen:
                library_uses.append((comp, fk, 'makeFunction'))
                seen.add((comp, fk))
    for name, url in packages.items():          # declared packages never imported
        if name not in matched and 'lib_' + key(name) not in libraries:
            libraries['lib_' + key(name)] = (name, 'library', f'Paquet Swift {url}.')
    config.LIBRARIES = libraries
    config.LIBRARY_USES = library_uses
