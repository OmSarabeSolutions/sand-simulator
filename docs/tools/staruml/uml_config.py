"""Description UML du projet TasDeSable - le seul fichier propre au projet de cet outillage.

Le reste du dossier (generate.py, swift_source.py, builder.py, *.js…) vient du skill swift-staruml-docs
et peut être remplacé à chaque mise à jour de l'outillage. Lancer docs/tools/staruml/build.sh
depuis n'importe où pour mettre à jour docs/uml/tasdesable.mdj et ses images.

Les noms de classes s'écrivent comme dans le code : Nom, Externe.Interne, ou paquet.Nom
quand le nom simple existe dans deux paquets. Un nom inconnu arrête la génération
avec la liste de ce qui est à corriger.
"""

PROJECT_NAME = 'TasDeSable'
PROJECT_DOC = ('Simulateur de tas de sable de Bak, Tang et Wiesenfeld (1987) pour macOS, en Swift 6, '
               'SwiftUI et Metal : ajout aléatoire et criticalité auto-organisée, versement central, '
               'tas divisible et comparaison de quatre tas.')
ID_PREFIX = 'TasDeSab'       # préfixe des identifiants des nouveaux éléments (8 octets au plus)

# Chemins, relatifs à la racine du dépôt (ROOT est relatif à ce fichier)
ROOT = '../../..'
MODEL = 'docs/uml/tasdesable.mdj'
IMAGES = 'docs/uml/images'
ENGINE = ''                     # moteur StarUML (metadata-json) ; '' : ~/.cache/staruml/metadata-json

# ---------------------------------------------------------------------------- vue logique
# Lue dans les sources Swift et les shaders Metal. Un paquet = la cible (module) puis ses dossiers ;
# les paquets sont relatifs à BASE_PACKAGE (la cible, quand il n'y en a qu'une).
LANGUAGE = 'swift'
SOURCE_ROOTS = [
    'TasDeSable',
]
SWIFT_MODULES = {
    'TasDeSable': 'TasDeSable',
}            # dossier -> nom de la cible (module)
BASE_PACKAGE = 'TasDeSable'
BASE_PACKAGE_DOC = None

# Shaders Metal (.metal) : une classe «metal» par fichier, ses fonctions kernel / vertex / fragment en
# opérations et ses structs en classes imbriquées «metal struct»
SHADERS = True
SHADER_CLASS_NAME = '{stem}Shaders'

# Conformances à ne pas dessiner, en plus de Sendable, Equatable, Identifiable, CaseIterable, Codable…
IGNORED_CONFORMANCES = []
# Classes de frameworks dont une classe du projet peut hériter, en plus de NSObject, NSView, MTKView…
SUPERCLASSES = []
# Montrer aussi les types private / fileprivate
INCLUDE_PRIVATE_TYPES = False

# Module (Maven/Gradle) de chaque paquet - documentation des paquets
MODULE_OF = {}

# Documentation des paquets : paquet relatif -> texte (sinon « Module x. »)
PACKAGE_DOCS = {
    'App': 'Point d’entrée SwiftUI : crée les réglages et le modèle, déclare la fenêtre et la page de réglages.',
    'Settings': 'Réglages persistés (taille de la grille, seuil, affichage, grains à déverser) et leur page.',
    'Model': 'Grilles, moteurs de bascule (CPU exact, GPU parallèle), statistiques et état de la simulation.',
    'Metal': 'Rendu 3D des colonnes (MetalKit), caméra orbitale et shaders Metal (calcul et rendu).',
    'Views': 'Vues SwiftUI : fenêtre principale, panneaux des quatre expériences, palette de couleurs.',
}

# Ordre des paquets du diagramme « 01 · Paquets » ; [] : tous les paquets
PACKAGE_ORDER = ['App', 'Settings', 'Views', 'Model', 'Metal']

# Supertypes externes : nom -> (bibliothèque, est une interface). Ceux qui manquent sont
# ajoutés automatiquement avec le stéréotype «externe».
EXTERNAL = {}

# Classes à ne pas montrer (clés)
EXCLUDED_CLASSES = []

# Classes à ajouter à la main (code généré, autre langage…) :
#   (paquet, Nom, 'class' | 'interface' | 'enum', stéréotype ou None ('record', 'controller'…),
#    ['attribut: Type', ...] (ou les littéraux d'une enum), ['op(p: Type): Retour', ...], documentation)
MANUAL_CLASSES = []
#   (generalization | realization | dependency, source, cible)
MANUAL_RELATIONS = []

