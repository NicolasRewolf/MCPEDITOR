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

La capacité mémorisée est une observation de la carte, pas une constante de la MPC. Le regroupement des `.PGM`
par PART et l’écoute de la sélection découpée seule restent à faire.
