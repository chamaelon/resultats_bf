# RÉSULTATS-BF — infrastructure Vagrant

Projet de groupe du module **DevOps et infrastructures reproductibles**,
Master 1 Informatique, Université Joseph Ki-Zerbo / IBAM, année 2026–2027.

Le projet déploie une API de consultation de résultats sur un réseau privé
Vagrant. Le groupe configuré dans ce dépôt est le **groupe 7** (`192.168.62.0/24`).
Les machines et leurs adresses sont générées depuis le [Vagrantfile](Vagrantfile)
et décrites dans `config/noeuds.yml`.

## Architecture

| Machine(s) | Rôle | Adresse du groupe 7 | Démarrage |
|---|---|---|---|
| `bdd1` | PostgreSQL primaire | `192.168.62.31` | obligatoire |
| `bdd2` | Réplique PostgreSQL en flux | `192.168.62.32` | obligatoire |
| `app1`…`appN` | API HTTP sans état | `192.168.62.21`… | obligatoire, `NB_APP` configurable |
| `lb1` | HAProxy et sonde `/sante` | `192.168.62.11` | obligatoire |
| `lb2` | HAProxy de secours et Keepalived/VRRP (E1) | `192.168.62.12` ; VIP `192.168.62.5` | facultatif |
| `obs` | Prometheus, Grafana et exporters (E2) | `192.168.62.41` | facultatif |
| `cache` | Redis (E3) | `192.168.62.51` | facultatif |

## Synthèse de validation

