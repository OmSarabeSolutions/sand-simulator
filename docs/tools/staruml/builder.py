"""Builds the StarUML project from the classes read in the sources and the
descriptions of uml_config.py:

  00       overview: a hyperlink to every diagram
  01       package dependencies
  02-09    components (modules, libraries, interfaces) and deployment
  10-29    class diagrams (configured, or one per package)
  30-39    state machines
  40-…     sequence diagrams

Every name a description uses is checked: an unknown class, component or
lifeline type stops the generation with the list of what is wrong.
"""
import re

from core import element, own, ref, clone_view, sub_view, ref_target, graphviz, points_str, text_w, BOLD_W, LINE_H
from java_source import resolve

VIS = {'public': '+', 'protected': '#', 'private': '-', 'package': '~'}


class ConfigError(Exception):
    pass


def cfg(config, name, default):
    v = getattr(config, name, default)
    return default if v is None else v


class Model:
    """The project being built, and indexes into it."""

    def __init__(self, config, classes, sizes):
        self.config = config
        self.base = cfg(config, 'BASE_PACKAGE', '')
        self.classes = classes
        self.sizes = sizes
        self.errors = []
        name = cfg(config, 'PROJECT_NAME', 'Projet')
        self.project = element('Project', None, name, documentation=cfg(
            config, 'PROJECT_DOC',
            f'Modèle UML de {name}, généré à partir des sources. Commencer par le diagramme « 00 · Vue '
            f'd’ensemble » : chaque lien ouvre un diagramme.'))
        self.elements = {}        # class key -> UML element
        self.packages = {}        # relative package -> UML package
        self.ops = {}             # (class key, op name) -> UML operation
        self.relations = []       # (kind, source key, target key, element)

    def size(self, view, w, h):
        """The measured size of `view` if known, else the estimate."""
        s = self.sizes.get(view['_id'])
        return (s[0], s[1]) if s else (w, h)

    def node(self, diagram, view):
        own(diagram, view, 'ownedViews')
        return view

    def edge(self, diagram, type_, model, tail, head, pts=None, line_style=1):
        v = clone_view(type_, diagram, model)
        v['tail'] = ref(tail)
        v['head'] = ref(head)
        v['lineStyle'] = line_style
        if pts:
            v['points'] = points_str(pts)
        for s in v.get('subViews', []):
            if s['_type'] == 'EdgeLabelView':
                s['hostEdge'] = ref(v)
        return own(diagram, v, 'ownedViews')

    def class_key(self, name, where):
        """The class key of `name` (Name, Outer.Inner or pkg.Name), or None after noting the error."""
        if name in self.classes:
            return name
        k = resolve(self.classes, name, None, self.base)
        if k:
            return k
        cands = sorted(c['name'] for c in self.classes.values() if c['display'] == name)
        hint = f' - ambigu, préciser : {", ".join(cands)}' if cands else ''
        self.errors.append(f'{where} : classe inconnue « {name} »{hint}')
        return None

    def diagram_name(self, key, default):
        return cfg(self.config, 'DIAGRAM_NAMES', {}).get(key, default)


def type_ref(model, type_text, ctx):
    """A reference to the project class named by `type_text` (seen from class `ctx`), or the text itself."""
    t = type_text.strip()
    k = resolve(model.classes, t, model.classes[ctx], model.base) if re.fullmatch(r'[\w.]+', t) else None
    if k:
        return ref(model.elements[k])
    return t


# ============================================================================ logical view

