#!/usr/bin/env python3
"""Updates the StarUML model of the project described by uml_config.py (next to this file).

    python3 generate.py [--sizes sizes.json] [--base in.mdj] [--out out.mdj] [--fresh]
    python3 generate.py --print root|model|images|engine

build.sh runs the whole update: trial merge, measure, real merge, check, render.
Needs Graphviz (`dot`) for the layout.

The logical model is read from the Swift sources and their Metal shaders (LANGUAGE = 'swift',
swift_source.py) or from Java sources (LANGUAGE = 'java', java_source.py), under SOURCE_ROOTS;
other classes can be described by hand (MANUAL_CLASSES). For Swift, the components, the
frameworks and packages imported and the shader files are found in the code too, unless
uml_config.py describes them (AUTO_COMPONENTS, AUTO_LIBRARIES). Components, deployment,
state machines and sequence diagrams are described in uml_config.py, from the
code they document.

The freshly built model is then MERGED into the existing file (merge.py): what
was arranged or added by hand in StarUML - layout, styles, notes, diagrams -
is kept; only what is new in the code is added, and what disappeared from it
removed. `--fresh` ignores the existing file and loses all of that.
"""
import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import builder      # noqa: E402
import core         # noqa: E402
import java_source  # noqa: E402
import merge        # noqa: E402
import swift_source  # noqa: E402


def load_config():
    spec = importlib.util.spec_from_file_location('uml_config', os.path.join(HERE, 'uml_config.py'))
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)
    return config


def paths(config):
    root = os.path.normpath(os.path.join(HERE, getattr(config, 'ROOT', '../../..')))
    return {'root': root,
            'model': os.path.join(root, config.MODEL),
            'images': os.path.join(root, getattr(config, 'IMAGES', os.path.join(os.path.dirname(config.MODEL),
                                                                                  'images'))),
            'engine': os.path.expanduser(getattr(config, 'ENGINE', '') or '')}


def read_classes(config, root):
    roots = [os.path.join(root, r) for r in getattr(config, 'SOURCE_ROOTS', [])]
    base = getattr(config, 'BASE_PACKAGE', '')
    if getattr(config, 'LANGUAGE', 'swift') == 'swift':
        modules = {os.path.join(root, r): m for r, m in (getattr(config, 'SWIFT_MODULES', {}) or {}).items()}
        classes = swift_source.read_classes(
            roots, base, modules, root, shaders=getattr(config, 'SHADERS', True),
            shader_name=getattr(config, 'SHADER_CLASS_NAME', '{stem}Shaders'),
            ignored=getattr(config, 'IGNORED_CONFORMANCES', []),
            superclasses=getattr(config, 'SUPERCLASSES', []),
            include_private_types=getattr(config, 'INCLUDE_PRIVATE_TYPES', False))
    else:
        classes = java_source.read_classes(roots, base)
    manual = getattr(config, 'MANUAL_CLASSES', [])
    if manual:
        java_source.manual_classes(manual, getattr(config, 'MANUAL_RELATIONS', []), classes)
    for k in getattr(config, 'EXCLUDED_CLASSES', []):
        classes.pop(k, None)
    if getattr(config, 'LANGUAGE', 'swift') == 'swift':
        for c in classes.values():               # what a type depends on must still exist
            c['deps'] = [d for d in c['deps'] if d in classes]
        swift_source.auto_dependencies(config, classes, root)
    return classes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sizes', help='exact view sizes measured by measure.js on a trial merge')
    ap.add_argument('--out', help='default: MODEL of uml_config.py')
    ap.add_argument('--base', help='the existing model to merge into (default: --out)')
    ap.add_argument('--fresh', action='store_true',
                    help='ignore the existing file - discards every change made in StarUML')
    ap.add_argument('--print', choices=['root', 'model', 'images', 'engine'], dest='show',
                    help='print a path of the configuration and stop')
    args = ap.parse_args()

    config = load_config()
    p = paths(config)
    if args.show:
        print(p[args.show])
        return
    out = os.path.abspath(args.out) if args.out else p['model']
    base = os.path.abspath(args.base) if args.base else out
    os.chdir(p['root'])

    old = None
    if os.path.exists(base) and not args.fresh:
        old = json.load(open(base, encoding='utf-8'))
    base_manifest = os.path.splitext(base)[0] + '.generated.json'
    manifest = json.load(open(base_manifest, encoding='utf-8')) if os.path.exists(base_manifest) and old else None
    manifest_file = os.path.splitext(out)[0] + '.generated.json'
    classes = read_classes(config, p['root'])
    prefix = getattr(config, 'ID_PREFIX', None) or getattr(config, 'PROJECT_NAME', 'UML')

    def generate(sizes):
        core.reset_ids(prefix)
        return builder.build(config, classes, sizes)

    try:
        project = generate({})
        if args.sizes:
            # Sizes are measured on the merged file: look them up by the id each view will get
            measured = json.load(open(args.sizes))
            ids = merge.final_ids(project, old)
            project = generate({g: measured[f] for g, f in ids.items() if f in measured})
    except builder.ConfigError as e:
        print('uml_config.py à corriger :\n' + '\n'.join('  ' + x for x in str(e).splitlines()), file=sys.stderr)
        sys.exit(2)

    project, new_manifest, report = merge.merge(project, old, manifest)
    merge.update_overview(project, report)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(project, f, indent='\t', ensure_ascii=False)
    with open(manifest_file, 'w', encoding='utf-8') as f:
        json.dump(new_manifest, f, indent=1, ensure_ascii=False)
    print(f'  {len(classes)} classes lues')
    for line in report:
        print('  ' + line)
    print('écrit', os.path.relpath(out, p['root']))


if __name__ == '__main__':
    main()