Le socle a répondu sur `/sante` et `/resultat`, avec 50 000 lignes sur
chacune des bases et la réplication active. V1 a confirmé une répartition
10/10 ; V6 a mesuré le basculement de la VIP en 1,56 s. V2 a réussi à deux
travailleurs, tandis que son essai de stress à dix travailleurs a rencontré
des erreurs. V3 reste indicatif faute d’Apache Bench, V4 doit être relancé avec
son contrôle post-bascule corrigé, et V5 n’a pas validé la reconstruction sans
intervention manuelle. Voir la [synthèse et les limites détaillées](DOSSIER_ARCHITECTURE.md#synthèse-pour-la-soutenance)
et conserver les [rapports bruts](mesures/) comme preuves.

Le socle obligatoire utilise environ 3 Go de RAM. Les extensions sont
facultatives et se démarrent séparément pour limiter la mémoire consommée.
L'API expose `GET /resultat?matricule=…`, `GET /sante` et `GET /info`.
Le schéma SQL définit les champs `matricule`, `nom`, `serie`, `moyenne` et
`admis` ; `app/database/data.sql` génère 50 000 lignes reproductibles avec
`generate_series`.

## Prérequis

- Git
- Vagrant 2.4 ou ultérieur
- VirtualBox compatible avec la version de Vagrant installée
- 8 Go de RAM recommandés sur l'hôte

L'API est compilée dans la VM applicative ; Bun n'est pas requis sur l'hôte.

## Installation

Depuis PowerShell à la racine du dépôt :

```powershell
Copy-Item .env.exemple .env
```

Dans `.env`, gardez `GROUPE=7`, vérifiez `NB_APP=2` et remplacez les valeurs
de démonstration par des mots de passe locaux. Ne versionnez jamais ce fichier.
Le `.env.exemple` est un modèle, pas un jeu de secrets de production.

Démarrez le socle obligatoire :

```powershell
vagrant up
vagrant status
```

La configuration par défaut n'allume pas les extensions facultatives. Pour
les extensions E1 et E2 :

```powershell
vagrant up lb2 obs
```

Pour Redis (E3), si vous choisissez également cette extension :

```powershell
vagrant up cache
```

Le nombre d'instances applicatives se règle par `NB_APP` dans `.env`. Par
exemple, passez-le à `4`, puis exécutez `vagrant up` pour ajouter les nœuds.
Le répartiteur génère sa liste de serveurs depuis `config/noeuds.yml`.

## Accès aux services

- API via le port transféré de `lb1` : `http://localhost:8080/info`,
  `http://localhost:8080/sante` et
  `http://localhost:8080/resultat?matricule=146066W`.
- Avec E1 démarrée, VIP Keepalived : `http://192.168.62.5/`.
- Prometheus (E2) : `http://192.168.62.41:9090`.
- Grafana (E2) : `http://192.168.62.41:3000`.
- Statistiques HAProxy : `http://192.168.62.11:8404/stats`.

Le port `8080` de l'hôte est transféré par `lb1` uniquement ; pour valider la
bascule VRRP, utilisez la VIP et le scénario V6 plutôt que `localhost:8080`.

## Scénarios de validation

Les scripts PowerShell créent un rapport horodaté dans `mesures/`. Depuis la
racine du dépôt, lancez par exemple :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validation_scenario_v1.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\validation_scenario_v2.ps1 -Travailleurs 2
powershell -ExecutionPolicy Bypass -File .\scripts\validation_scenario_v3.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\validation_scenario_v4.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\validation_scenario_v5.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\validation_scenario_v6.ps1
```

V1–V4 et V6 modifient l'état des VM pendant le test ; V5 détruit puis recrée
les VM. Lisez le script concerné avant exécution, sauvegardez toute donnée à
conserver et ne lancez V5 que lorsque la destruction est autorisée.
Les résultats doivent être contrôlés et commentés après chaque exécution.
Le rapport V1 final de la campagne est
[`V1_20261027_180252.md`](mesures/V1_20261027_180252.md).
V2 a réussi à deux travailleurs ; l'essai de stress à dix travailleurs a
rencontré des erreurs sur l'hôte de validation. V3 doit être mesuré avec
Apache Bench (`ab`) : le générateur PowerShell de secours fournit uniquement
des résultats indicatifs.

Les objectifs à démontrer sont :

| Scénario | Vérification |
|---|---|
| V1 | 20 appels `/info`, répartition équilibrée entre toutes les applications |
| V2 | Panne d'un serveur applicatif sous charge, exclusion en moins de 5 s |
| V3 | `ab -n 2000 -c 50`, comparaison avec `NB_APP=2` puis `NB_APP=4` |
| V4 | Panne de `bdd1`, promotion de `bdd2`, reprise et durée mesurées |
| V5 | `vagrant destroy -f` puis reconstruction et vérification de l'API |
| V6 | Panne de `lb1`, reprise via la même VIP en moins de 5 s |

Les mesures de débit dépendent des ressources de l'hôte ; rapportez les
résultats observés sans extrapoler ni inventer de chiffres.

## Exploitation et sécurité

- Les scripts de validation V4 et V5 changent l'état des bases/VM. V4 promeut
  `bdd2` et peut laisser `bdd1` arrêtée ; relancez V5 pour repartir d'un état
  propre, après avoir vérifié que la destruction est autorisée.
- Les fichiers `.env` sont ignorés par Git. Utilisez `.env.exemple` pour
  documenter les variables nécessaires, jamais des mots de passe réels.
- Tout le trafic entre les VM utilise le réseau privé Vagrant ; seul `lb1`
  publie le port HTTP `8080` sur l'hôte.
- Les scripts de provisionnement sont conçus pour être rejoués. Vérifiez
  toutefois l'idempotence par deux exécutions consécutives de
  `vagrant provision` et conservez les résultats.

## Livrables de soutenance

- [Dossier d'architecture](DOSSIER_ARCHITECTURE.md) — base de rédaction
  structurée selon les exigences du sujet ; à mettre en page sur 10 à 15 pages
  et à compléter avec les preuves encore attendues.
- [Journal de bord](JOURNAL_DE_BORD.md) — synthèse de la campagne technique ;
  les noms, rôles réels, réunions et rotations doivent être renseignés par les
  quatre membres du groupe.
- Les [rapports V1–V6](mesures/) contiennent les mesures effectivement prises.
  V3 avec Apache Bench, le rapport V4 après correction et V5 sans
  provisionnement manuel restent à compléter avant de déclarer toutes les
  validations acquises.
Ne pas remplacer les mesures échouées ou incomplètes par des valeurs estimées.
Ne pas remplacer les mesures échouées ou incomplètes par des valeurs estimées.
