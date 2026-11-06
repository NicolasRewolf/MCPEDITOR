# MPC Kit Studio — prototype Mac

> Ce dépôt contient l’app seule, extraite du projet de nouvel OS MPC3000 (Homework 4.0)
> avec son historique. Il contient aussi la page de vente (`site/`) et le plan de lancement
> ([docs/LAUNCH.md](docs/LAUNCH.md)). La recherche ROM reste dans son propre dépôt.

Application native pour Apple Silicon, macOS 13 ou plus récent. Interface en français.
Programmes MPC3000 natifs et sons SND révision 02, avec préparation de programmes à partir de WAV/AIFF.
Aucune gestion de séquences.

## Essayer

Le workflow **MPC Kit Studio - Mac** fabrique une image disque et une archive Apple Silicon dans ses artefacts GitHub Actions.
Décompresser l'archive de l'artefact, ouvrir **MPC-Kit-Studio-Apple-Silicon.dmg**,
puis copier **MPC Kit Studio.app** dans Applications. Le ZIP reste disponible en alternative.
La signature est locale (ad hoc), sans certificat Developer ID ni notarisation Apple.
Si macOS bloque l'application téléchargée, utiliser son option **Ouvrir quand même** dans
Réglages Système → Confidentialité et sécurité. Ne pas désactiver Gatekeeper.

1. Ouvrir l’application, avec ou sans SD. **.PGM** rassemble la collection conservée sur le Mac, les `.PGM` des PART montées et des dossiers ajoutés,
   avec leur emplacement visible sur chaque ligne. Un `.PGM` contient les affectations et les réglages ; les sons restent dans les `.SND`.
2. Créer un nouveau programme .PGM, puis glisser des WAV, AIFF ou SND sur les pads. Une sélection multiple
   remplit les pads suivants dans l’ordre de la sélection, jusqu’à D16.
   Si la lecture d’un dépôt reste bloquée, **Annuler le dépôt** rend immédiatement le programme .PGM disponible
   et conserve ses modifications ; un retour tardif du fournisseur est ignoré.
3. Dans **Samples**, la vue initiale **Bibliothèque et SD** rassemble les sons référencés par les `.PGM` disponibles et les samples visibles de toutes les PART, même sans programme.
   Les samples sont groupés par source et chaque ligne ne montre que leur nom. Un clic écoute le sample ;
   **⌘.** arrête l’écoute. Le ⓘ du sample choisi indique les `.PGM` enregistrés qui l’utilisent ; **Ouvrir**
   charge le programme choisi. Les liens ne tiennent pas compte des modifications encore en mémoire.
   En haut, la liste des **lieux** reste visible : Bibliothèque et SD, Carte SD, puis chaque dossier ajouté
   (par exemple `Soul` sur le SSD `T9`), et **Ajouter un dossier…**. Un dossier s’affiche en arborescence,
   comme le navigateur d’un logiciel de musique : un clic sur un sous-dossier le déplie sur place, un second le
   replie ; chaque dossier n’est lu qu’à son ouverture, un niveau à la fois, et les dossiers ouverts le restent
   quand on revient à ce lieu ou qu’on actualise. Un sample se glisse sur un pad depuis n’importe quelle
   profondeur ; le clic droit propose **Affecter au pad** et **Afficher dans le Finder** (aussi sur un lieu,
   avec **Retirer de la liste**). Dans un dossier, la recherche parcourt tout le dossier, sous-dossiers fermés
   compris : chaque mot doit figurer dans le nom du sample ou de ses dossiers (« sloppy loops »). Elle ne part
   qu’après la frappe, ne suit aucun lien symbolique, ignore les fichiers cachés et s’arrête à 500 résultats,
   12 niveaux ou 100 000 éléments, ce qu’elle signale. Les résultats sont groupés par sous-dossier.
   Ailleurs, la recherche filtre la vue courante.
   **Affecter au pad** pose le sample choisi ; le glisser-déposer reste possible. Les flèches ↑ ↓ passent
   d’un sample visible à l’autre ; le casque à côté de la recherche (ou le menu **Bibliothèque**) active
   **Écouter en parcourant avec ↑ ↓**. Un `.SND` est écouté entre ses marqueurs de début et de fin.
   Une réserve sur l’inventaire n’est plus qu’un ⚠ à côté du compteur, expliqué au survol.
   Dans **.PGM**, la liste est groupée : bibliothèque sur le Mac, puis PART A à Z, puis dossiers par nom.
   Chaque ligne indique le nombre de samples résolus, ce qui distingue les homonymes comme plusieurs
   `PROGRAM_.pgm` ; l’infobulle donne le titre sur la MPC s’il diffère.
   L’onglet **PART** regroupe les PART vides en une seule carte (lettres et capacité), puis détaille
   les autres avec leur place libre et une barre de remplissage. Il signale les fichiers laissés par macOS
   (`._*` des copies du Finder, `.Trashes`, index) et la place qu’ils occupent. Kit Studio n’en crée pas
   et ne les supprime pas. Le lieu **Carte SD** indique le nombre de PART qui ont un contenu.
   Dans **.PGM**, le bouton de forme d’onde **Voir les samples** parcourt les sons référencés sans charger le programme.
