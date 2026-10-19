# Icône MPC Kit Studio

`AppIcon.png` est la source de l’icône de l’application ; `AppIcon.icns` est le fichier livré dans le bundle macOS. Régénération des tailles standard et Retina : `bash scripts/build-icon.sh`, depuis `mac/KitStudio`.

Créée le 19 octobre 2026 avec l’outil intégré de génération d’images, puis affinée avec le même outil. Aucun logo Akai ni texte n’est incorporé. Les redimensionnements pour le paquet ICNS utilisent les outils macOS `sips` et `iconutil`.

## Brief de génération

Une icône macOS carrée pour MPC Kit Studio : boîtier ivoire arrondi, écran vert sauge et exactement seize pads anthracite disposés en quatre rangées de quatre, dont un vermillon. Vue de face, proportions simples, relief discret, inspiration industrielle sobre, lisibilité dans le Dock. Extérieur transparent, marges régulières, aucun texte, logo, câble ou décor.

## Consigne d’affinage

Conserver le boîtier, l’écran, la grille et le pad rouge. Nettoyer les fragments et franges à l’extérieur du boîtier ; conserver une silhouette arrondie et un fond transparent. Ne pas ajouter ou changer les éléments internes.
