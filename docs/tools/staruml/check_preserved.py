#!/usr/bin/env python3
"""Checks that a regenerated .mdj kept what was done by hand before: every view
of the old file still there, unchanged (position, size, route, style).

A view may only go with what it shows: its diagram (no longer generated), its
model element (removed from the code, or a hyperlink to a removed diagram), or
because the generator no longer produces it - it is in the manifest of the old
file (<before>.generated.json) and not in the new one.

    python3 <outils>/check_preserved.py <before.mdj> <after.mdj>
"""
import json
import os
import sys

from merge import index, is_view, keys_of, relaid


def manifest_of(mdj):
    path = os.path.splitext(mdj)[0] + '.generated.json'
    return json.load(open(path, encoding='utf-8')) if os.path.exists(path) else None


def main(before, after):
    old, new = json.load(open(before, encoding='utf-8')), json.load(open(after, encoding='utf-8'))
    oobjs, opar = index(old)
    nobjs, _ = index(new)
    views = [i for i in oobjs if opar[i][1] == 'ownedViews']
    before_m, after_m = manifest_of(before), manifest_of(after)
    no_longer_generated = set()
    if before_m is not None and after_m is not None:
        okeys = keys_of(old)
        for i in views:
            d = okeys[opar[i][0]['_id']]
            previous, wanted = set(before_m.get(d, [])), set(after_m.get(d, []))
            if okeys[i] in previous and (okeys[i] not in wanted or relaid(previous, wanted)):
                no_longer_generated.add(i)      # gone, or laid out again
    changed, lost, expected = [], [], 0
    for oid in views:
        o = oobjs[oid]
        if oid in nobjs:
            if nobjs[oid] != o and oid not in no_longer_generated:
                changed.append(o)
            continue
        model = o.get('model', {}).get('$ref') if isinstance(o.get('model'), dict) else None
        if opar[oid][0]['_id'] not in nobjs or (model and model not in nobjs) or oid in no_longer_generated:
            expected += 1
        else:
            lost.append(o)
    gone = [o for i, o in oobjs.items() if not is_view(opar[i][1]) and i not in nobjs]
    print(f'vues : {len(views)} avant, {len(changed)} modifiée(s), {len(lost)} perdue(s), '
          f'{expected} retirée(s) ou redisposée(s) volontairement')
    print(f'éléments retirés : {len(gone)}')
    for o in (changed + lost)[:20]:
        print('  vue', o['_type'], o['_id'])
    for o in gone[:20]:
        print('  élément', o['_type'], o.get('name', ''))
    return 0 if not (changed or lost) else 1


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:3]))
