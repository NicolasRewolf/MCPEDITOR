# Vocabulaire et flux de MPC Kit Studio

Clarifié avec Nicolas le 17 octobre 2026. Ce document distingue le besoin produit de l’état livré ; il ne relance pas UNDERSTAND.

## Objets du domaine

- **Sample** : un son utilisé dans une composition. Une occurrence de fichier possède un emplacement et une provenance. Un nom commun ou une empreinte identique ne justifie pas une fusion automatique.
- **Programme `.PGM`** : une composition intentionnelle de pads et de paramètres qui référence des sons externes `.SND`. Nicolas emploie désormais `.PGM` pour cet objet dans toute l’interface. Pour le transporter, les SND référencés doivent aussi être disponibles ; le fichier PGM seul ne contient pas leur audio.
- **Bibliothèque** : l’ensemble dans lequel retrouver samples et .PGM. L’attente de Nicolas est une collection durable de .PGM composés par style ou intention, utilisable indépendamment de la présence de la SD.
- **PART** : un emplacement sur la SD, avec sa capacité et son état d’inventaire. Ce n’est ni un genre musical ni l’identité d’un .PGM.
- **Copie enregistrée** : un nouveau PGM et ses sons écrits dans un dossier choisi. Une copie sur la SD constitue un emplacement de transport ; elle ne crée pas implicitement une sauvegarde sur le Mac.
- **Association sample–PGM** : une référence vérifiée depuis un PGM vers un SND, avec provenance et niveau de certitude. Elle peut être multiple. Une absence de référence dans un relevé partiel ne signifie pas que le son est inutilisé.

## Flux attendu, exprimé par Nicolas

Composer un .PGM → le conserver dans sa bibliothèque → composer d’autres .PGM → choisir ceux à envoyer sur la SD avec leurs sons → retrouver chaque .PGM par sa PART et son nom de fichier.

Les vues souhaitées sont trois lectures cohérentes : Samples avec leurs .PGM et emplacements ; .PGM avec leurs copies présentes sur SD ; PART avec leur contenu. Le classement historique et les créations récentes doivent coexister sans réécrire les originaux.

## État livré en 0.6.0 (17)

L’app mémorise des dossiers, indexe leurs PGM et ceux des PART montées, permet la composition en mémoire et écrit des copies vers une destination validée. La bibliothèque propose trois vues : `.PGM`, Samples et PART. Samples réunit les sons visibles sur la SD ou parcourt une source choisie ; chaque occurrence garde son chemin. Depuis un PGM, « Voir les samples » montre ses références résolues sans remplacer le document ouvert. Depuis un sample, les liens indiquent chaque PGM enregistré qui le référence et son emplacement.

Les associations sont un relevé en mémoire, recalculé en lecture seule depuis les PGM et les en-têtes SND. La même résolution de noms sert à l’ouverture et à l’index des associations. Aucun audio n’est décodé pour cet index ; aucun tag n’est injecté dans les SND. Une référence ambiguë ou illisible demeure non résolue. Une absence de lien ne prouve pas qu’un son est inutilisé, notamment en présence d’un inventaire incomplet ou d’autres formats.

Une copie locale est conservée dans un dossier ajouté à la bibliothèque ; une copie uniquement sur SD n’a pas de sauvegarde locale implicite. La dernière copie du document courant est identifiée par son chemin. Le catalogue durable indépendant des supports et le suivi de filiation entre plusieurs copies d’un PGM ne sont pas implémentés : noms ou empreintes identiques ne regroupent pas automatiquement des occurrences.

La marque MPC Kit Studio et les identifiants internes restent stables. Cette passe ajoute la lecture des associations et simplifie leur navigation ; les formats de fichiers et les protections d’écriture restent inchangés.

## Contraintes de cette passe

Déboguer et simplifier l’existant, sans ajouter de nettoyage automatique, d’écrasement ou de déplacement. SD en lecture uniquement pour l’investigation ; tests d’écriture sur dossiers locaux. Une PART invérifiable n’est jamais proposée comme vide. Les SEQ, APS, ALL et champs inconnus empêchent de déduire une autorisation de suppression d’une simple absence de référence PGM.