def build_logical(model, root):
    classes = model.classes
    module_of = cfg(model.config, 'MODULE_OF', {})
    parent = root
    for part in model.base.split('.') if model.base else []:
        parent = own(parent, element('UMLPackage', parent, part))
    fp = parent
    if model.base:
        fp['documentation'] = cfg(model.config, 'BASE_PACKAGE_DOC', 'Racine du code.')
    model.packages[''] = fp
    for pkg in sorted({c['pkg'] for c in classes.values() if c['pkg']}, key=lambda p: (p.count('.'), p)):
        parent, path = fp, ''
        for part in pkg.split('.'):
            path = f'{path}.{part}' if path else part
            if path not in model.packages:
                doc = cfg(model.config, 'PACKAGE_DOCS', {}).get(path) or \
                    (f'Module {module_of[path]}.' if path in module_of else '')
                model.packages[path] = own(parent, element('UMLPackage', parent, part, documentation=doc))
            parent = model.packages[path]

    # Supertypes from outside the project: the configured ones, then any other one found
    external = dict(cfg(model.config, 'EXTERNAL', {}))
    for c in classes.values():
        for sup in c['extends'] + c['implements']:
            if not resolve(classes, sup, c, model.base) and sup not in external:
                interface = sup in c['implements'] or c['kind'] == 'interface'
                external[sup] = ('externe', interface)
    if external:
        ext = own(root, element('UMLPackage', root, 'Bibliothèques externes',
                                documentation='Types de bibliothèques dont héritent des classes du modèle.'))
        for name, (lib, interface) in sorted(external.items()):
            model.elements[name] = own(ext, element('UMLInterface' if interface else 'UMLClass', ext, name,
                                                    stereotype=lib.lower()))

    def supertype(name, ctx):
        k = resolve(classes, name, classes[ctx], model.base)
        return k if k else name if name in model.elements else None

    # Classifiers first (so that types can reference each other)
    for c in classes.values():
        pkg = model.packages[c['pkg']]
        t = {'interface': 'UMLInterface', 'enum': 'UMLEnumeration'}.get(c['kind'], 'UMLClass')
        e = element(t, pkg, c['display'], documentation=c['doc'])
        if c['kind'] == 'record':
            e['stereotype'] = 'record'
        elif c.get('stereotype'):
            e['stereotype'] = c['stereotype']
        if c['abstract']:
            e['isAbstract'] = True
        if c['final']:
            e['isLeaf'] = True
        model.elements[c['name']] = own(pkg, e)

    # Members
    for c in classes.values():
        e = model.elements[c['name']]
        for m in c['members']:
            if m['kind'] == 'literal':
                own(e, element('UMLEnumerationLiteral', e, m['name']), 'literals')
            elif m['kind'] == 'field':
                if m['static'] and m['visibility'] == 'private':
                    continue        # internal constants
                a = element('UMLAttribute', e, m['name'], visibility=m['visibility'],
                            type=type_ref(model, m['type'], c['name']), isStatic=m['static'], isReadOnly=m['final'])
                if m['static'] and re.fullmatch(r'-?[\d.]+[dDfFlL]?', m['default']):
                    a['defaultValue'] = m['default']
                own(e, a, 'attributes')
            elif m['kind'] in ('op', 'ctor'):
                if m['visibility'] == 'private':
                    continue
                o = element('UMLOperation', e, m['name'], visibility=m['visibility'], isStatic=m['static'],
                            isAbstract=m['abstract'])
                if m['kind'] == 'ctor':
                    o['stereotype'] = 'create'
                elif m.get('stereotype'):
                    o['stereotype'] = m['stereotype']
                for pname, ptype in m['params']:
                    own(o, element('UMLParameter', o, pname, type=type_ref(model, ptype, c['name']), direction='in'),
                        'parameters')
                if m['kind'] == 'op' and m['type'] != 'void':
                    own(o, element('UMLParameter', o, '', type=type_ref(model, m['type'], c['name']),
                                   direction='return'), 'parameters')
                own(e, o, 'operations')
                model.ops.setdefault((c['name'], m['name']), o)

    # Relationships
    for c in classes.values():
        src = model.elements[c['name']]
        related = set()
        for sup in c['extends']:
            k = supertype(sup, c['name'])
            if k:
                kind = 'UMLInterfaceRealization' if c['kind'] != 'interface' and \
                    model.elements[k]['_type'] == 'UMLInterface' else 'UMLGeneralization'
                r = own(src, element(kind, src, None, source=ref(src), target=ref(model.elements[k])))
                model.relations.append(('generalization' if kind == 'UMLGeneralization' else 'realization',
                                        c['name'], k, r))
                related.add(k)
        for itf in c['implements']:
            k = supertype(itf, c['name'])
            if k:
                r = own(src, element('UMLInterfaceRealization', src, None, source=ref(src),
                                     target=ref(model.elements[k])))
                model.relations.append(('realization', c['name'], k, r))
                related.add(k)
        for m in c['members']:
            if m['kind'] != 'field' or m['static']:
                continue
            targets = [k for k in (resolve(classes, n, c, model.base) for n in re.findall(r'[\w.]+', m['type']))
                       if k and k != c['name']]
            for t in targets[:1]:
                many = re.search(r'(List|Set|Collection|Map|Iterable|Stream|Array|Dictionary|Deque)\b|\[\]|'
                                 r'^\s*\[.+\]\s*\??$', m['type'])
                optional = re.search(r'\bOptional\b|\?\s*$', m['type'])
                composite = m['default'].startswith('new ')
                a = element('UMLAssociation', src, None)
                a['end1'] = element('UMLAssociationEnd', a, '', reference=ref(src), navigable=False,
                                    aggregation='composite' if composite else 'none')
                a['end2'] = element('UMLAssociationEnd', a, m['name'], reference=ref(model.elements[t]),
                                    navigable=True, visibility=m['visibility'],
                                    multiplicity='0..*' if many else '0..1' if optional else '')
                own(src, a)
                model.relations.append(('association', c['name'], t, a))
                related.add(t)
        for d in c['deps']:
            k = d if d in classes else resolve(classes, d, c, model.base)
            if k and k not in related and k != c['name']:
                r = own(src, element('UMLDependency', src, None, source=ref(src), target=ref(model.elements[k])))
                model.relations.append(('dependency', c['name'], k, r))
                related.add(k)

    # Package dependencies, from the class ones
    pkg_deps = set()
    for kind, a, b, _ in model.relations:
        if kind == 'dependency' or kind == 'association':
            pa, pb = classes[a]['pkg'], classes[b]['pkg'] if b in classes else None
            if pb is not None and pa != pb:
                pkg_deps.add((pa, pb))
    model.pkg_deps = {}
    for a, b in sorted(pkg_deps):
        pa = model.packages[a]
        model.pkg_deps[(a, b)] = own(pa, element('UMLDependency', pa, None, source=ref(pa),
                                                 target=ref(model.packages[b])))
    return fp


# ============================================================================ class diagrams

def model_name(model, r):
    for n, e in model.elements.items():
        if e['_id'] == r['$ref']:
            return e.get('name', n)
    return '?'


def type_text(model, t):
    return t if isinstance(t, str) else model_name(model, t)


