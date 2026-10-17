# Vocabulaire et flux de MPC Kit Studio

Clarifié avec Nicolas le 17 octobre 2026. Ce document distingue le besoin produit de l’état livré ; il ne relance pas UNDERSTAND.

## Objets du domaine

- **Sample** : un son utilisé dans une composition. Une occurrence de fichier possède un emplacement et une provenance. Un nom commun ou une empreinte identique ne justifie pas une fusion automatique.
- **Kit** : une composition intentionnelle de pads, de paramètres et de sons. Dans le langage de Nicolas, `.PGM = kit`. Pour transporter un kit, les SND auxquels son PGM fait référence doivent aussi être disponibles.
- **Bibliothèque** : l’ensemble dans lequel retrouver samples et kits. L’attente de Nicolas est une collection durable de kits composés par style ou intention, utilisable indépendamment de la présence de la SD.
- **PART** : un emplacement sur la SD, avec sa capacité et son état d’inventaire. Ce n’est ni un genre musical ni l’identité d’un kit.
- **Copie enregistrée** : un nouveau PGM et ses sons écrits dans un dossier choisi. Une copie sur la SD constitue un emplacement de transport ; elle ne crée pas implicitement une sauvegarde sur le Mac.
- **Association sample–kit** : une référence vérifiée depuis un PGM vers un SND, avec provenance et niveau de certitude. Elle peut être multiple. Une absence de référence dans un relevé partiel ne signifie pas que le son est inutilisé.

## Flux attendu, exprimé par Nicolas

Composer un kit → le conserver dans sa bibliothèque → composer d’autres kits → choisir ceux à envoyer sur la SD → retrouver chaque kit par sa PART et son nom de PGM.

Les vues souhaitées sont trois lectures cohérentes : Samples avec leurs kits et emplacements ; Kits avec leurs copies présentes sur SD ; PART avec leur contenu. Le classement historique et les créations récentes doivent coexister sans réécrire les originaux.

## État livré en 0.5.2 (14)

L’app mémorise des dossiers, indexe leurs PGM et ceux des PART montées, permet la composition en mémoire et écrit des copies vers une destination validée. Samples parcourt un dossier à la fois. Une copie locale est conservée dans un dossier ajouté à la bibliothèque ; une copie uniquement sur SD n’a pas de sauvegarde locale implicite. La dernière copie du document courant est identifiée par son chemin.

Le catalogue durable indépendant des supports, le suivi des différentes copies d’un même kit, la vue globale des samples et les associations sample–kit dans l’interface ne sont pas encore implémentés. L’inventaire privé du 17 octobre fournit ces associations pour le relevé initial de la SD, comme données dérivées sur le Mac. Aucun tag n’est injecté dans les SND.

## Contraintes de cette passe

Déboguer et simplifier l’existant, sans ajouter de nettoyage automatique, d’écrasement ou de déplacement. SD en lecture uniquement pour l’investigation ; tests d’écriture sur dossiers locaux. Une PART invérifiable n’est jamais proposée comme vide. Les SEQ, APS, ALL et champs inconnus empêchent de déduire une autorisation de suppression d’une simple absence de référence PGM.
