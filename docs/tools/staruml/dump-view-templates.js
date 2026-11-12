// Dumps a fresh instance of each view type the generator uses, exactly as
// StarUML's own constructors build it, into view-templates.json.
//   node dump-view-templates.js <metadata-json dir> view-templates.json
var path = require("path");
var mdjson = require(path.resolve(process.argv[2], "metadata-json"));
var type = require(require.resolve("requirejs", { paths: [path.resolve(process.argv[2])] }))("core/Global").global.type;
var names = ["UMLClassView", "UMLInterfaceView", "UMLEnumerationView", "UMLPackageView", "UMLComponentView",
  "UMLNodeView", "UMLArtifactView", "UMLGeneralizationView", "UMLInterfaceRealizationView", "UMLAssociationView",
  "UMLDependencyView", "UMLCommunicationPathView", "UMLAttributeView", "UMLOperationView",
  "UMLEnumerationLiteralView", "UMLFrameView", "UMLSeqLifelineView", "UMLSeqMessageView",
  "UMLCombinedFragmentView", "UMLInteractionOperandView", "UMLStateView", "UMLPseudostateView",
  "UMLFinalStateView", "UMLTransitionView", "UMLNoteView", "UMLNoteLinkView", "HyperlinkView"];
var out = {};
names.forEach(function (n) {
    if (!type[n]) { console.error("type inconnu : " + n); process.exit(1); }
    out[n] = JSON.parse(mdjson.Repository.writeObject(new type[n]()));
});
require("fs").writeFileSync(process.argv[3], JSON.stringify(out, null, 1));
console.log(names.length + " gabarits");
