#!/usr/bin/env bash
# Lance les tests avec la couverture du code, puis affiche le rapport par fichier.
#
#   scripts/coverage.sh            rapport dans le terminal
#   scripts/coverage.sh --json     écrit aussi build/coverage.json (rapport complet de xccov)
#
# Le résultat brut est dans build/coverage.xcresult (s'ouvre dans Xcode : onglet Coverage).
set -euo pipefail
cd "$(dirname "$0")/.."
# Utiliser Xcode même si xcode-select pointe sur les Command Line Tools
if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
RESULT=build/coverage.xcresult
rm -rf "$RESULT"
command -v xcodegen > /dev/null && xcodegen generate --quiet
xcodebuild -project TasDeSable.xcodeproj -scheme TasDeSable -derivedDataPath build \
  -enableCodeCoverage YES -resultBundlePath "$RESULT" test 2>&1 \
  | grep -E '✔ Test run|✘|error:|\*\* TEST' || true
[[ -d $RESULT ]] || { echo "Pas de résultat de test : $RESULT" >&2; exit 1; }

xcrun xccov view --report --json "$RESULT" > build/coverage.json
python3 - build/coverage.json <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
for target in report['targets']:
    if not target['name'].startswith('TasDeSable.app'):
        continue
    print(f"\n{target['name']} : {target['lineCoverage']:.1%} "
          f"({target['coveredLines']} / {target['executableLines']} lignes)\n")
    files = sorted(target['files'], key=lambda f: f['lineCoverage'])
    width = max(len(f['name']) for f in files)
    for f in files:
        bar = '█' * round(f['lineCoverage'] * 20)
        print(f"  {f['name']:<{width}}  {f['lineCoverage']:6.1%}  {bar:<20}  "
              f"{f['coveredLines']:>4} / {f['executableLines']:<4}")
PY
if [[ ${1:-} != --json ]]; then rm -f build/coverage.json; fi
