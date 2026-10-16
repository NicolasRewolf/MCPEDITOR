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
3. Dans **Samples**, parcourir une PART ou ajouter un dossier du SSD : les sons existants apparaissent
   même sans programme. Sélectionner un son, l’écouter, puis l’affecter au pad choisi, ou le glisser sur un pad.
   La recherche filtre le dossier courant ; les sous-dossiers s’ouvrent séparément.
4. Former les banques A–D, nommer le sample sélectionné, régler les découpes, l’accordage et les traitements.
   Parcourir la bibliothèque ne remplace jamais le kit en mémoire.
5. **Enregistrer le kit…** propose une PART vide disposant d’assez d’espace, avec une réserve pour
   l’allocation des fichiers. Valider, ou ouvrir **Changer la destination**. Sans PART adaptée,
   l’application demande une autre destination. Aucun déplacement de kits existants n’est automatique.
6. Après enregistrement, la bibliothèque sélectionne la copie créée ; le titre indique la PART et le nom réel du `.PGM`. La **Carte de la SD**
   reste disponible en bas de la bibliothèque pour consulter le rangement.
7. Éjecter la SD depuis le Finder, la remettre dans la MPC et charger le `.PGM` indiqué.

Chaque enregistrement crée un nouveau programme et ses sons ; les fichiers existants sont conservés.
Un nom ASCII libre de huit caractères est choisi en cas de collision. Le kit ouvert d’origine reste
identifié séparément de la dernière copie enregistrée. Les dossiers ajoutés sont mémorisés localement.
La notion de PART vide exclut les fichiers cachés macOS : elle exige l’absence de toute entrée visible
et un parcours complet sans erreur. Une PART contenant uniquement des samples, séquences ou dossiers
n’est donc jamais choisie automatiquement comme vide.

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
- La préécoute joue les samples avec leur accordage. Elle ne reproduit pas
  les filtres, enveloppes, couches, modes d'affectation ou convertisseurs audio de la MPC.
- Les sons absents, ambigus ou non pris en charge empêchent l'export.
  Les SND compressés révision 82 et autres formats portant l'extension SND sont refusés.
- Les fichiers exportés ont au moins 441 points (10 ms). Les octets situés
  après le PCM déclaré sont signalés à l'import puis omis à l'export.
- Plafond du prototype : 32 Mio de PCM par kit ; vérifier la RAM réellement installée dans la MPC.
- Seuls les sons référencés sont exportés ; l'inventaire inutilisé est vidé.
  Le PGM est écrit après les SND. Un échec entraîne le retrait des seuls fichiers créés
  par cet export, avec signalement si le retrait échoue. Une coupure d'alimentation
  ne constitue pas une transaction atomique de tout le kit.
- Les modifications sont en mémoire jusqu'à l'export. Il n'y a pas encore de sauvegarde
  de projet de travail, d'annulation générale ou de restauration de session.

## Compiler sur le Mac

Installer les outils développeur Apple (Xcode ou ses outils en ligne de commande), puis :

```sh
cd mac/KitStudio
bash scripts/build-app.sh
```

Le script lance les tests, compile pour arm64, assemble et signe localement l'application.
Résultat : `dist/MPC-Kit-Studio-Apple-Silicon.dmg` et `.zip`.
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
Le travail de l'application ne relance pas la recherche ROM UNDERSTAND.