# ---------------------------------------------------------------------------- diagrammes de classes
# [] : un diagramme par paquet (10 · Classes — paquet…), avec les membres s'il a au plus
# AUTO_MEMBERS_MAX_CLASSES classes. Sinon, une entrée par diagramme, numérotés de 10 à 29 :
#   {'name': '10 · Classes — …', 'package': 'paquet relatif propriétaire', 'classes': ['A', 'B.C'],
#     'doc': 'ce que montre le diagramme', 'members': True, 'rankdir': 'TB' | 'LR'}
CLASS_DIAGRAMS = [
    {'name': '10 · Classes — réglages et application', 'package': 'Settings',
     'classes': ['TasDeSableApp', 'AppSettings', 'DisplayMode', 'AppLanguage', 'CellPalette', 'SettingsView'],
     'doc': 'Les réglages persistés (taille, seuil, affichage, langue, palette), leur page et l’application '
            'qui les partage avec le modèle.',
     'members': True, 'rankdir': 'TB'},
    {'name': '11 · Classes — grille et moteurs de bascule', 'package': 'Model',
     'classes': ['Grid', 'SandpileEngine', 'CPUSandpile', 'GPUSandpile', 'ToppleOrder', 'ToppleScratch',
                 'Avalanche', 'RandomDropper', 'CenterDropper', 'ToppleParams', 'DivisibleParams', 'GPUSandpileError',
                 'SandpileShaders', 'SandpileShaders.ToppleParams', 'SandpileShaders.DivisibleParams'],
     'doc': 'La grille, les deux moteurs qui la stabilisent (CPU exact, GPU parallèle), les kernels de Sandpile.metal et les structures partagées avec Swift.',
     'members': True, 'rankdir': 'TB'},
    {'name': '12 · Classes — état de la simulation', 'package': 'Model',
     'classes': ['SimulationModel', 'SimulationMode', 'SimulationState', 'AvalancheStats', 'HistogramBin',
                 'RenderSnapshot', 'ValueKind', 'AbelianReport', 'DivisibleReport', 'ComparisonPile'],
     'doc': 'Le modèle observable de l’interface : expériences, résultats et image envoyée au rendu.',
     'members': True, 'rankdir': 'LR'},
    {'name': '13 · Classes — rendu Metal', 'package': 'Metal',
     'classes': ['MetalView', 'MetalView.Coordinator', 'OrbitMTKView', 'SandpileRenderer', 'OrbitCamera', 'Matrix',
                 'RenderUniforms', 'RenderShaders', 'RenderShaders.RenderUniforms', 'RenderShaders.VertexOut'],
     'doc': 'La vue MetalKit, le renderer qui dessine une colonne instanciée par case, et la caméra orbitale.',
     'members': True, 'rankdir': 'TB'},
    {'name': '14 · Classes — vues SwiftUI', 'package': 'Views',
     'classes': ['ContentView', 'SimulationCanvas', 'RandomDropPanel', 'CentralPourPanel', 'DivisiblePanel',
                 'DiscOverlay', 'ComparisonView', 'StatRow', 'Palette', 'PaletteLegend', 'PaletteSwatch',
                 'AvalancheHistogram'],
     'doc': 'La fenêtre principale, les panneaux des quatre expériences et la palette partagée avec le shader.',
     'members': False, 'rankdir': 'LR'},
]
AUTO_MEMBERS_MAX_CLASSES = 20