## Correction du flux en 0.7.0 (20), 26 octobre 2026

L’action **Enregistrer** conserve maintenant un PGM et ses SND dans une collection locale gérée par l’app,
indépendante des supports externes. Seule sa version courante apparaît dans la bibliothèque. Les anciennes
révisions sont conservées pour récupération, sans effacement automatique ; elles occupent de l’espace disque.
L’action **Copier sur la SD…** utilise toujours les protections de destination existantes et ne change ni le nom
ni l’état enregistré du document local. Les fichiers sources externes restent intacts.

Les éditions ont un historique borné d’annulation/rétablissement. Déplacer des pads échange les correspondances
pad→note afin de préserver tous les paramètres natifs ; copier une affectation partage son sample. Samples
s’ouvre sur la bibliothèque et la SD et possède un retour conservant recherche et sélection.

Le suivi durable de filiation entre la collection et ses copies SD hors ligne reste absent. Aucun tag n’est écrit
dans les sons, aucune migration des sources historiques n’est automatique, aucune compatibilité matérielle
nouvelle n’est déduite des tests logiciels. UNDERSTAND demeure en pause.

## Correctifs de revue en 0.7.1 (21), 5 novembre 2026

Revue du code, de l’app installée et d’une SD réelle en lecture seule (26 PART FAT12 de 8,2 Mo, 304 SND, 13 PGM).
Le but reste un outil pour bâtir des banks de samples, pas une MPC logicielle.

- Interface déclarée en français (`CFBundleDevelopmentRegion`, `fr.lproj`) : menus « Fichier… » et tailles « Mo »
  au lieu de « File » et « MB ».
- Une seule fenêtre, sans onglets. Le nom de sauvegarde de sa position ne change plus à chaque build.
- Le test du curseur de découpe ne dépend plus d’un `NSSlider` que macOS 27 ne crée plus.
- Les boutons principaux restent lisibles fenêtre inactive ou désactivés.
- Corbeille refusée sur une PART : `FileManager.trashItem` y crée un `.Trashes` illisible et la place reste occupée.
  Observé sur les PART S et U de la carte de test, toutes deux devenues invérifiables.
- Message de PART non vérifiable propre à la bibliothèque, avec sa lettre et la mention d’un `.Trashes` illisible.
- Retrait d’un dossier ou d’une source de samples de la liste, sans toucher aux fichiers.
- Aperçu du nom 8.3 du `.PGM` et des samples ; vocabulaire harmonisé (tutoiement, PART, samples, Mio, échantillons).

Non traité ici : métadonnées macOS (`._*`, `.fseventsd`) qui occupent des grappes sur les PART, chemins mémorisés
en texte (un SSD remonté sous un autre nom les casse), réécriture complète des SND à chaque révision locale.
Aucune écriture sur SD, aucun essai sur la MPC.

## Bâtir une bank en 0.7.2 (22), 5 novembre 2026

- Jauge « tient dans une PART » sous la mémoire audio : même estimation que la vérification de copie, comparée
  à la plus grande PART vide montée, ou à la dernière mémorisée. La fenêtre de copie explique un dépassement.
  Sur la carte de test, une PART vide offre 8,1 Mo ; KIT demande 3,8 Mo.
- Les pads qui partagent un sample portent une icône 🔗 ; l’éditeur nomme les pads concernés. KIT affecte
  36 pads à 23 samples ; B01 (KIK5) y partage son sample avec A09 et C05.
- Samples : flèches ↑ ↓ après un clic dans la liste, option **Écouter à la sélection** mémorisée ;
  la demande la plus récente l’emporte sur une préécoute encore en décodage.
- Liste .PGM : nombre de samples résolus par programme. Les 8 `PROGRAM_.pgm` de la carte portent tous le titre
  interne `PROGRAM_01` ; seul leur contenu et leur PART les distinguent. Le titre interne figure en infobulle.

La capacité mémorisée est une observation de la carte, pas une constante de la MPC.

