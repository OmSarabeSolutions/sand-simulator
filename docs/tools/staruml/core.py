"""Building blocks of a StarUML model: elements, ids, views and the Graphviz layout.

Views are copies of view-templates.json - the views exactly as StarUML's own
constructors create them (see dump-view-templates.js). StarUML recomputes label
texts and minimum sizes when it draws a diagram, so the generator only has to
place the nodes.
"""
import base64
import copy
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = json.load(open(os.path.join(HERE, 'view-templates.json')))

# ============================================================================ ids

_state = {'counter': 0, 'prefix': b'UML'}


def reset_ids(prefix):
    """Stable, unique ids - the same project always yields the same file."""
    _state['counter'] = 0
    _state['prefix'] = prefix.encode()[:8] if isinstance(prefix, str) else prefix[:8]


def new_id():
    _state['counter'] += 1
    return base64.b64encode(_state['prefix'] + _state['counter'].to_bytes(6, 'big')).decode()


def ref(element):
    return {'$ref': element['_id']}


def element(type_, parent, name=None, **fields):
    e = {'_type': type_, '_id': new_id()}
    if parent is not None:
        e['_parent'] = ref(parent)
    if name is not None:
        e['name'] = name
    e.update(fields)
    return e


def own(parent, child, field='ownedElements'):
    parent.setdefault(field, []).append(child)
    return child


# ============================================================================ views

def clone_view(type_, parent_view_or_diagram, model=None, **fields):
    """A view of `type_` - a fresh copy of StarUML's own template, with new ids."""
    tpl = copy.deepcopy(TEMPLATES[type_])
    ids = {}

    def collect(o):
        if isinstance(o, dict):
            if '_id' in o:
                ids[o['_id']] = new_id()
            for v in o.values():
                collect(v)
        elif isinstance(o, list):
            for v in o:
                collect(v)

    def remap(o):
        if isinstance(o, dict):
            if '_id' in o:
                o['_id'] = ids[o['_id']]
            if '$ref' in o and o['$ref'] in ids:
                o['$ref'] = ids[o['$ref']]
            for v in o.values():
                remap(v)
        elif isinstance(o, list):
            for v in o:
                remap(v)

    collect(tpl)
    remap(tpl)
    tpl['_parent'] = ref(parent_view_or_diagram)

    # Every sub view shows the same model element; edge labels belong to their edge
    def set_parents(v):
        for s in v.get('subViews', []):
            s['_parent'] = ref(v)
            if model is not None and 'model' not in s and s['_type'] != 'LabelView':
                s['model'] = ref(model)
            set_parents(s)
    set_parents(tpl)
    if model is not None:
        tpl['model'] = ref(model)
    tpl.update(fields)
    return tpl


def sub_view(view, type_):
    return next(s for s in view['subViews'] if s['_type'] == type_)


def ref_target(view, field):
    rid = view[field]['$ref']

    def find(v):
        if v.get('_id') == rid:
            return v
        for s in v.get('subViews', []):
            r = find(s)
            if r:
                return r
    return find(view)


# ============================================================================ layout

CHAR_W = 7.2      # Arial 13, average - a little generous on purpose
BOLD_W = 8.0
LINE_H = 15


def text_w(s, w=CHAR_W):
    return len(s) * w


def graphviz(nodes, edges, rankdir='TB', nodesep=0.5, ranksep=0.7, extra='', labels=None):
    """nodes: {key: (w, h)} in px; edges: [(a, b)], with optional `labels` (one text
    per edge, to leave room for it). Returns centers {key: (x, y)} and edge
    polylines {index: [(x, y), ...]} in px, y downwards."""
    lines = [f'digraph G {{ rankdir={rankdir}; nodesep={nodesep}; ranksep={ranksep}; '
             f'splines=polyline; {extra}',
             '  node [shape=box fixedsize=true label=""];']
    for k, (w, h) in nodes.items():
        lines.append(f'  "{k}" [width={w / 72:.3f} height={h / 72:.3f}];')
    for i, (a, b) in enumerate(edges):
        label = (labels or [''] * len(edges))[i].replace('"', "'")
        lab = f' label="{label}" fontname="Arial" fontsize=13' if label else ''
        lines.append(f'  "{a}" -> "{b}" [id="e{i}"{lab}];')
    lines.append('}')
    out = subprocess.run(['dot', '-Tjson'], input='\n'.join(lines), capture_output=True, text=True,
                         check=True).stdout
    g = json.loads(out)
    H = float(g['bb'].split(',')[3])
    centers = {}
    for o in g.get('objects', []):
        if 'pos' in o:
            x, y = map(float, o['pos'].split(','))
            centers[o['name']] = (x, H - y)
    routes = {}
    for e in g.get('edges', []):
        pts = []
        for p in e['pos'].split(' '):
            if p.startswith(('e,', 's,')):
                continue
            x, y = map(float, p.split(','))
            pts.append((x, H - y))
        # a polyline spline repeats each corner - keep the corners only
        corners = pts[::3] if len(pts) > 4 else [pts[0], pts[-1]]
        routes[int(e['id'][1:])] = corners
    return centers, routes


def points_str(pts):
    return ';'.join(f'{round(x)}:{round(y)}' for x, y in pts)