def member_lines(model, name, with_members):
    e = model.elements[name]
    attrs, ops = [], []
    if with_members:
        for lit in e.get('literals', []):
            attrs.append(lit['name'])
        for a in e.get('attributes', []):
            ro = ' {readOnly}' if a.get('isReadOnly') else ''
            attrs.append(f"{VIS[a['visibility']]}{a['name']}: {type_text(model, a['type'])}{ro}")
        for o in e.get('operations', []):
            ps = [p for p in o.get('parameters', []) if p['direction'] == 'in']
            ret = [p for p in o.get('parameters', []) if p['direction'] == 'return']
            sig = ', '.join(f"{p['name']}: {type_text(model, p['type'])}" for p in ps)
            r = type_text(model, ret[0]['type']) if ret else ''
            ops.append(f"{VIS[o['visibility']]}{o['name']}({sig}){': ' + r if r else ''}")
    stereo = e.get('stereotype') or {'UMLInterface': 'interface', 'UMLEnumeration': 'enumeration'}.get(e['_type'])
    return stereo, attrs, ops


def class_view(model, diagram, name, with_members):
    e = model.elements[name]
    t = {'UMLInterface': 'UMLInterfaceView', 'UMLEnumeration': 'UMLEnumerationView'}.get(e['_type'], 'UMLClassView')
    v = clone_view(t, diagram, e)
    stereo, attrs, ops = member_lines(model, name, with_members)
    v['suppressAttributes'] = not with_members
    v['suppressOperations'] = not with_members
    if t == 'UMLEnumerationView':
        v['suppressLiterals'] = not with_members
    if t == 'UMLInterfaceView':
        v['stereotypeDisplay'] = 'label'
    w = max([text_w(e['name'], BOLD_W)] + [text_w(x) for x in attrs + ops] +
            [text_w(f'«{stereo}»') if stereo else 0]) + 24
    h = 26 + (LINE_H if stereo else 0)
    if e.get('isLeaf'):
        h += LINE_H  # the {leaf} property line under the name
    if with_members:
        h += 10 + LINE_H * len(attrs) + 10 + LINE_H * len(ops)
    estimated_w, estimated_h = w, h
    w, h = model.size(v, w, h)
    w = max(w, estimated_w)     # the measurement can leave out property suffixes such as {readOnly}
    if e.get('isLeaf') or t == 'UMLEnumerationView':
        # The measurement leaves out the {leaf} and «enumeration» lines, which are still drawn.
        h = max(h, estimated_h)
    v['width'], v['height'] = round(w), round(h)
    return model.node(diagram, v)


EDGE_VIEWS = {'generalization': 'UMLGeneralizationView', 'realization': 'UMLInterfaceRealizationView',
              'association': 'UMLAssociationView', 'dependency': 'UMLDependencyView',
              'path': 'UMLCommunicationPathView'}


def layout_and_link(model, diagram, views, relations, rankdir='TB', ranksep=0.8, nodesep=0.45, labels=None):
    """Places `views` ({key: view}) with Graphviz, then draws `relations`
    ([(kind, a, b, element)]) between them."""
    edge_specs = []
    for kind, a, b, rel in relations:
        upper, lower = (b, a) if kind in ('generalization', 'realization') else (a, b)
        edge_specs.append((upper, lower, kind, a, b, rel))
    nodes = {n: (v['width'], v['height']) for n, v in views.items()}
    centers, routes = graphviz(nodes, [(u, l) for u, l, *_ in edge_specs], rankdir=rankdir,
                               ranksep=ranksep, nodesep=nodesep, labels=labels)
    margin = 40
    for n, v in views.items():
        x, y = centers[n]
        v['left'] = round(x - v['width'] / 2 + margin)
        v['top'] = round(y - v['height'] / 2 + margin + 30)
    for i, (upper, lower, kind, a, b, rel) in enumerate(edge_specs):
        pts = [(x + margin, y + margin + 30) for x, y in routes[i]]
        if (upper, lower) != (a, b):
            pts = list(reversed(pts))
        model.edge(diagram, EDGE_VIEWS[kind], rel, views[a], views[b], pts)


def diagram_spec(spec):
    """A class diagram of uml_config.CLASS_DIAGRAMS, as a dict."""
    if isinstance(spec, dict):
        return {'members': True, 'rankdir': 'TB', 'doc': '', 'package': '', **spec}
    name, pkg, focus, doc, *rest = spec
    return {'name': name, 'package': pkg, 'classes': focus, 'doc': doc, 'members': rest[0] if rest else True,
            'rankdir': rest[1] if len(rest) > 1 else 'TB'}


def top_package(pkg):
    return pkg.split('.')[0]


def auto_class_diagrams(model):
    """One diagram per package - per top-level package beyond 20 packages, to stay within 10-29 -,
    with members when it stays readable."""
    max_members = cfg(model.config, 'AUTO_MEMBERS_MAX_CLASSES', 20)
    grouped = len({c['pkg'] for c in model.classes.values()}) > 20
    by_pkg = {}
    for k, c in model.classes.items():
        by_pkg.setdefault(top_package(c['pkg']) if grouped else c['pkg'], []).append(k)
    out = []
    for i, pkg in enumerate(sorted(by_pkg)):
        keys = sorted(by_pkg[pkg], key=lambda k: model.classes[k]['display'])
        label = pkg or model.base.split('.')[-1] or 'racine'
        doc = cfg(model.config, 'PACKAGE_DOCS', {}).get(pkg, f'Les classes du paquet {label}.')
        out.append({'name': f'{10 + i:02d} · Classes — {label}', 'package': pkg, 'classes': keys, 'doc': doc,
                    'members': len(keys) <= max_members, 'rankdir': 'TB'})
    return out


