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

## État livré en 0.6.0 (16)

L’app mémorise des dossiers, indexe leurs PGM et ceux des PART montées, permet la composition en mémoire et écrit des copies vers une destination validée. La bibliothèque propose trois vues : `.PGM`, Samples et PART. Samples réunit les sons visibles sur la SD ou parcourt une source choisie ; chaque occurrence garde son chemin. Depuis un PGM, « Voir les samples » montre ses références résolues sans remplacer le document ouvert. Depuis un sample, les liens indiquent chaque PGM enregistré qui le référence et son emplacement.

Les associations sont un relevé en mémoire, recalculé en lecture seule depuis les PGM et les en-têtes SND. La même résolution de noms sert à l’ouverture et à l’index des associations. Aucun audio n’est décodé pour cet index ; aucun tag n’est injecté dans les SND. Une référence ambiguë ou illisible demeure non résolue. Une absence de lien ne prouve pas qu’un son est inutilisé, notamment en présence d’un inventaire incomplet ou d’autres formats.

Une copie locale est conservée dans un dossier ajouté à la bibliothèque ; une copie uniquement sur SD n’a pas de sauvegarde locale implicite. La dernière copie du document courant est identifiée par son chemin. Le catalogue durable indépendant des supports et le suivi de filiation entre plusieurs copies d’un PGM ne sont pas implémentés : noms ou empreintes identiques ne regroupent pas automatiquement des occurrences.

La marque MPC Kit Studio et les identifiants internes restent stables. Cette passe ajoute la lecture des associations et simplifie leur navigation ; les formats de fichiers et les protections d’écriture restent inchangés.

## Contraintes de cette passe

Déboguer et simplifier l’existant, sans ajouter de nettoyage automatique, d’écrasement ou de déplacement. SD en lecture uniquement pour l’investigation ; tests d’écriture sur dossiers locaux. Une PART invérifiable n’est jamais proposée comme vide. Les SEQ, APS, ALL et champs inconnus empêchent de déduire une autorisation de suppression d’une simple absence de référence PGM.
