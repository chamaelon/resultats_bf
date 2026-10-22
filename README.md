voici:# Plateforme RÉSULTATS-BF

Infrastructure hautement disponible, résiliente et décrite en code (*Infrastructure as Code*) avec **Vagrant** et **VirtualBox**.

- **Contexte :** Projet de groupe — Master 1 Informatique, Virtualisation et Cloud Computing
- **Établissement :** Institut Supérieur de l'Informatique et du Management (IBAM), Université Joseph Ki-Zerbo
- **Enseignant :** Dr SOMDA Flavien Hervé
- **Année universitaire :** 2026-2027

---

## 1. Vue d'ensemble du projet

La plateforme **RÉSULTATS-BF** permet aux candidats de consulter leurs résultats d'examens par numéro de matricule. L'architecture vise deux objectifs principaux :

1. **Résilience :** maintenir le service malgré certaines pannes de composants.
2. **Scalabilité :** permettre l'ajout de serveurs applicatifs sans réécrire toute la configuration.

### Architecture

- **`lb1` :** répartiteur de charge HAProxy avec sonde de santé `/sante`.
- **`lb2` :** répartiteur de secours utilisant Keepalived/VRRP pour la bascule (extension E1).
- **`app1` à `appN` :** serveurs applicatifs.
- **`bdd1` :** base PostgreSQL primaire.
- **`bdd2` :** réplica PostgreSQL.
- **`cache` :** service de cache défini dans la configuration.
- **`obs` :** serveur d'observabilité Prometheus et Grafana (extension E2).
- **Node Exporter :** collecte des métriques système des machines.

Les rôles et adresses IP des machines sont définis dans `config/noeuds.yml`, généré par le `Vagrantfile`.

### Réseau privé

Le réseau est calculé à partir du numéro de groupe :

`192.168.(55 + GROUPE).0/24`

Par défaut, `GROUPE=1`, ce qui correspond au réseau `192.168.56.0/24`.

## 2. Prérequis techniques

Sur la machine hôte :

- **VirtualBox**, compatible avec la version de Vagrant installée.
- **Vagrant**.
- **Git**, pour récupérer le dépôt.
- Une mémoire vive suffisante pour exécuter les machines virtuelles ; **8 Go ou plus sont recommandés**.

La box Vagrant utilisée est `bento/ubuntu-24.04`, version `202404.26.0`.

## 3. Récupération du projet

Cloner le dépôt :

```bash
git clone https://github.com/chamaelon/resultats_bf.git
cd resultats_bf
```

## 4. Configuration de l'environnement

Avant de démarrer l'infrastructure :

1. Vérifier le `Vagrantfile` et les paramètres de configuration.
2. Vérifier les variables d'environnement nécessaires à l'application.
3. Utiliser les fichiers d'exemple disponibles dans `app/api/`, lorsqu'ils sont fournis, pour préparer la configuration locale.
4. Ne jamais versionner les fichiers `.env` contenant des secrets.

Les paramètres principaux du `Vagrantfile` sont :

- `GROUPE` : numéro du groupe, compris entre 1 et 8 ; valeur par défaut : `1`.
- `NB_APP` : nombre de serveurs applicatifs ; valeur par défaut : `2`.

Ces variables peuvent être adaptées selon les besoins du déploiement.

## 5. Démarrage de l'infrastructure

Démarrer les machines :

```bash
vagrant up
```

Consulter leur état :

```bash
vagrant status
```

Pour reconstruire l'infrastructure depuis zéro, uniquement si la suppression des machines et de leurs données locales est acceptable :

```bash
vagrant destroy -f
vagrant up
```

**Attention :** `vagrant destroy -f` supprime les machines virtuelles gérées par Vagrant et peut entraîner la perte des données qu'elles contiennent.

## 6. Extension E1 — Haute disponibilité du répartiteur

L'extension E1 ajoute `lb2` comme répartiteur de secours. Keepalived/VRRP assure le mécanisme de bascule de l'adresse IP virtuelle selon la configuration déployée.

Le fonctionnement doit être vérifié en arrêtant `lb1` et en contrôlant que le service reste accessible grâce au mécanisme de secours.

Le nœud `lb2` est déclaré facultatif dans le `Vagrantfile` (`required: false`). Son déploiement et son fonctionnement dépendent donc de la configuration retenue.

## 7. Extension E2 — Observabilité

L'extension E2 ajoute un serveur `obs` utilisant :

- **Prometheus :** collecte et stockage des métriques.
- **Node Exporter :** exposition des métriques système sur le port `9100`.
- **Grafana :** visualisation des métriques à l'aide de tableaux de bord.

### Accès aux services

Les adresses prévues sur le réseau privé sont :

- **Prometheus :** `http://IP_OBS:9090`
- **Grafana :** `http://IP_OBS:3000`

Remplacer `IP_OBS` par l'adresse de la machine `obs` définie dans `config/noeuds.yml`.

Les métriques disponibles dépendent du démarrage des machines, de la configuration des cibles Prometheus et de la disponibilité des exporteurs concernés.

## 8. Scénarios de validation V1 à V6

Exécuter les tests sur une infrastructure démarrée. Consigner les commandes, les résultats, les erreurs et les temps de reprise. Les résultats ci-dessous sont des critères de vérification, pas des mesures déjà obtenues.

| Test | Procédure | Vérification attendue |
|---|---|---|
| **V1 — Répartition de charge** | Effectuer 20 appels à `/info`. | Observer les serveurs applicatifs sollicités et mesurer la répartition. |
| **V2 — Panne applicative** | Arrêter `app1` pendant des requêtes. | Vérifier la continuité du service et mesurer la période de dégradation. |
| **V3 — Montée en charge** | Si ApacheBench est installé, exécuter `ab -n 2000 -c 50`, puis comparer différentes valeurs de `NB_APP`. | Comparer le débit et le nombre d'erreurs. |
| **V4 — Panne de la base primaire** | Arrêter `bdd1` et observer le comportement de l'application et la procédure de bascule. | Vérifier la disponibilité des données et mesurer le temps de reprise. |
| **V5 — Reconstruction** | Exécuter `vagrant destroy -f`, puis `vagrant up`, si la destruction est autorisée. | Vérifier la reconstruction et mesurer sa durée. |
| **V6 — Panne du répartiteur** | Arrêter `lb1`. | Vérifier la disponibilité du service via le mécanisme de secours et mesurer le temps de bascule. |

### Compte rendu des tests

Pour chaque test, noter :

- la date et les conditions d'exécution ;
- les commandes exécutées ;
- le résultat obtenu ;
- les erreurs ou requêtes perdues ;
- le temps de reprise ;
- la conclusion : réussi, échoué ou à reprendre.

Ne renseigner aucune mesure avant d'avoir exécuté le test correspondant.

## 9. Vérifications et dépannage

### État de l'infrastructure

```bash
vagrant status
```

### État des services de supervision

Sur la machine `obs` :

```bash
systemctl status prometheus
systemctl status grafana-server
systemctl status prometheus-node-exporter
```

Ces commandes permettent de vérifier l'état des services concernés lorsqu'ils sont installés.

En cas d'échec, consulter les journaux du service concerné et vérifier les adresses IP, les ports, les cibles Prometheus et la disponibilité des machines.

## 10. Sécurité et bonnes pratiques

- Ne jamais committer de secrets ou de fichiers `.env` personnels.
- Conserver les fichiers d'exemple nécessaires au déploiement.
- Vérifier les modifications avant de les intégrer à `main`.
- Effectuer les opérations destructives uniquement lorsque cela est autorisé.
- Documenter les résultats réellement observés, sans inventer de mesures.