def class_diagram(model, spec):
    owner = model.packages.get(spec['package'], model.packages[''])
    focus = [k for k in (model.class_key(n, spec['name']) for n in spec['classes']) if k]
    if not focus:
        return None
    with_members = spec['members']
    d = own(owner, element('UMLClassDiagram', owner, spec['name'], documentation=spec['doc'], defaultDiagram=False))
    shown = list(focus)
    # Direct supertypes and association targets of the focus classes give the context
    for kind, a, b, _ in model.relations if with_members else []:
        if a in focus and kind in ('generalization', 'realization', 'association') and b not in shown:
            shown.append(b)
    views = {n: class_view(model, d, n, with_members and n in focus) for n in shown}
    # dependencies only between the classes the diagram is about: those to the context would hide the rest
    rels = [r for r in model.relations if r[1] in views and r[2] in views and r[1] != r[2]
            and (r[0] != 'dependency' or (r[1] in focus and r[2] in focus))]
    layout_and_link(model, d, views, rels, rankdir=spec['rankdir'])
    return d


# ============================================================================ package diagram

def package_diagram(model, fp):
    """Beyond 12 packages (and without PACKAGE_ORDER), one view per top-level package."""
    pkgs = cfg(model.config, 'PACKAGE_ORDER', [])
    deps = model.pkg_deps
    if not pkgs:
        pkgs = sorted({c['pkg'] for c in model.classes.values()})
        if len(pkgs) > 12:
            pkgs = sorted({top_package(p) for p in pkgs})
            deps = {}
            for a, b in sorted(model.pkg_deps):
                ta, tb = top_package(a), top_package(b)
                if ta != tb and (ta, tb) not in deps:
                    pa = model.packages[ta]
                    deps[(ta, tb)] = own(pa, element('UMLDependency', pa, None, source=ref(pa),
                                                     target=ref(model.packages[tb])))
    if len(pkgs) < 2:
        return None
    name = model.diagram_name('packages', '01 · Paquets — dépendances')
    d = own(fp, element('UMLPackageDiagram', fp, name, documentation=cfg(
        model.config, 'PACKAGE_DIAGRAM_DOC', 'Une dépendance A → B : une classe de A nomme une classe de B.')))
    views = {}
    for p in pkgs:
        if p not in model.packages:
            model.errors.append(f'PACKAGE_ORDER : paquet inconnu « {p} »')
            continue
        label = p or model.base
        v = clone_view('UMLPackageView', d, model.packages[p])
        w, h = model.size(v, max(text_w(label.split('.')[-1], BOLD_W) + 40, 110), 60)
        v['width'], v['height'] = round(w), round(h)
        views[p] = model.node(d, v)
    rels = [('dependency', a, b, dep) for (a, b), dep in deps.items() if a in views and b in views]
    layout_and_link(model, d, views, rels, ranksep=0.9, nodesep=0.35)
    return d


# ============================================================================ components

def build_components(model, project):
    """COMPONENTS: key -> (name, stereotype, doc[, provided interfaces, required interfaces]);
    LIBRARIES: key -> (name, stereotype, doc); COMPONENT_USES / LIBRARY_USES: (a, b[, label])."""
    components = cfg(model.config, 'COMPONENTS', {})
    libraries = cfg(model.config, 'LIBRARIES', {})
    if not components:
        return
    view_model = own(project, element('UMLModel', project, 'Vue des composants', documentation=cfg(
        model.config, 'COMPONENTS_DOC', 'Les modules du projet, les interfaces qu’ils fournissent et requièrent, '
                                        'et les bibliothèques et fichiers dont ils dépendent.')))
    comps = {}
    for key, spec in list(components.items()) + list(libraries.items()):
        name, stereo, doc = spec[:3]
        comps[key] = own(view_model, element('UMLComponent', view_model, name, stereotype=stereo, documentation=doc))

    interfaces = {}
    for key, spec in components.items():
        for n in (spec[3] if len(spec) > 3 else []) + (spec[4] if len(spec) > 4 else []):
            if n not in interfaces:
                k = model.class_key(n, f'COMPONENTS[{key}]')
                if k:
                    interfaces[n] = model.elements[k]
    relations = []
    for key, spec in components.items():
        c = comps[key]
        for itf in (spec[3] if len(spec) > 3 else []):
            if itf in interfaces:
                r = own(c, element('UMLInterfaceRealization', c, None, source=ref(c), target=ref(interfaces[itf])))
                relations.append(('realization', key, 'itf:' + itf, r))
        for itf in (spec[4] if len(spec) > 4 else []):
            if itf in interfaces:
                r = own(c, element('UMLDependency', c, None, source=ref(c), target=ref(interfaces[itf]),
                                   stereotype='use'))
                relations.append(('dependency', key, 'itf:' + itf, r))
    uses, labels = [], []
    module_uses = cfg(model.config, 'COMPONENT_USES', [])
    for use in module_uses + cfg(model.config, 'LIBRARY_USES', []):
        a, b, label = (tuple(use) + ('',))[:3]
        if a not in comps or b not in comps:
            model.errors.append(f'COMPONENT_USES / LIBRARY_USES : composant inconnu dans {use}')
            continue
        stereo = 'requires' if use in module_uses and b in components else 'use'
        r = own(comps[a], element('UMLDependency', comps[a], label or None, source=ref(comps[a]),
                                  target=ref(comps[b]), stereotype=stereo))
        uses.append(('dependency', a, b, r))
        labels.append(label)

    def component_view(d, key):
        c = comps[key]
        v = clone_view('UMLComponentView', d, c)
        v['stereotypeDisplay'] = 'decoration-label'
        v['suppressAttributes'] = True
        v['suppressOperations'] = True
        w, h = model.size(v, max(text_w(c['name'], BOLD_W), text_w('«' + c['stereotype'] + '»')) + 60, 56)
        v['width'], v['height'] = round(max(w, 150)), round(h)
        return model.node(d, v)

    def interface_view(d, name):
        v = clone_view('UMLInterfaceView', d, interfaces[name])
        v['stereotypeDisplay'] = 'icon'
        v['suppressAttributes'] = True
        v['suppressOperations'] = True
        w, h = model.size(v, max(text_w(interfaces[name]['name'], BOLD_W) + 10, 60), 50)
        v['width'], v['height'] = round(w), round(h)
        return model.node(d, v)

    d = own(view_model, element('UMLComponentDiagram', view_model,
                                model.diagram_name('components', '02 · Composants — modules et dépendances'),
                                documentation='Les dépendances entre modules, et les bibliothèques et fichiers de '
                                              'chaque module.'))
    views = {k: component_view(d, k) for k in comps}
    layout_and_link(model, d, views, uses, ranksep=0.8, nodesep=0.4,
                    labels=labels if any(labels) else None)

    if relations:
        d = own(view_model, element('UMLComponentDiagram', view_model,
                                    model.diagram_name('interfaces', '03 · Composants — interfaces fournies et '
                                                                     'requises'),
                                    documentation='Ce que chaque module fournit (cercle) ou requiert («use»).'))
        views = {k: component_view(d, k) for k in components}
        for name in interfaces:
            views['itf:' + name] = interface_view(d, name)
        layout_and_link(model, d, views, relations, ranksep=0.9, nodesep=0.4)


