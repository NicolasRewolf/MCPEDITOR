# Vendre Kit Studio : plan de lancement

Pré-étude du 6 novembre 2026. Rien n'est acheté, aucun compte n'est ouvert, rien n'est publié.
Les prix et règles cités ont été relevés le 6 novembre 2026 ; les revérifier au moment de s'inscrire.

La page de vente est en ligne sur https://kitmpc3000.rewolf.studio : en anglais à la racine
([`site/index.html`](../site/index.html)), en français sous `/fr/` ([`site/fr/index.html`](../site/fr/index.html)).
Les deux partagent `site/styles.css` et `site/main.js` ; un changement de texte se fait dans les deux.
Les zones surlignées en jaune (classe `todo`) sont à remplir. Le bouton d'achat reste inactif tant que
`CHECKOUT_URL`, dans `site/main.js`, est vide.

## Avant d'ouvrir la vente

La page ne doit rien dire de faux le jour où elle est en ligne. Voici ce qui n'est pas encore vrai :

1. **Faire l'aller-retour réel sur la MPC.** C'est le bloquant n°1. À ce jour, aucune bank écrite par
   Kit Studio n'a été chargée sur la machine (le README le dit). Faire au moins : une bank de 16 pads
   copiée sur une PART vide, chargée sur la MPC, chaque pad joué, noms, découpes et accordage vérifiés.
   Puis une bank qui remplit presque une PART. Noter l'OS, l'adaptateur et la carte utilisés.
2. **Remplacer le programme modèle.** `Default.pgm` vient du dépôt izzyreal/mpc, sous GPL v3 ; ses droits
   de redistribution ne sont pas tranchés. Le plus simple : créer un programme vide sur ta propre MPC,
   le sauver sur la SD et en faire le nouveau `Default.pgm`. Il ne doit alors rien à personne.
3. **Signer et notariser l'app** (section Apple). Sans ça, macOS bloque l'app téléchargée et la page
   ment quand elle dit « elle s'ouvre sans alerte ».
4. **Choisir le nom affiché** (section Nom) et le changer dans l'app, la page et le DMG.
5. **Ajouter une vraie capture d'écran** (`site/screenshot.png`), prise avec ta vraie carte.
6. **Remplir les zones jaunes** : modèle de l'adaptateur SCSI→SD, adresse de contact, mentions légales,
   prestataire de paiement.
7. **Ouvrir le compte de paiement**, créer le produit, déposer le DMG, coller le lien dans `CHECKOUT_URL`.

## Décisions à prendre

| Sujet | Recommandation | Pourquoi |
|---|---|---|
| Nom | **Kit Studio**, sous-titré « pour MPC 3000 » | Voir ci-dessous : « MPC » est une marque et « MPC Editor » existe déjà. |
| Prix | **29 € TTC**, une fois | Assez bas pour un outil sans SAV, assez haut pour couvrir Apple dès 5 ventes par an. |
| Paiement | **Un « merchant of record »** (Lemon Squeezy ou Paddle) plutôt que Stripe en direct | Il vend à ta place : TVA, factures, litiges. Voir Paiement. |
| Remboursement | **Oui, 14 jours, sans débat** | Rassure sans créer de SAV : un mail, un clic chez le prestataire. |
| Protection anti-copie | **Aucune** | L'app ne se connecte jamais à internet : une vérification de licence casserait cette promesse et créerait du support. |
| Dépôt GitHub | **Privé tant que rien n'est décidé** | Un dépôt public laisse quiconque compiler l'app. Ouvrir le code reste possible plus tard ; le refermer ne l'est pas vraiment. |
| Langue | **Français au lancement**, anglais ensuite si ça prend | La plupart des propriétaires de MPC 3000 sont anglophones : l'anglais élargit le marché, mais coûte une traduction de l'app. |
| Mac Intel | **Non** | Une version universelle se compile facilement, mais elle n'a jamais été testée sur Intel. |

### Nom et marque

- **MPC** et **MPC 3000** sont des marques d'inMusic (Akai Professional). Les mettre dans le nom du produit
  expose à une demande de retrait. Les citer pour dire avec quoi l'app fonctionne (« pour MPC 3000 »)
  est l'usage habituel ; la page l'accompagne d'une mention de non-affiliation.
