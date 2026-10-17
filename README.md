# MPC Kit Studio — prototype Mac

Application native pour Apple Silicon, macOS 13 ou plus récent. Interface en français.
Programmes MPC3000 natifs et sons SND révision 02, avec préparation de kits WAV/AIFF.
Aucune gestion de séquences.

## Essayer

Le workflow **MPC Kit Studio - Mac** fabrique une image disque et une archive Apple Silicon dans ses artefacts GitHub Actions.
Décompresser l'archive de l'artefact, ouvrir **MPC-Kit-Studio-Apple-Silicon.dmg**,
puis copier **MPC Kit Studio.app** dans Applications. Le ZIP reste disponible en alternative.
La signature est locale (ad hoc), sans certificat Developer ID ni notarisation Apple.
Si macOS bloque l'application téléchargée, utiliser son option **Ouvrir quand même** dans
Réglages Système → Confidentialité et sécurité. Ne pas désactiver Gatekeeper.

1. Insérer la SD et ouvrir l’application. **Kits** rassemble les `.PGM` des PART et des dossiers ajoutés,
   avec leur emplacement visible sur chaque ligne. Un `.PGM` correspond à un kit.
2. Créer un nouveau kit, puis glisser des WAV, AIFF ou SND sur les pads. Une sélection multiple
   remplit les pads suivants dans l’ordre de la sélection, jusqu’à D16.
   Si la lecture d’un dépôt reste bloquée, **Annuler le dépôt** rend immédiatement le kit disponible
   et conserve ses modifications ; un retour tardif du fournisseur est ignoré.
3. Dans **Samples**, parcourir une PART ou ajouter un dossier du SSD : les sons existants apparaissent
   même sans programme. Sélectionner un son, l’écouter, puis l’affecter au pad choisi, ou le glisser sur un pad.
   La recherche filtre le dossier courant ; les sous-dossiers s’ouvrent séparément.
4. Former les banques A–D, nommer le sample sélectionné, régler les découpes, l’accordage et les traitements.
   Parcourir la bibliothèque ne remplace jamais le kit en mémoire.
5. **Enregistrer une copie…** propose une PART vide disposant d’assez d’espace, avec une réserve pour
   l’allocation des fichiers. Valider, ou ouvrir **Changer la destination**. Sans PART adaptée,
   l’application demande une autre destination. Aucun déplacement de kits existants n’est automatique.
6. Après enregistrement, la bibliothèque sélectionne la copie créée ; le titre indique la PART et le nom réel du `.PGM`. La **Carte de la SD**
   reste disponible en bas de la bibliothèque pour consulter le rangement.
7. Éjecter la SD depuis le Finder, la remettre dans la MPC et charger le `.PGM` indiqué.
8. Pour retirer un kit de la bibliothèque, ouvrir son menu **⋯** ou faire un clic droit,
   puis **Mettre le programme à la corbeille…**. La confirmation indique son chemin exact.
   Les `.SND` et `.SEQ` restent sur le disque ; une PART contenant encore des samples reste occupée.
   Si le kit était ouvert, sa copie en mémoire reste disponible et peut être enregistrée à nouveau.

Chaque enregistrement crée une nouvelle copie du programme et de ses sons ; les fichiers existants sont conservés.
Le nom se modifie dans l’en-tête du kit. La fenêtre d’enregistrement le présente en lecture seule
et sert à choisir la destination ; l’annuler ne renomme pas le programme.
Un nom ASCII libre de huit caractères est choisi en cas de collision. Le kit ouvert d’origine reste
identifié séparément de la dernière copie enregistrée. Les dossiers ajoutés sont mémorisés localement.
Le titre interne du programme est conservé lors d’une copie sans édition, même s’il diffère du nom
du fichier. Modifier explicitement le nom du kit modifie aussi ce titre ; un suffixe attribué pour
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
de l’attente sans modifier le kit. Un résultat tardif ne rétablit pas une sélection abandonnée.
Un nom de programme présent plusieurs fois interdit également sa mise à la corbeille.
Si macOS refuse l’accès à un dossier caché nécessaire au contrôle, l’app signale le refus ;
le kit peut être enregistré dans un dossier local vérifiable sur le Mac.

Commencer sur une **copie d'un kit dans un dossier local**, puis valider un petit export sur la MPC.
Aucun aller-retour matériel n'a encore été effectué par ce projet.

## Portée

- Le programme natif fait 4 608 octets. Les paramètres non édités, la carte des pads,
  les modes d'affectation, le filtre et le mixer sont conservés.
- Le nouveau kit utilise un programme modèle présent dans le corpus du dépôt.
- Le SND natif a un en-tête de 38 octets et du PCM 16 bits little-endian,
  stéréo planaire. Import WAV/AIFF converti vers 44,1 kHz.
- Les samples restent partagés entre les pads qui utilisent le même emplacement.
- Le chargement préfère un nom de fichier unique. Si le nom DOS diffère du nom référencé,
  il recherche un nom interne SND natif unique ; une ambiguïté reste signalée.
- Un import multiple est préparé intégralement avant de remplacer le kit en mémoire.
  Un fichier invalide, un dépassement de mémoire ou un lot dépassant D16 laisse le kit précédent intact.
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
- Plafond du prototype : 32 Mio de PCM par kit ; vérifier la RAM réellement installée dans la MPC.
- Seuls les sons référencés sont exportés ; l'inventaire inutilisé est vidé.
  Les SND sont écrits avant le programme. Celui-ci est préparé sous une extension `.TMP`,
  synchronisé, puis publié en `.PGM` sans remplacement d’un nom existant.
  En cas d’échec, les noms créés restent sur place et sont signalés : aucun nettoyage
  automatique ne risque de supprimer un fichier repris par un autre écrivain.
  Une coupure d’alimentation ne constitue pas une transaction atomique de tout le kit.
  Une interruption peut laisser des SND ou un TMP à examiner ; ne pas les effacer aveuglément.
- Les modifications sont en mémoire jusqu'à l'export. Il n'y a pas encore de sauvegarde
  de projet de travail, d'annulation générale ou de restauration de session.

## Compiler sur le Mac

Installer les outils développeur Apple (Xcode ou ses outils en ligne de commande), puis :

```sh
cd mac/KitStudio
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

- [PGM/SND](../../knowledge/program_sound_files.yaml), [paramètres](../../knowledge/programs.yaml),
  [répertoires](../../knowledge/storage_directory.yaml).
- Modèle : `ressources/incoming/01_izzyreal_mpc/test-resources/RealMpc3000/Pgm/PROGRAM.pgm`,
  SHA Git `7f9a42740821e6f8b7286b978d2481a8217df20b`.
- [Provenance du corpus](../../knowledge/source_corroboration.yaml).
La [notice du modèle et la licence présente dans son dépôt source](Notices/PROVENANCE.md)
sont incluses dans les ressources de l’application. Les droits de redistribution de cette capture
restent à clarifier avant une diffusion plus large.
Le travail de l'application ne relance pas la recherche ROM UNDERSTAND.