# ============================================================================ deployment

def build_deployment(model, project):
    """DEPLOYMENT_NODES: key -> (name, stereotype, doc); NETWORK: (a, b, label)."""
    nodes_spec = cfg(model.config, 'DEPLOYMENT_NODES', {})
    if not nodes_spec:
        return
    view = own(project, element('UMLModel', project, 'Vue de déploiement', documentation=cfg(
        model.config, 'DEPLOYMENT_DOC', 'Processus, machines, ports et flux réseau.')))
    nodes = {}
    for k, (name, stereo, doc) in nodes_spec.items():
        nodes[k] = own(view, element('UMLNode', view, name, documentation=doc, stereotype=stereo))
    d = own(view, element('UMLDeploymentDiagram', view,
                          model.diagram_name('deployment', '04 · Déploiement — réseau et ports'),
                          documentation=cfg(model.config, 'DEPLOYMENT_DOC', 'Processus, ports et flux réseau.')))
    views = {}
    for k, n in nodes.items():
        v = clone_view('UMLNodeView', d, n)
        w, h = model.size(v, max(text_w(n['name'], BOLD_W), text_w('«' + n['stereotype'] + '»')) + 50, 70)
        v['width'], v['height'] = round(w), round(h)
        views[k] = model.node(d, v)
    edges, labels = [], []
    for a, b, label in cfg(model.config, 'NETWORK', []):
        if a not in nodes or b not in nodes:
            model.errors.append(f'NETWORK : nœud inconnu dans {(a, b, label)}')
            continue
        path = element('UMLCommunicationPath', nodes[a], label)
        path['end1'] = element('UMLAssociationEnd', path, reference=ref(nodes[a]), navigable='unspecified')
        path['end2'] = element('UMLAssociationEnd', path, reference=ref(nodes[b]), navigable='navigable')
        own(nodes[a], path)
        edges.append(('path', a, b, path))
        labels.append(label)
    layout_and_link(model, d, views, edges, ranksep=1.1, nodesep=0.8, labels=labels)


# ============================================================================ state machines

S, I, C, F = 'state', 'initial', 'choice', 'final'


def transition_label(trigger, guard, effect):
    out = trigger
    if guard:
        out += f' [{guard}]'
    if effect:
        out += f' / {effect}'
    return out.strip()


def build_state_machines(model, project):
    """STATE_MACHINES: {'name', 'owner' (class), 'doc', 'states': key -> (name, kind, {entry|do|exit: text}),
    'transitions': [(source, target, trigger, guard, effect)]}; kind: state, initial, choice, final."""
    machines = cfg(model.config, 'STATE_MACHINES', [])
    holder = None
    for sm in machines:
        owner_key = model.class_key(sm['owner'], sm['name']) if sm.get('owner') else None
        if sm.get('owner') and not owner_key:
            continue
        if owner_key:
            owner = model.elements[owner_key]
        else:
            if holder is None:
                holder = own(project, element('UMLModel', project, 'Vue dynamique — états'))
            owner = holder
        build_machine(model, owner, sm)