- **« MPC Editor »** est déjà le nom d'un ancien outil Windows qui fait la même chose
  ([fil mpc-forums](https://www.mpc-forums.com/viewtopic.php?p=1830860)). À éviter.
- Le dépôt GitHub s'appelle `MCPEDITOR` (inversion de lettres). On peut le renommer sur GitHub
  sans perdre l'historique ; l'ancienne adresse redirige.
- Changer le nom affiché sans toucher aux identifiants internes : `CFBundleIdentifier` et le dossier
  `~/Library/Application Support/MPC Kit Studio` doivent rester tels quels, sinon la bibliothèque
  des personnes déjà équipées disparaît.

### Domaine

Disponibilités relevées le 6 novembre 2026 (registre Vercel) :

| Domaine | Libre | 1re année | Renouvellement |
|---|---|---|---|
| kit3000.com | oui | 12,03 $ | 12,03 $ |
| kit3000.app | oui | 9,99 $ | 15 $ |
| pgmkit.com | oui | 12,03 $ | 12,03 $ |
| kitstudio.app | **non** | | |

Option sans achat : un sous-domaine de `rewolf.studio`, que tu possèdes déjà (par exemple
`kit.rewolf.studio`). Acheter un domaine dédié seulement si la vente démarre.
Hébergement de la page : statique, gratuit sur Vercel ou GitHub Pages (dossier `site/`).

## Prix

- Coûts fixes par an : Apple 99 $ (≈ 99 €), domaine ≈ 12 €. Hébergement : 0 €.
- Frais par vente chez un merchant of record : environ 5 % + 0,50 $, soit ≈ 2 € sur 29 €.
- Équilibre : environ **5 ventes par an**. Au-delà, c'est du bonus.
- Le marché est petit : il faut une MPC 3000, l'OS Vailixi 3.50, un adaptateur SD et un Mac Apple Silicon.
  Compter en dizaines de ventes, pas en milliers. 39 € reste défendable ; au-dessus, l'absence de SAV
  devient difficile à assumer.

## Paiement

**Stripe en direct** est possible (un lien de paiement suffit), mais c'est toi le vendeur : facture à
chaque client, mentions de TVA, et dès 10 000 € de ventes à des particuliers d'autres pays de l'UE
(cumul sur l'année et la précédente), TVA du pays de l'acheteur via le guichet OSS
([Keobiz](https://www.keobiz.fr/?p=30583)). En franchise en base, le seuil des prestations de services est
de 37 500 € ([Tide](https://www.tide.co/fr-FR/blog/fiscalite-et-impots/micro-entreprise-tva/)) ; à faire
confirmer pour la vente de licences logicielles.

**Un merchant of record** (MoR) achète et revend à ta place. Tu reçois des virements et tu factures un seul
client, le MoR. Il héberge le DMG, envoie le lien de téléchargement et la facture, gère les remboursements.

| Option | Frais annoncés | Pour toi |
|---|---|---|
| Lemon Squeezy | ≈ 5 % + 0,50 $ | Racheté par Stripe ; héberge les fichiers ; clés de licence possibles mais inutiles ici. |
| Paddle | ≈ 5 % + 0,50 $ | Indépendant, validation du compte plus stricte. |
| Stripe Managed Payments | ≈ 3,5 % en plus des frais Stripe | Le MoR de Stripe ; annoncé pour la France, éligibilité à vérifier dans le tableau de bord. |
| Gumroad | ≈ 10 % + 0,50 $ | Le plus simple, le plus cher. |

Sources (blogs comparatifs, à recouper avec les pages officielles) :
[dev.to, 2026](https://dev.to/jettfu/stripe-vs-paddle-vs-lemon-squeezy-fee-comparison-2026-2c77),
[Stripe Managed Payments](https://docs.stripe.com/payments/managed-payments),
[annonce Stripe Paris 2026](https://stripe.com/newsroom/news/stripe-tour-paris-2026).

Recommandation : **Lemon Squeezy**, ou Stripe Managed Payments si ton compte y a accès.
Dans tous les cas, demander à l'URSSAF ou à un comptable si ton activité déclarée couvre la vente
de licences de logiciel, et dans quelle catégorie déclarer ces recettes.

## Apple

Pour qu'une app téléchargée hors Mac App Store s'ouvre sans blocage, il faut
([Apple, Developer ID](https://developer.apple.com/support/developer-id)) :

1. **Adhérer à l'Apple Developer Program** en tant que particulier (99 $ par an ; à confirmer sur
   developer.apple.com/programs). Pas besoin de numéro D-U-N-S en individuel.
2. **Créer un certificat « Developer ID Application »** dans Xcode (Réglages → Comptes → Gérer les certificats).
3. **Créer un mot de passe d'app** sur appleid.apple.com, puis enregistrer le profil de notarisation :
   `xcrun notarytool store-credentials kitstudio-notary --apple-id … --team-id … --password …`
4. Lancer **`scripts/release-signed.sh`** (préparé, jamais exécuté) : signature Developer ID avec
   runtime renforcé, notarisation et agrafage de l'app puis du DMG, contrôle Gatekeeper, manifeste.

La notarisation n'a pas de coût en plus. Le Mac App Store n'est pas recommandé : il impose le bac à sable,
qui gênerait l'accès direct aux PART de la SD et aux dossiers de samples.

## Mises à jour

Pas de mise à jour automatique : elle demanderait une connexion à internet. Une nouvelle version est déposée
chez le prestataire ; les acheteurs la retéléchargent depuis leur mail d'achat. La page le dit ainsi.

## Séparation des dépôts

- Ce dépôt (`~/Desktop/MPC EDITOR`, distant `NicolasRewolf/MCPEDITOR`) contient l'app avec ses 29 commits
  d'historique, extraits de `mac/KitStudio` du dépôt Homework 4.0, plus ses deux workflows CI.
  Les rapports `reports/kit_studio_*` sont restés dans le dépôt de recherche.
- Chemins adaptés : workflows CI, portée du manifeste de livraison, liens du README.
- Le test qui relit le corpus de PGM réels du dépôt de recherche est ignoré ici, comme prévu par le test.
- Reste à faire dans le dépôt Homework 4.0, une fois ce dépôt poussé : retirer `mac/KitStudio` et les
  workflows `kit-studio*.yml`, et laisser un renvoi vers ce dépôt.
