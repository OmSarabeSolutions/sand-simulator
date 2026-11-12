#!/usr/bin/env bash
# Met à jour le modèle StarUML du projet à partir des sources - en gardant ce qui a été fait à la main
# dans StarUML - puis redessine ses images PNG. Chemins et contenu : uml_config.py, à côté de ce script.
#
#   <outils>/build.sh            mise à jour (fusion avec le fichier existant)
#   <outils>/build.sh --fresh    régénération complète : perd les retouches faites dans StarUML
#
# Nécessite python3 et Graphviz (dot). Pour les tailles exactes et les images, aussi git, Node.js et npm :
# le moteur de StarUML (metadata-json) est récupéré une fois dans $STARUML_ENGINE
# (par défaut ~/.cache/staruml/metadata-json, ou ~/.cache/nunami/metadata-json s'il existe déjà).
set -euo pipefail
TOOLS=$(cd "$(dirname "$0")" && pwd)
FRESH=${1:-}
MODEL=$(python3 "$TOOLS/generate.py" --print model)
IMAGES=$(python3 "$TOOLS/generate.py" --print images)
ENGINE=${STARUML_ENGINE:-$(python3 "$TOOLS/generate.py" --print engine)}
if [[ -z $ENGINE ]]; then
  ENGINE=$HOME/.cache/staruml/metadata-json
  [[ ! -d $ENGINE && -d $HOME/.cache/nunami/metadata-json ]] && ENGINE=$HOME/.cache/nunami/metadata-json
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/staruml.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export NODE_NO_WARNINGS=1

command -v dot > /dev/null || { echo "Graphviz (dot) est requis : brew install graphviz" >&2; exit 1; }
if [[ ! -d $ENGINE ]]; then
  mkdir -p "$(dirname "$ENGINE")"
  git clone --depth 1 https://github.com/staruml/metadata-json.git "$ENGINE"
  (cd "$ENGINE" && npm install --no-save fs-extra@0.12.0 ejs@1.0.0 markdown@0.5.0 escape-html@1.0.1 canvas@3 \
     && (node -e "require('canvas')" 2>/dev/null || npm rebuild canvas))
fi

if [[ -f $MODEL && $FRESH != --fresh ]]; then
  cp "$MODEL" "$WORK/before.mdj"
  [[ -f ${MODEL%.mdj}.generated.json ]] && cp "${MODEL%.mdj}.generated.json" "$WORK/before.generated.json"
fi
# 1. Une fusion d'essai, pour mesurer les vues comme StarUML les dessine
python3 "$TOOLS/generate.py" ${FRESH:+--fresh} --base "$MODEL" --out "$WORK/trial.mdj" > /dev/null
node "$TOOLS/measure.js" "$ENGINE" "$WORK/trial.mdj" "$WORK/sizes.json"
# 2. La vraie fusion, dans le modèle, avec les tailles mesurées
python3 "$TOOLS/generate.py" ${FRESH:+--fresh} --sizes "$WORK/sizes.json"
# 3. Rien de ce qui était là ne doit avoir bougé
if [[ -f $WORK/before.mdj ]]; then
  python3 "$TOOLS/check_preserved.py" "$WORK/before.mdj" "$MODEL"
fi
rm -rf "$IMAGES"
node "$TOOLS/render.js" "$ENGINE" "$MODEL" "$IMAGES"