## Ranger la bibliothèque en 0.7.3 (23), 5 novembre 2026

- Erratum : la passe 0.7.2 notait l’écoute de la seule partie découpée comme « à faire ». C’était déjà le cas :
  la préécoute d’un `.SND` lit son en-tête et joue de son marqueur de début à son marqueur de fin.
- Liste .PGM groupée : bibliothèque sur le Mac, PART A–Z, puis dossiers par nom. En-têtes fixes avec le nombre de .PGM.
- Onglet PART : fichiers `._*` comptés en grappes de la PART et dossiers système (`.Trashes`, `.Spotlight-V100`),
  lus par `readdir` car Foundation masque les `._*`. `.fseventsd`, présent sur chaque PART montée, reste en infobulle.
  Relevé informatif : aucune suppression proposée. Non vérifié sur la carte réelle pendant cette passe (SD débranchée) ;
  le relevé du 5 novembre en lecture seule comptait 65 `._*` sur S, 17 sur T, 5 sur R, 1 sur A et U.
- Dossiers mémorisés : chemin conservé pour l’ordre et la compatibilité, plus un bookmark. Le bookmark ne sert que si
  le dossier garde son chemin dans un volume remonté sous un autre nom ; un dossier déplacé reste indisponible.
  Repli pour les anciennes entrées : même chemin sur un seul nom de montage voisin (« T9 » pour « T9 1 »).
  La source `/Volumes/T9 1/User Library/Samples/Soul` sera réparée au prochain branchement du SSD sous « T9 ».

Écarté pour l’instant : partager les SND inchangés entre révisions locales. Une bank tient dans une PART
d’environ 8 Mo, ce qui borne chaque révision ; modifier la publication atomique du magasin local coûterait plus
que l’espace gagné.

## Alléger les 26 PART en 0.7.4 (24), 6 novembre 2026

Nicolas trouve encombrantes les 26 PART de sa carte. Côté app :

- Onglet PART : les PART vides et vérifiées partagent une carte (11 sur la carte de test : E G H J K M N P Q W X,
  8,1 Mo chacune). Une PART à vérifier, comme U avec son `.Trashes`, garde sa carte.
- Chaque autre PART montre sa place libre et une barre de remplissage par rapport à une PART vide
  (mesurée, ou mémorisée sans la carte). PART D : 90 ko libres.
- Le menu des sources de samples ne liste plus les PART sans sample.

Contrôles sur la carte réelle, en lecture seule : relevé macOS identique à l’inventaire manuel (A 1, R 5, S 65,
T 17, U 1 fichiers `._` ; `.Trashes` sur S et U), scan de 26 PART en 0,20 s. Au rebranchement du SSD, la source
`/Volumes/T9 1/…` a été réparée en `/Volumes/T9/…` et a reçu son bookmark.

Côté machine, le canon (checkpoint 33, analyse statique de Vailixi 3.50) décrit deux formats SCSI, Standard et
Hybrid, au plus 26 partitions, et l’étiquette `MPC-PART` écrite par le mode Hybrid. La PART A de la carte mesure
15 939 secteurs, soit le premier volume Hybrid de taille 1. Les tailles proposées par l’écran de formatage ne
sont pas établies ; aucun reformatage n’a été fait.

## Cure de minceur en 0.7.5 (25), 6 novembre 2026

Nicolas : « J’ai le cerveau qui explose quand je vois la quantité d’information et d’options, ça me repousse
à utiliser l’outil. » L’écran Samples comptait plus de 50 éléments avant même la liste. Cette passe retire
ou range ; elle n’ajoute aucune fonction et ne change aucune règle d’écriture.

- Retiré de l’écran : titre « Bibliothèque », bouton Actualiser (menu Bibliothèque, ⌘R), bouton d’ajout de
  dossier (menu de source), bloc jaune d’inventaire (un ⚠ avec infobulle), sous-titres répétés des samples,
  panneau « Utilisé par » (bulle ⓘ du sample choisi), boutons Écouter et Arrêter (un clic écoute, ⌘. arrête),
  case « Écouter à la sélection » (menus), ligne d’état sous la liste (seules les vraies erreurs s’affichent),
  « MPC KIT STUDIO », « BANQUE », « ÉDITION DU SAMPLE », « TRAITEMENT AUDIO », rappels de copie, consigne
  de glisser, compteur de pads, boutons Annuler et Rétablir (menu Édition), icône d’information de la barre d’état.