# ---------------------------------------------------------------------------- composants
# Vides, ils sont déduits du code (AUTO_COMPONENTS) : un composant par paquet de premier niveau,
# ses dépendances d'après celles de ses classes. Décrits ici, ils remplacent la déduction :
#   clé -> (nom, stéréotype, documentation, [interfaces fournies], [interfaces requises])
# Les interfaces sont des classes de la vue logique ; avec au moins une, le diagramme
# « 03 · Composants — interfaces fournies et requises » est ajouté.
AUTO_COMPONENTS = True
COMPONENTS = {}
# (composant, composant dont il dépend[, libellé])
COMPONENT_USES = []
# Bibliothèques et fichiers : clé -> (nom, 'library' | 'resource' | 'file' | 'external', documentation).
# AUTO_LIBRARIES ajoute les frameworks et paquets Swift importés (sauf IGNORED_MODULES, et Foundation,
# Observation, os…), les paquets déclarés (Package.swift, project.yml, .xcodeproj) et les fichiers .metal,
# avec qui les utilise ; ce qui est décrit ici est gardé tel quel.
AUTO_LIBRARIES = True
IGNORED_MODULES = []
LIBRARIES = {}
# (composant, bibliothèque[, libellé])
LIBRARY_USES = []
# Trouvé dans le code :
#   import Charts : Views
#   import CoreGraphics : Views
#   import Foundation : Metal, Model, Settings
#   import Metal : Metal, Model
#   import MetalKit : Metal
#   import Observation : Model, Settings
#   import SwiftUI : App, Metal, Settings, Views
#   import simd : Metal
#   shader TasDeSable/Metal/Render.metal
#   shader TasDeSable/Metal/Sandpile.metal

# ---------------------------------------------------------------------------- déploiement
# clé -> (nom, 'device' | 'executionEnvironment' | 'node', documentation) ; vide : pas de diagramme
DEPLOYMENT_NODES = {
    'mac': ('Mac (Apple Silicon)', 'device', 'macOS 15 ou plus récent.'),
    'process': ('Processus TasDeSable', 'executionEnvironment',
                'Application SwiftUI : thread principal (MainActor), tâches détachées pour les ajouts de grains.'),
    'gpu': ('GPU Apple', 'device', 'Exécute les kernels de calcul et le pipeline de rendu.'),
    'storage': ('UserDefaults', 'node', 'Domaine de préférences de l’application.'),
}
# (nœud, nœud, libellé : protocole, port…)
NETWORK = [
    ('mac', 'process', 'lance'),
    ('process', 'gpu', 'Metal : command buffers compute (topple, divisible)'),
    ('process', 'gpu', 'Metal : rendu 60 i/s (cellVertex, cellFragment)'),
    ('process', 'storage', 'réglages'),
]
DEPLOYMENT_DOC = 'Application locale, sans réseau : un processus, le GPU intégré et les préférences.'

# ---------------------------------------------------------------------------- machines à états
# Décrites dans uml_scenarios.py, avec les séquences.
from uml_scenarios import STATE_MACHINES_TASDESABLE, SCENARIOS_TASDESABLE
# Diagrammes 30 à 39, décrits d'après le code :
#   {'name': '30 · États — …', 'owner': 'Classe', 'doc': '…',
#     'states': {'i': ('', 'initial', {}), 'a': ('Nom', 'state', {'entry': '…', 'do': '…', 'exit': '…'}),
#                'c': ('', 'choice', {}), 'f': ('', 'final', {})},
#     'transitions': [('i', 'a', 'déclencheur', 'garde', 'effet'), ...]}
STATE_MACHINES = STATE_MACHINES_TASDESABLE

# ---------------------------------------------------------------------------- séquences
# Acteurs des scénarios : nom -> documentation
ACTORS = {'Utilisateur': 'La personne qui utilise l’application.'}
# Diagrammes 40 et suivants, décrits d'après le code :
#   {'name': '40 · Séquence — …', 'doc': '…',
#     'lifelines': {'u': ('', 'Utilisateur'), 'svc': ('', 'Classe'), 'b': ('rôle', 'Autre')},
#     'steps': [('call', 'u', 'svc', 'op(args)'), ('async', a, b, '…'), ('reply', b, a, '…'),
#               ('create', a, b, 'new B()'), ('self', a, 'op()'),
#               ('alt', [('[garde]', [étapes]), ('[sinon]', [étapes])]), ('opt', '[garde]', [étapes]),
#               ('loop', '[pour chaque …]', [étapes])]}
# Un message 'op(args)' vers une classe qui a l'opération op y est lié.
SCENARIOS = SCENARIOS_TASDESABLE

# Noms des diagrammes générés, à changer au besoin :
#   'overview', 'packages', 'components', 'interfaces', 'deployment'
DIAGRAM_NAMES = {'deployment': '04 · Déploiement — processus, GPU et préférences'}

# Diagramme « 00 · Vue d’ensemble » : texte de la note de titre, et colonnes de liens
#   [(titre de colonne, ('UMLClassDiagram', ...)), ...] ; None : textes par défaut
OVERVIEW_TEXT = None
OVERVIEW_COLUMNS = None