4. Former les banques A–D, nommer le sample sélectionné, régler les découpes, l’accordage et les traitements.
   Déplacer un pad vers un autre déplace son affectation ; deux pads occupés sont échangés. Survoler une
   banque pendant le glissement permet de changer de banque. Copier une affectation via son menu partage
   le même sample : une icône 🔗 marque ces pads et l’éditeur nomme les pads concernés, car le nom,
   la découpe et les traitements s’appliquent à tous ; l’accordage reste propre à chaque pad.
   **⌘Z / ⇧⌘Z** annule/rétablit les éditions, depuis le menu Édition ; les sélections ne créent pas d’historique.
   Un pad vide n’occupe qu’une ligne dans l’éditeur. La barre d’état affiche chaque message quelques secondes.
   Le menu **Bibliothèque** regroupe Actualiser (⌘R), l’ajout d’un dossier de samples et l’écoute.
   Sous la mémoire audio, une jauge compare l’espace que demande la copie (allocation FAT et réserve,
   comme la vérification de copie) à la plus grande PART vide de la SD, ou à la dernière observée si la carte
   est absente. Une bank qui dépasse est signalée avant la copie.
   Parcourir la bibliothèque ne remplace jamais le programme .PGM en mémoire. Le retour de la vue Samples
   retrouve sa recherche et sa sélection précédentes.
5. **Enregistrer (⌘S)** conserve le programme et tous ses sons dans la bibliothèque sur le Mac.
   Le premier enregistrement d’une source externe en crée une version indépendante ; aucun original n’est remplacé.
   Enregistrer à nouveau met à jour le même élément de bibliothèque. Le nom se modifie dans l’en-tête.
6. **Copier sur la SD… (⇧⌘S)** propose une PART vide disposant d’assez d’espace, avec une réserve pour
   l’allocation des fichiers. Valider ou changer la destination. Sans PART adaptée, choisir un autre dossier.
   La copie ne renomme pas le document ouvert et ne remplace pas son enregistrement local. Le message de fin
   indique la PART et le nom réel du `.PGM` à charger. L’onglet **PART** affiche les `.PGM` présents et leurs samples.
7. Éjecter la SD depuis le Finder, la remettre dans la MPC et charger le `.PGM` indiqué.
8. Pour retirer un programme .PGM de la bibliothèque, ouvrir son menu **⋯** ou faire un clic droit,
   puis **Mettre le programme à la corbeille…**. La confirmation indique son chemin exact.
   Les `.SND` et `.SEQ` restent sur le disque ; une PART contenant encore des samples reste occupée.
   Si le programme .PGM était ouvert, sa copie en mémoire reste disponible et peut être enregistrée à nouveau.
   Sur une PART de la SD, la corbeille n’est pas proposée : macOS y créerait un dossier caché `.Trashes`
   qui garde le fichier sur la PART et empêche ensuite de la vérifier. Supprimer ce `.PGM` depuis la MPC si nécessaire.

Les associations sont calculées en lecture seule depuis les fichiers `.PGM` et les en-têtes `.SND`.
Aucun tag n’est écrit sur la SD. Deux fichiers de même nom sur deux PART restent deux occurrences distinctes.
Une référence ambiguë, absente ou illisible reste signalée ; « aucun lien trouvé » ne signifie jamais « inutilisé ».
Les programmes et les fichiers invisibles à macOS ne peuvent pas être retrouvés par cette vue ; un inventaire
incomplet demeure indiqué. Les séquences `.SEQ`, `.APS` et `.ALL` ne sont pas analysées pour ces associations.
La lecture des associations est bornée, sans décodage audio ; les limites atteintes sont signalées.