- Mémoire audio : affichée seule seulement quand la jauge de PART manque ; sinon dans l’infobulle de la jauge.
- Un pad vide réduit l’éditeur à une ligne ; la barre d’état n’affiche un message que six secondes.
- Bug supprimé avec la ligne d’état : « 0 sample(s) visibles » pouvait contredire le compteur du haut.

Les cinq dispositions grises de la toile restent à arbitrer ; celles qui montrent plus de choses à la fois
iraient contre ce retour.

## Navigateur de samples en arborescence en 0.7.6 (26), 6 novembre 2026

Nicolas : « comme dans Ableton je puisse naviguer dans ma bank de sample local genre celle qui est dans mon
SSD afin de faire du drag and drop. » L’onglet Samples garde sa place (le choix de disposition reste ouvert)
mais son contenu change :

- Le menu de source devient une liste de lieux toujours visible : Bibliothèque et SD, Carte SD, dossiers
  ajoutés avec leur volume (« Soul · T9 »), Ajouter un dossier. Clic droit : Afficher dans le Finder,
  Retirer de la liste. Les PART isolées restent accessibles depuis l’onglet PART.
- Un dossier s’affiche en arbre. Un sous-dossier se déplie sur place et n’est lu qu’à ce moment, un niveau à
  la fois, avec les mêmes garde-fous que la navigation précédente : seul un dossier visible dans l’arbre et
  contenu dans la source peut s’ouvrir, chemin résolu compris ; une PART démontée reste indisponible.
  Les dossiers ouverts sont relus avec la source à l’actualisation ; une sélection disparue est retirée.
  Un dossier vide ou illisible le dit à sa place.
- La recherche d’un dossier devient récursive, mais seulement parce qu’un mot est tapé : choisir une source
  ne lance toujours aucun parcours complet du SSD. Elle attend 250 ms après la frappe, s’annule au mot
  suivant, ne suit aucun lien symbolique, saute fichiers cachés et paquets, et s’arrête à 500 résultats,
  12 niveaux ou 100 000 éléments en le signalant (« 500+ résultats »). Chaque mot doit figurer dans le
  chemin sous la source. En attendant, les dossiers déjà lus donnent une réponse partielle.
- Le casque à côté de la recherche active l’écoute en parcourant ; la colonne passe de 300 à 320 points.

Rien n’est écrit sur le SSD ni sur la SD par ce navigateur : il liste, lit l’audio pour l’écoute et ouvre
le Finder. Les cinq dispositions habillées à la DA de l’app sont sur la toile, page « Habillées ».

## Trois colonnes en 0.8.0 (27), 6 novembre 2026

Nicolas a dessiné sa disposition puis choisi la planche 7 de la toile : « à gauche il faut qu’il y ait
vraiment que la gestion des samples et sur la droite la gestion des .PGM, je pense que la sélection des part
doit être très minimaliste. J’aime pas du tout la section de gauche avec ces 3 onglets. » Puis : « Il faut
que les samples soient à côté des pads pour glisser. »

- Les onglets .PGM / Samples / PART disparaissent. Gauche : samples de l’ordinateur (lieux en pastilles, arbre,
  recherche) au-dessus des samples de la SD (PART fermées qui s’ouvrent sur place, recherche propre), séparés par
  une poignée réglable et mémorisée ; « Affecter au pad » en bas. Centre : nom, jauge, pads, puis l’éditeur dessous.
  Droite : liste des .PGM filtrée par une ligne de lettres (Tout · Mac · PART qui ont un contenu), une ligne pour
  les PART vides, la place libre et les fichiers macOS de la PART choisie.
