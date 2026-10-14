# MPC Kit Studio — prototype Mac

Application native pour Apple Silicon, macOS 13 ou plus récent. Interface en français.
Programmes MPC3000 natifs et sons SND révision 02, avec préparation de kits WAV/AIFF.
Aucune gestion de séquences.

## Essayer

Le workflow **MPC Kit Studio - Mac** fabrique une archive Apple Silicon dans ses artefacts GitHub Actions.
Décompresser l'archive externe puis **MPC-Kit-Studio-Apple-Silicon.zip**, et ouvrir **MPC Kit Studio.app**.
La signature est locale (ad hoc), sans certificat Developer ID ni notarisation Apple.
Si macOS bloque l'application téléchargée, utiliser son option **Ouvrir quand même** dans
Réglages Système → Confidentialité et sécurité. Ne pas désactiver Gatekeeper.

1. Insérer la SD ; cliquer sur Actualiser pour afficher les volumes externes.
2. Choisir PART A, PART B, etc., puis un programme. « Ouvrir un dossier » fonctionne aussi sur une copie locale.
3. Jouer les pads, changer de banque A–D, importer ou glisser des WAV, AIFF ou SND.
   Une sélection multiple remplit les pads suivants dans l'ordre de la sélection.
4. Régler les marqueurs début/fin, découper, normaliser, convertir en mono, inverser ou appliquer des fondus de 3 ms.
5. Choisir un nom de kit, puis Exporter vers la racine d'une partition. L'application crée un nouveau
   programme et de nouveaux sons, avec noms ASCII de huit caractères sans écraser les fichiers existants.
6. Éjecter la SD depuis le Finder, puis charger le nouveau programme sur la MPC.

Commencer sur une **copie d'un kit dans un dossier local**, puis valider un petit export sur la MPC.
Aucun aller-retour matériel n'a encore été effectué par ce projet.

## Portée

- Le programme natif fait 4 608 octets. Les paramètres non édités, la carte des pads,
  les modes d'affectation, le filtre et le mixer sont conservés.
- Le nouveau kit utilise un programme modèle présent dans le corpus du dépôt.
- Le SND natif a un en-tête de 38 octets et du PCM 16 bits little-endian,
  stéréo planaire. Import WAV/AIFF converti vers 44,1 kHz.
- Les samples restent partagés entre les pads qui utilisent le même emplacement.
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
Résultat : `dist/MPC-Kit-Studio-Apple-Silicon.zip`.
Les tests du cœur se lancent séparément avec `swift test`.

## Sources techniques

- [PGM/SND](../../knowledge/program_sound_files.yaml), [paramètres](../../knowledge/programs.yaml),
  [répertoires](../../knowledge/storage_directory.yaml).
- Modèle : `ressources/incoming/01_izzyreal_mpc/test-resources/RealMpc3000/Pgm/PROGRAM.pgm`,
  SHA Git `7f9a42740821e6f8b7286b978d2481a8217df20b`.
- [Provenance du corpus](../../knowledge/source_corroboration.yaml).
Le travail de l'application ne relance pas la recherche ROM UNDERSTAND.