La collection locale se trouve dans `~/Library/Application Support/MPC Kit Studio/Programs` ; **Finder**
révèle le `.PGM` courant. Chaque édition enregistrée prépare un ensemble natif complet avant publication
atomique de sa version courante. Une seule version apparaît dans la bibliothèque. Les révisions précédentes
et les écritures interrompues restent sur le Mac pour récupération ; elles consomment de l’espace et ne sont
pas purgées automatiquement. Un enregistrement sans modification ne crée pas de nouvelle révision.
Un `.PGM` local abîmé est signalé sans masquer les autres. Aucune sauvegarde automatique n’est revendiquée.
L’historique d’édition est limité à 50 étapes et à un budget conservateur de 256 Mio ; il est propre au document ouvert.
Avant de changer de document ou de quitter, les choix sont **Enregistrer / Abandonner les modifications / Annuler**.
Un enregistrement échoué laisse les modifications en mémoire et empêche la fermeture demandée.

Chaque copie de transport crée des fichiers nouveaux, avec un nom ASCII libre de huit caractères en cas de
collision. L’annulation du dialogue ne renomme pas le programme. Les dossiers ajoutés sont mémorisés localement ;
**Retirer de la liste**, dans le menu Dossiers ou par clic droit sur un lieu de samples, les oublie sans toucher aux fichiers.
Chaque dossier est aussi mémorisé par un bookmark : un volume remonté sous un autre nom (« T9 » puis « T9 1 »)
reste retrouvé tant que le dossier garde son chemin dans ce volume. Un dossier déplacé ou renommé devient
indisponible, comme avant. Une ancienne entrée sans bookmark est réparée si un seul volume voisin
(« T9 » pour « T9 1 ») contient le même chemin ; plusieurs candidats laissent le chemin tel quel.
Le nom 8.3 écrit pour le `.PGM` et pour chaque sample, sur le Mac comme sur la SD, s’affiche sous le champ de nom
dès qu’il diffère du nom saisi (« Enregistré sous KICK_DEE.SND »).
Une PART non vérifiable indique sa lettre et la raison du refus. Une corbeille cachée `.Trashes` illisible
est nommée ; elle apparaît quand un fichier de la PART est mis à la corbeille depuis le Mac.
Le suivi durable des copies SD hors ligne n’est pas encore implémenté : la bibliothèque indique les fichiers
réellement inventoriés, sans regrouper arbitrairement les homonymes.
Le titre interne du programme est conservé lors d’une copie sans édition, même s’il diffère du nom
du fichier. Modifier explicitement le nom du programme .PGM modifie aussi ce titre ; un suffixe attribué pour
éviter une collision ne le modifie pas.
La notion de PART vide exclut les fichiers cachés macOS : elle exige l’absence de toute entrée visible
et un parcours complet sans erreur. Une PART contenant uniquement des samples, séquences ou dossiers
n’est donc jamais choisie automatiquement comme vide.
Une lecture FAT dont l’espace occupé n’est pas expliqué par l’inventaire reste « À vérifier »
et n’est pas proposée automatiquement comme destination vide.
L’identité du dossier et du volume est conservée jusqu’au clic sur Enregistrer, puis revérifiée
avant les créations. Une PART annoncée vide doit encore l’être à cet instant. Les destinations
non vérifiables, y compris par un choix de dossier personnalisé, restent protégées en lecture.
Le contrôle d’un dossier personnalisé s’exécute en arrière-plan ; **Annuler** permet de sortir
de l’attente sans modifier le programme .PGM. Un résultat tardif ne rétablit pas une sélection abandonnée.
Un nom de programme présent plusieurs fois interdit également sa mise à la corbeille.
Si macOS refuse l’accès à un dossier caché nécessaire au contrôle, l’app signale le refus ;
le programme .PGM peut être enregistré dans un dossier local vérifiable sur le Mac.

Commencer sur une **copie d'un programme .PGM dans un dossier local**, puis valider un petit export sur la MPC.
Aucun aller-retour matériel n'a encore été effectué par ce projet.

## Portée

- Le programme natif fait 4 608 octets. Les paramètres non édités, la carte des pads,
  les modes d'affectation, le filtre et le mixer sont conservés.
- Le nouveau programme .PGM utilise un programme modèle présent dans le corpus du dépôt.
- Le SND natif a un en-tête de 38 octets et du PCM 16 bits little-endian,
  stéréo planaire. Import WAV/AIFF converti vers 44,1 kHz.
- Les samples restent partagés entre les pads qui utilisent le même emplacement.
- Le chargement préfère un nom de fichier unique. Si le nom DOS diffère du nom référencé,
  il recherche un nom interne SND natif unique ; une ambiguïté reste signalée.
