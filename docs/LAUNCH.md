# Vendre Kit for MPC3000 : plan de lancement

## État au 6 novembre 2026, fin de journée

| Sujet | Décidé et en place |
|---|---|
| Nom | **Kit for MPC3000**, partout : site, Stripe, mentions légales, app. La machine s'écrit « MPC3000 ». Le site et Stripe sont alignés ; l'app (titre, DMG) est confiée à la session de revue. |
| Page | https://kitmpc3000.rewolf.studio (anglais) et `/fr/`, hébergée sur Vercel (projet `kitmpc3000`, dossier `site/`). |
| Paiement | Stripe en **mode réel** avec **Managed Payments** : Stripe (via Link) vend à ta place et gère la TVA, les reçus, les factures et les litiges, pour 3,5 % de plus par vente. Produit `prod_VZvjTdxJ5PeHgn`, 29 € TTC ; lien `https://buy.stripe.com/bJe00le8mgyA8Ob0rCfAc00` (`plink_1UYluHPc3KBNseSeyFyUCCtD`), qui renvoie vers `/thanks/` après paiement. |
| TVA | Assujetti. Le prix affiché est TTC (4,83 € de TVA sur 29 €), calculé par Managed Payments. |
| Livraison | **Lien de téléchargement réservé aux acheteurs** : après paiement, Stripe renvoie vers `/thanks/?key=<code>`. Le code n'existe que dans la redirection du lien de paiement ; le dépôt public n'en garde que l'empreinte SHA-256 (`site/api/download.js`). Avec un code valide, `/api/download` sert le DMG depuis le stockage privé Vercel Blob `kitmpc3000-releases` (`releases/Kit-for-MPC3000-Apple-Silicon.dmg`). En ligne : 0.9.2 (31) notarisée, SHA-256 `a7b565d4…bd3b6b` (corrige la copie sur SD de la 0.9.1). La fonction lit sans cache, sinon un écrasement servirait l'ancienne version. Publier une version = écraser ce fichier (`vercel blob put … --allow-overwrite true`, avec `VERCEL_OIDC_TOKEN` retiré de l'environnement). Si le lien circule : nouveau code, nouvelle empreinte dans `download.js`, nouvelle redirection dans Stripe. Choisi à la place d'une vérification par clé Stripe, qu'il aurait fallu copier à la main dans Vercel. |
| Apple | Programme développeur actif, certificat « Developer ID Application: Nicolas Doucet (94497Y576D) » installé. Il manque le profil `kitstudio-notary`. |

Ce qu'il reste à rendre vrai avant la première livraison : le DMG notarisé, l'essai sur la MPC,
le `Default.pgm` venu de ta machine, l'adresse de contact et les mentions légales sur les pages.
Vercel en offre gratuite interdit l'usage commercial : passer en Pro ou déplacer la page.


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
4. **Nom : Kit for MPC3000** (décidé). Page et Stripe faits ; reste l'app et le DMG, puis refaire les captures.
5. **Ajouter une vraie capture d'écran** (`site/screenshot.png`), prise avec ta vraie carte.
6. **Remplir les zones jaunes** : modèle de l'adaptateur SCSI→SD, adresse de contact, mentions légales,
   prestataire de paiement.
7. **Paiement** : fait (Stripe, Managed Payments, lien branché). Reste à livrer le DMG à chaque acheteur.

## Décisions à prendre

| Sujet | Recommandation | Pourquoi |
|---|---|---|
| Nom | ~~Kit Studio~~ → décidé : **Kit for MPC3000** | « for MPC3000 » dit avec quoi l'app fonctionne ; la page garde la mention de non-affiliation. « MPC Editor » existe déjà. |
| Prix | **29 € TTC**, une fois | Assez bas pour un outil sans SAV, assez haut pour couvrir Apple dès 5 ventes par an. |
| Paiement | Décidé : **Stripe Managed Payments** (merchant of record de Stripe) | Il vend à ta place : TVA, factures, litiges. Voir Paiement. |
| Remboursement | **Oui, 14 jours, sans débat** | Rassure sans créer de SAV : un mail, un clic chez le prestataire. |
| Protection anti-copie | **Aucune** | L'app ne se connecte jamais à internet : une vérification de licence casserait cette promesse et créerait du support. |
| Dépôt GitHub | **Privé tant que rien n'est décidé** | Un dépôt public laisse quiconque compiler l'app. Ouvrir le code reste possible plus tard ; le refermer ne l'est pas vraiment. |
| Langue | Fait : **français et anglais** depuis la 0.9.0 (l'app suit la langue du Mac, français par défaut) | La plupart des propriétaires de MPC3000 sont anglophones. Les captures du site restent en français. |
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