def build_machine(model, owner, sm):
    machine = own(owner, element('UMLStateMachine', owner, sm['name'], documentation=sm.get('doc', '')))
    region = own(machine, element('UMLRegion', machine, ''), 'regions')
    d = own(machine, element('UMLStatechartDiagram', machine, sm['name'], documentation=sm.get('doc', '')))
    frame = model.node(d, clone_view('UMLFrameView', d, d))

    vertices, views = {}, {}
    for key, (name, kind, acts) in sm['states'].items():
        if kind == S:
            v_el = element('UMLState', region, name)
            for what, field in (('entry', 'entryActivities'), ('do', 'doActivities'), ('exit', 'exitActivities')):
                if what in acts:
                    own(v_el, element('UMLOpaqueBehavior', v_el, acts[what]), field)
        elif kind == F:
            v_el = element('UMLFinalState', region, name)
        else:
            v_el = element('UMLPseudostate', region, name, kind=kind)
        vertices[key] = own(region, v_el, 'vertices')
        vtype = {S: 'UMLStateView', F: 'UMLFinalStateView'}.get(kind, 'UMLPseudostateView')
        v = clone_view(vtype, d, v_el)
        if kind == S:
            lines = [f'{w}/{a}' for w, a in acts.items()]
            w = max([text_w(name, BOLD_W)] + [text_w(x) for x in lines]) + 30
            h = 34 + (LINE_H * len(lines) + 8 if lines else 0)
        else:
            w = h = {I: 20, C: 30, F: 26}.get(kind, 30)
        w, h = model.size(v, max(w, 110) if kind == S else w, h)
        v['width'], v['height'] = round(w), round(h)
        views[key] = model.node(d, v)

    transitions = []
    for src, tgt, trig, guard, effect in sm['transitions']:
        if src not in vertices or tgt not in vertices:
            model.errors.append(f'{sm["name"]} : état inconnu dans la transition {(src, tgt, trig)}')
            continue
        t = element('UMLTransition', region, '', source=ref(vertices[src]), target=ref(vertices[tgt]), kind='external')
        if trig:
            own(t, element('UMLEvent', t, trig, kind='anyReceive'), 'triggers')
        if guard:
            t['guard'] = guard
        if effect:
            own(t, element('UMLOpaqueBehavior', t, effect), 'effects')
        own(region, t, 'transitions')
        transitions.append((src, tgt, t, transition_label(trig, guard, effect)))

    nodes = {k: (v['width'], v['height']) for k, v in views.items()}
    centers, routes = graphviz(nodes, [(a, b) for a, b, _, _ in transitions], rankdir='TB', nodesep=0.9,
                               ranksep=0.9, labels=[lb for *_, lb in transitions])
    ox, oy = 240, 70          # room on the left for the labels of transitions going left
    for k, v in views.items():
        x, y = centers[k]
        v['left'], v['top'] = round(x - v['width'] / 2 + ox), round(y - v['height'] / 2 + oy)
    for i, (a, b, t, _) in enumerate(transitions):
        pts = [(x + ox, y + oy) for x, y in routes[i]]
        if a == b:
            # A loop on the right side of the state
            v = views[a]
            r, top = v['left'] + v['width'], v['top']
            pts = [(r - 20, top), (r - 20, top - 25), (r + 30, top - 25), (r + 30, top + 15), (r, top + 15)]
        model.edge(d, 'UMLTransitionView', t, views[a], views[b], pts, 1)
    edge_xs = [float(p.split(':')[0]) for v in d['ownedViews'] if v['_type'] == 'UMLTransitionView'
               for p in v['points'].split(';')]
    right = max([v['left'] + v['width'] for v in views.values()] + edge_xs) + 220
    bottom = max(v['top'] + v['height'] for v in views.values()) + 40
    frame['left'], frame['top'], frame['width'], frame['height'] = 20, 16, round(right - 20), round(bottom - 16)


# ============================================================================ sequence diagrams

HEAD_H = 40        # lifeline head
ROW = 34
SELF_ROW = 46
FRAG_HEAD = 44
FRAG_END = 14


def build_scenarios(model, project):
    """SCENARIOS: {'name', 'doc', 'lifelines': key -> (role name, class or actor), 'steps': [...]}, with
    ACTORS: name -> documentation. Steps:
      ('call' | 'async' | 'reply' | 'create', from, to, 'op(args)')   ('self', who, 'op(args)')
      ('alt', [(guard, [steps]), ...])   ('opt', guard, [steps])   ('loop', guard, [steps])"""
    scenarios = cfg(model.config, 'SCENARIOS', [])
    if not scenarios:
        return
    dyn = own(project, element('UMLModel', project, 'Vue dynamique — interactions', documentation=cfg(
        model.config, 'SCENARIOS_DOC', 'Les principaux scénarios, en diagrammes de séquence.')))
    actors = {n: own(dyn, element('UMLActor', dyn, n, documentation=doc))
              for n, doc in cfg(model.config, 'ACTORS', {}).items()}
    collab = own(dyn, element('UMLCollaboration', dyn, 'Scénarios',
                              documentation='Les rôles joués par les classes dans les scénarios.'))
    roles = {}

    def role(name, type_name, where):
        key = (name, type_name)
        if key not in roles:
            if type_name in actors:
                t = actors[type_name]
            else:
                k = model.class_key(type_name, where)
                if not k:
                    return None
                t = model.elements[k]
            roles[key] = own(collab, element('UMLAttribute', collab, name, type=ref(t)), 'attributes')
        return roles[key]

    for sc in scenarios:
        build_scenario(model, collab, sc, role, actors)