- Un import multiple est préparé intégralement avant de remplacer le programme .PGM en mémoire.
  Un fichier invalide, un dépassement de mémoire ou un lot dépassant D16 laisse le programme .PGM précédent intact.
  Les sons de moins de 441 points et les valeurs audio non finies sont refusés à l'import.
- Un sample Float dépassant la plage −1…+1 reste intact en mémoire, avec un diagnostic de crête.
  L’export est bloqué pour éviter un écrêtage silencieux. **Normaliser les samples concernés**
  applique un gain à ta demande ; remplacer le sample permet aussi de poursuivre.
- La préécoute joue les samples avec leur accordage. Elle ne reproduit pas
  les filtres, enveloppes, couches, modes d'affectation ou convertisseurs audio de la MPC.
- Les sons absents, ambigus ou non pris en charge empêchent l'export.
  Les SND compressés révision 82 et autres formats portant l'extension SND sont refusés.
- Les fichiers exportés ont au moins 441 points (10 ms). Les octets situés
  après le PCM déclaré sont signalés à l'import puis omis à l'export.
- Plafond du prototype : 32 Mio de PCM par programme .PGM ; vérifier la RAM réellement installée dans la MPC.
- Seuls les sons référencés sont exportés ; l'inventaire inutilisé est vidé.
  Les SND sont écrits avant le programme. Celui-ci est préparé sous une extension `.TMP`,
  synchronisé, puis publié en `.PGM` sans remplacement d’un nom existant.
  En cas d’échec, les noms créés restent sur place et sont signalés : aucun nettoyage
  automatique ne risque de supprimer un fichier repris par un autre écrivain.
  L’ensemble formé par le .PGM et ses sons n’est pas une transaction atomique en cas de coupure d’alimentation.
  Une interruption peut laisser des SND ou un TMP à examiner ; ne pas les effacer aveuglément.
- Les modifications sont en mémoire jusqu'à l'export. Il n'y a pas encore de sauvegarde
  de projet de travail, d'annulation générale ou de restauration de session.

## Compiler sur le Mac

Installer les outils développeur Apple (Xcode ou ses outils en ligne de commande), puis :

```sh
bash scripts/build-app.sh
```

Le script lance les tests, compile pour arm64, assemble et signe localement l'application.
Résultat : `dist/MPC-Kit-Studio-Apple-Silicon.dmg`, `.zip` et `release-manifest.json`.
Le manifeste relève commit, état des sources, version/build, outils et empreintes des sources,
archives et fichiers de l’app. La vérification décompresse le ZIP courant et contrôle sa ressource,
son exécutable et sa signature. En CI, ce même livrable est ensuite lancé sur un runner isolé ;
le processus et sa fenêtre sont contrôlés séparément. Ce n’est pas une attestation indépendante.
Les tests du cœur se lancent séparément avec `swift test`.
Les tests de l'application contrôlent aussi les conversions WAV/AIFF mono/stéréo
à 44,1/48/96 kHz, le budget des lots, les curseurs natifs et le rendu audio hors ligne.
Ces contrôles ne remplacent pas une écoute humaine ni un chargement sur la MPC.

## Sources techniques

L’interprétation des en-têtes SND est centralisée dans `MPCSoundHeader`
(`Sources/MPCCore/NativeFormats.swift`). L’association des fichiers utilise l’identité native
sans décoder le PCM ; le chargement et l’import vérifient les tailles et leurs budgets avant
le décodage complet. Les exigences propres à l’import, comme le minimum de 441 points,
restent dans le chemin d’import.

`KitExport.prepareCopy` (`Sources/MPCCore/KitExport.swift`) prépare les sons référencés
et les tailles des fichiers pour l’affichage et l’export, sans parcourir les valeurs audio.
Une préparation impossible affiche « Taille indisponible » et empêche la recommandation
automatique d’une PART. L’export contrôle ensuite les valeurs PCM et les tailles encodées,
puis l’espace réel et l’identité de la destination avant toute création de fichier.

- Formats PGM/SND, paramètres et répertoires : relevés dans le dépôt de recherche
  Homework 4.0 (privé), dont cette app a été extraite le 6 novembre 2026.
- Modèle : `test-resources/RealMpc3000/Pgm/PROGRAM.pgm` du dépôt izzyreal/mpc,
  SHA Git `7f9a42740821e6f8b7286b978d2481a8217df20b`.
La [notice du modèle et la licence présente dans son dépôt source](Notices/PROVENANCE.md)
sont incluses dans les ressources de l’application. Les droits de redistribution de cette capture
restent à clarifier avant la vente : voir [le plan de lancement](docs/LAUNCH.md).