- Le lieu « Bibliothèque » ne montre plus que la collection du Mac : la SD a son volet. Un seul sample est choisi
  à la fois entre les deux volets ; une actualisation ou un démontage retire un sample SD qui n’est plus listé.
- Filtrer les .PGM ne change plus les samples affichés ; ajouter un dossier de .PGM ne l’ouvre plus à gauche.
- Le dernier lieu de samples et les dossiers ouverts sont mémorisés d’un lancement à l’autre.
- Pads de 64 points, forme d’onde de 110 points et traitements sur une ligne : l’éditeur tient sous les pads
  dans une fenêtre de 860 points de haut.
- Les racines de la bibliothèque Mac sont comparées par chemin : une même racine écrite avec ou sans « / » final
  faisait manquer le groupe « Bibliothèque sur le Mac » dans les tests.

Les états de modèle des anciens onglets sont retirés en 0.8.1.

## Hygiène en 0.8.1 (28), 6 novembre 2026

Nicolas : « Fais le ménage, clean tout. Je veux une app avec une hygiène indiscutable. » Aucune fonction visible
ne change ; tout ce que l’interface n’atteignait plus est retiré, avec ses tests portés vers ce qui l’a remplacé.

- Retirés du modèle : le mode d’onglet, les portées « toute la SD » et « une PART » du volet ordinateur, la
  navigation vers un sous-dossier et son bouton « dossier parent », la recherche de .PGM sans champ, la liste des
  emplacements, les libellés et avertissements de l’ancien navigateur, `previewSample`, `collapseAllSampleFolders`,
  le résumé des liens d’un sample ; dans MPCCore, `soundNames`.
- L’état des samples n’est plus une phrase analysée pour y trouver une erreur : `sampleProblem` ne porte que les
  vrais problèmes (écoute impossible, source indisponible) et s’efface au geste suivant.
- Un arbre vide ne se dit « vide » que si l’inventaire permet de conclure ; sinon « Aucun sample visible ». Les
  samples d’un .PGM gardent l’avertissement de sa PART.
- Les tests de sûreté portent désormais sur les volets réels : démontage, PART à vérifier, lien symbolique qui
  remplace un dossier ouvert, sélection qui disparaît, réponses tardives d’une source abandonnée.
- `LibraryBrowser.swift`, qui ne contenait plus de navigateur, devient `SampleColumn`, `ProgramColumn`,
  `LibraryComponents`, `LibraryFormat` et `ExportDestinationSheet`.
- CI : `actions/checkout` v7.0.1 et `actions/upload-artifact` v7.0.2 (Node.js 24), épinglés sur leur commit.
- README : la portée parlait encore d’absence de sauvegarde et d’annulation, et d’un onglet PART.

## Français et anglais en 0.9.0 (29), 6 novembre 2026

Nicolas : « Fais une version anglaise et une version française de l’app. » Une seule app : elle suit la langue
de macOS, en français par défaut.

- Le français reste la langue source dans le code. Chaque texte montré passe par SwiftUI ou par
  `String(localized:)` : messages du modèle, erreurs de MPCCore, panneaux, alertes, infobulles et étiquettes
  vocales. 408 textes, dont les pluriels, ont leur anglais dans `Localization/Localizable.xcstrings`.
- La construction relève les textes utilisés et refuse un texte sans anglais, inutilisé ou aux formats
  différents ; le catalogue est compilé dans `en.lproj` et `fr.lproj`, et l’app déclare les deux langues.
- « Annuler » servait à la fois pour Undo et pour Cancel : le menu Édition a sa propre clé.
- Les pluriels fabriqués par concaténation (« sample » + « s ») deviennent des textes complets ; le français
  choisit sa forme dans le code pour rester juste sans catalogue, l’anglais a ses formes dans le catalogue.
- L’étiquette d’accessibilité du curseur de découpe ne se déduit plus de son titre affiché.
- `build-app.sh` prend Xcode quand `xcode-select` désigne les outils en ligne de commande.

Vérifié dans une copie de revue en anglais : barre d’outils, colonnes, menus (File, Edit, View, Library).
La notarisation reste à faire : l’app est signée localement, sans Developer ID.