def build_scenario(model, collab, sc, role, actors):
    inter = own(collab, element('UMLInteraction', collab, sc['name'], documentation=sc.get('doc', '')))
    d = own(inter, element('UMLSequenceDiagram', inter, sc['name'], documentation=sc.get('doc', ''),
                           showSequenceNumber=False, showSignature=True, showActivation=False))
    frame = clone_view('UMLFrameView', d, d)
    model.node(d, frame)

    # Lifelines
    lifelines, lviews, x = {}, {}, 40
    for key, (rname, tname) in sc['lifelines'].items():
        r = role(rname, tname, sc['name'])
        if r is None:
            return
        life = own(inter, element('UMLLifeline', inter, rname, represent=ref(r)), 'participants')
        lifelines[key] = life
        label = f'{rname}: {tname}' if tname not in actors else f': {tname}'
        w = max(text_w(label) + 24, 90)
        v = clone_view('UMLSeqLifelineView', d, life)
        v['left'], v['top'], v['width'] = round(x), 50, round(w)
        if tname in actors:
            v['stereotypeDisplay'] = 'icon'
        lviews[key] = v
        x += w + 36
    center = {k: v['left'] + v['width'] / 2 for k, v in lviews.items()}

    created = {}
    msgs, frags = [], []
    y = [50 + HEAD_H + 40]

    def involved(steps):
        out = set()
        for s in steps:
            if s[0] in ('call', 'async', 'reply', 'create'):
                out |= {s[1], s[2]}
            elif s[0] == 'self':
                out.add(s[1])
            elif s[0] == 'alt':
                for _, sub in s[1]:
                    out |= involved(sub)
            else:
                out |= involved(s[2])
        return out

    def walk(steps, depth):
        for s in steps:
            kind = s[0]
            if kind in ('alt', 'opt', 'loop', 'par', 'break', 'critical'):
                operands = s[1] if kind in ('alt', 'par') else [(s[1], s[2])]
                frag = element('UMLCombinedFragment', inter, '', interactionOperator=kind)
                own(inter, frag, 'fragments')   # StarUML: every fragment belongs to the interaction
                y[0] += 10
                top = y[0] - 20
                y[0] += FRAG_HEAD            # frame header + first guard
                ops = []
                for i, (guard, sub) in enumerate(operands):
                    operand = own(frag, element('UMLInteractionOperand', frag, '', guard=guard.strip('[]')),
                                  'operands')
                    otop = top + 20
                    if i:
                        otop = y[0] - 12      # separator, then this operand's guard
                        y[0] += FRAG_HEAD - 8
                    walk(sub, depth + 1)
                    ops.append((operand, otop))
                bottom_f = y[0] - 8
                frags.append((frag, kind, involved([s]), depth, top, bottom_f, ops))
                y[0] += FRAG_END + 10
                continue
            if kind == 'self':
                src = tgt = s[1]
                label = s[2]
            else:
                src, tgt, label = s[1], s[2], s[3]
            if src not in lifelines or tgt not in lifelines:
                model.errors.append(f'{sc["name"]} : ligne de vie inconnue dans {s}')
                continue
            sort = {'call': 'synchCall', 'async': 'asynchCall', 'reply': 'reply', 'create': 'createMessage',
                    'self': 'synchCall'}[kind]
            m = element('UMLMessage', inter, '', source=ref(lifelines[src]), target=ref(lifelines[tgt]),
                        messageSort=sort)
            name, args = label, None
            mm = re.match(r'^(\w+)\((.*)\)$', label)
            target_type = sc['lifelines'][tgt][1]
            target_key = target_type if target_type in model.classes else \
                resolve(model.classes, target_type, None, model.base)
            if mm and kind != 'reply' and (target_key, mm.group(1)) in model.ops:
                name, args = mm.group(1), mm.group(2)
                m['signature'] = ref(model.ops[(target_key, mm.group(1))])
                if args:
                    m['arguments'] = args
            m['name'] = name
            own(inter, m, 'messages')
            if kind == 'create':
                created[tgt] = y[0]
            msgs.append((m, kind, src, tgt, y[0]))
            y[0] += SELF_ROW if kind == 'self' else ROW + 14 if kind == 'reply' else ROW

    walk(sc['steps'], 0)
    bottom = y[0] + 20

    # Lifeline views (created ones start at their creation message)
    for key, v in lviews.items():
        if key in created:
            v['top'] = round(created[key] - 20)
        v['height'] = round(bottom - v['top'])
        name_c = ref_target(v, 'nameCompartment')
        name_c['left'], name_c['top'], name_c['width'], name_c['height'] = v['left'], v['top'], v['width'], HEAD_H
        line = ref_target(v, 'linePart')
        line['left'], line['top'] = round(center[key]), v['top'] + HEAD_H
        line['width'], line['height'] = 1, v['height'] - HEAD_H
        model.node(d, v)

    # Combined fragments (outer ones first, so they sit behind)
    for frag, kind, keys, depth, top, bottom_f, ops in sorted(frags, key=lambda f: f[3]):
        keys = [k for k in keys if k in lviews]
        if not keys:
            continue
        lefts = [lviews[k]['left'] for k in keys]
        rights = [lviews[k]['left'] + lviews[k]['width'] for k in keys]
        pad = 14 - 5 * depth
        left, right = min(lefts) - pad, max(rights) + pad
        if any(mk == 'self' and ms in keys for _, mk, ms, _, _ in msgs):
            right += 60
        fv = clone_view('UMLCombinedFragmentView', d, frag)
        fv['left'], fv['top'] = round(left), round(top)
        fv['width'], fv['height'] = round(right - left), round(bottom_f - top)
        comp = ref_target(fv, 'operandCompartment')
        comp['left'], comp['top'] = fv['left'], fv['top'] + 20
        comp['width'], comp['height'] = fv['width'], fv['height'] - 20
        tops = [t for _, t in ops] + [bottom_f]
        for i, (operand, otop) in enumerate(ops):
            ov = clone_view('UMLInteractionOperandView', comp, operand)
            ov['left'], ov['top'] = fv['left'], round(otop if i else fv['top'] + 20)
            ov['width'], ov['height'] = fv['width'], round(tops[i + 1] - ov['top'])
            comp.setdefault('subViews', []).append(ov)
        model.node(d, fv)

    # Message views
    for m, kind, src, tgt, my in msgs:
        tail = ref_target(lviews[src], 'linePart')
        head = ref_target(lviews[tgt], 'linePart')
        if kind == 'self':
            cx = center[src]
            pts = [(cx, my), (cx + 40, my), (cx + 40, my + 16), (cx, my + 16)]
        else:
            x1, x2 = center[src], center[tgt]
            if kind == 'create':
                x2 = lviews[tgt]['left'] if x2 > x1 else lviews[tgt]['left'] + lviews[tgt]['width']
            pts = [(x1, my), (x2, my)]
        mv = model.edge(d, 'UMLSeqMessageView', m, tail, head, pts, 0)
        act = sub_view(mv, 'UMLActivationView')
        act['left'], act['top'], act['width'], act['height'] = round(center[tgt] - 7), round(my), 14, 25
        act['visible'] = False

    right = max([v['left'] + v['width'] for v in lviews.values()] +
                [v['left'] + v['width'] for v in d['ownedViews'] if v['_type'] == 'UMLCombinedFragmentView']) + 30
    frame['left'], frame['top'], frame['width'], frame['height'] = 20, 16, round(right - 20), round(bottom + 10 - 16)


