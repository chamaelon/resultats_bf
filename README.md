# Plateforme RÉSULTATS-BF

Infrastructure hautement disponible, résiliente et décrite en code (Infrastructure as Code) avec **Vagrant** et **VirtualBox**.

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
- **`lb2` :** répartiteur de secours avec mécanisme de bascule Keepalived/VRRP (extension E1).
- **`app1` à `appN` :** serveurs applicatifs.
- **`bdd1` :** base PostgreSQL primaire.
- **`bdd2` :** réplica PostgreSQL.
- **`cache` :** service de cache défini dans la configuration.
- **`obs` :** serveur d'observabilité Prometheus et Grafana (extension E2).
- **Node Exporter :** collecte des métriques système des machines.

Les rôles et adresses IP sont définis dans `config/noeuds.yml`. Le réseau privé est configuré dans le `Vagrantfile`.

## 2. Prérequis techniques

Sur la machine hôte :

- VirtualBox compatible avec la version de Vagrant installée.
- Vagrant.
- Git pour récupérer le dépôt.
- Une mémoire vive suffisante pour exécuter les machines virtuelles ; 8 Go ou plus sont recommandés.

La box Vagrant utilisée est `bento/ubuntu-24.04`.

## 3. Récupération du projet

Cloner le dépôt :

```bash
git clone https://github.com/chamaelon/resultats_bf.git
cd resultats_bf
```

## 4. Configuration et démarrage

1. Vérifier le `Vagrantfile` et `config/noeuds.yml`.
2. Vérifier les variables d'environnement nécessaires à l'application et utiliser les fichiers d'exemple fournis.
3. Ne jamais versionner les fichiers `.env` contenant des secrets.
4. Démarrer les machines :

```bash
vagrant up
```

Consulter l'état des machines :

```bash
vagrant status
```

Pour reconstruire l'infrastructure depuis zéro, uniquement si la suppression des machines et de leurs données locales est acceptable :

```bash
vagrant destroy -f
vagrant up
```

## 5. Extension E1 — Haute disponibilité du répartiteur

L'extension E1 ajoute `lb2` comme répartiteur de secours. Keepalived/VRRP assure le mécanisme de bascule de l'adresse IP virtuelle selon la configuration déployée.

Le fonctionnement doit être vérifié en arrêtant `lb1` et en contrôlant que le service reste accessible par le mécanisme de secours.

## 6. Extension E2 — Observabilité

L'extension E2 ajoute un serveur `obs` utilisant :

- **Prometheus :** collecte et stockage des métriques.
- **Node Exporter :** exposition des métriques système sur le port 9100.
- **Grafana :** visualisation des métriques à l'aide de tableaux de bord.

Adresses prévues sur le réseau privé :

- Prometheus : `http://IP_OBS:9090`
- Grafana : `http://IP_OBS:3000`

Remplacer `IP_OBS` par l'adresse de la machine `obs` dans `config/noeuds.yml`.

La disponibilité des métriques dépend du démarrage des machines et de la configuration des cibles et exporteurs.

## 7. Scénarios de validation V1 à V6

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

## 8. Vérifications et dépannage

Commandes utiles :

```bash
vagrant status
```

Sur une machine Linux, pour vérifier les services concernés :

```bash
systemctl status prometheus-node-exporter
systemctl status prometheus
systemctl status grafana-server
```

Les deux dernières commandes sont destinées à la machine `obs`. Elles ne fonctionneront que si les services correspondants sont installés.

En cas d'échec, consulter les journaux du service concerné et vérifier la configuration des adresses IP, des ports et des cibles Prometheus.

## 9. Sécurité et bonnes pratiques

- Ne jamais committer de secrets ou de fichiers `.env` personnels.
- Conserver les fichiers d'exemple nécessaires au déploiement.
- Vérifier les modifications avant de les intégrer à `main`.
- Effectuer les opérations destructives uniquement lorsque cela est autorisé.
- Documenter les résultats réellement observés, sans inventer de mesures.