# ============================================================================ overview

OVERVIEW_COLUMNS = [
    ('Structure : paquets, composants, déploiement',
     ('UMLPackageDiagram', 'UMLComponentDiagram', 'UMLDeploymentDiagram')),
    ('Classes, par paquet', ('UMLClassDiagram',)),
    ('États', ('UMLStatechartDiagram',)),
    ('Séquences', ('UMLSequenceDiagram',)),
]


def overview(model, project, root):
    """00 · Vue d'ensemble: one hyperlink per diagram, by kind, under a heading note; double-clicking a
    link opens its diagram in StarUML."""
    d = own(root, element('UMLClassDiagram', root, model.diagram_name('overview', '00 · Vue d’ensemble'),
                          defaultDiagram=True,
                          documentation='Le point d’entrée de la documentation UML : un lien vers chaque diagramme. '
                                        'Double-cliquer un lien ouvre le diagramme.'))

    def diagrams(o, out):
        if isinstance(o, dict):
            if o.get('_type', '').endswith('Diagram') and o is not d:
                out.append(o)
            for k, v in o.items():
                if k not in ('_parent', 'ownedViews'):
                    diagrams(v, out)
        elif isinstance(o, list):
            for v in o:
                diagrams(v, out)
        return out

    found = sorted(diagrams(project, []), key=lambda x: x['name'])
    x, step = 40, 44
    title = clone_view('UMLNoteView', d)
    title.update(text=cfg(model.config, 'OVERVIEW_TEXT',
                          f'{project["name"]} — documentation UML\n\nGénérée à partir des sources. '
                          f'Double-cliquer un lien pour ouvrir le diagramme.'),
                 left=40, top=20, width=860, height=60)
    model.node(d, title)
    for heading, types in cfg(model.config, 'OVERVIEW_COLUMNS', OVERVIEW_COLUMNS):
        mine = [g for g in found if g['_type'] in types]
        if not mine:
            continue
        width = max([text_w(g['name']) for g in mine] + [text_w(heading)]) + 70
        note = clone_view('UMLNoteView', d)
        note.update(text=heading, left=x, top=110, width=round(width), height=30)
        model.node(d, note)
        y = 160
        for g in mine:
            link = own(root, element('Hyperlink', root, g['name'], reference=ref(g)))
            v = clone_view('HyperlinkView', d, link)
            v.update(left=x, top=y, width=round(width), height=32)
            model.node(d, v)
            y += step
        x += width + 40
    return d


# ============================================================================ build

def build(config, classes, sizes):
    model = Model(config, classes, sizes)
    project = model.project
    root = own(project, element('UMLModel', project, 'Documentation',
                                documentation='Le diagramme d’ensemble et ses liens vers tous les diagrammes.'))
    logical = own(project, element('UMLModel', project, 'Vue logique', documentation=cfg(
        config, 'LOGICAL_DOC', 'Paquets, classes et relations, lus dans les sources, types imbriqués compris.')))
    fp = build_logical(model, logical)
    package_diagram(model, fp)
    for spec in [diagram_spec(s) for s in cfg(config, 'CLASS_DIAGRAMS', [])] or auto_class_diagrams(model):
        class_diagram(model, spec)
    build_components(model, project)
    build_deployment(model, project)
    build_state_machines(model, project)
    build_scenarios(model, project)
    overview(model, project, root)
    if model.errors:
        raise ConfigError('\n'.join(dict.fromkeys(model.errors)))
    return project
