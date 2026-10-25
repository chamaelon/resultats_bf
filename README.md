# Projet RÉSULTATS-BF - Infrastructure DevOps

## 📌 Présentation du Projet
Ce projet a été réalisé dans le cadre du module **DevOps et infrastructures reproductibles** (M1 Informatique) encadré par le Dr SOMDA Flavien Hervé.
Il vise à déployer une infrastructure hautement disponible, résiliente et automatisée pour la consultation des résultats de concours de la fonction publique au Burkina Faso.

L'infrastructure est entièrement pilotée par le code (Infrastructure as Code) via **Vagrant** et **VirtualBox**, et satisfait les exigences de scalabilité, de reproductibilité et de sécurité.

**Groupe :** 7
**Réseau privé du groupe :** `192.168.62.0/24`
* **Contexte :** Projet de groupe - Master 1 Informatique / Virtualisation et Cloud Computing
* **Établissement :** Institut Supérieur de Informatique et de Management (IBAM), Université Joseph Ki Zerbo
* **Enseignant :** Dr SOMDA Flavien Hervé
* **Année universitaire :** 2026-2027

---

## 🏗️ Architecture de l'Infrastructure

Notre plateforme repose sur une architecture à trois niveaux (N-Tiers) :
1. **Étage de Répartition de Charge (Load Balancing) & Haute Disponibilité** :
   - `lb1` (Master) et `lb2` (Backup) propulsés par **HAProxy**.
   - Redondance IP virtuelle (VIP) gérée par **Keepalived / VRRP** (192.168.62.10).
2. **Étage Applicatif (Middleware Node.js)** :
   - Multiples nœuds applicatifs (`app1`, `app2`, etc.) exécutant une API RESTful Node.js (TypeScript) sans état.
   - Intégration d'un système de mise en cache **Redis**.
3. **Étage de Données (Base de données PostgreSQL)** :
   - Base de données primaire (`bdd1`).
   - Base de données secondaire (`bdd2`) en réplication de flux (Streaming Replication) pour une résilience en cas de panne.
4. **Étage d'Observabilité** (Bonus) :
   - Monitoring via **Prometheus** et **Grafana**.
La plateforme **RÉSULTATS-BF** permet aux candidats de consulter leurs résultats d'examens par numéro de matricule. L'architecture a été pensée pour répondre à deux impératifs non fonctionnels majeurs :

1. **La résilience :** Le système continue de fonctionner malgré la panne d'un composant (serveur applicatif ou base de données).
2. **La scalabilité :** L'absorption d'un pic de trafic s'effectue horizontalement par simple ajout de serveurs, sans réécriture de la configuration.

### Architecture Cible (Socle Obligatoire + Extensions)

* **Répartition de charge (`lb1`) :** HAProxy configuré dynamiquement avec une sonde de santé (`/sante`).
* **Répartiteur de secours (`lb2`) :** HAProxy et Keepalived/VRRP assurent le mécanisme de bascule en cas de panne de `lb1` (extension E1).
* **Serveurs applicatifs (`app1` à `appN`) :** Services stateless (Python/Node.js) répartis sur un réseau privé.
* **Base de données (`bdd1` & `bdd2`) :** PostgreSQL avec un nœud primaire en lecture/écriture (`bdd1`) et une réplique en flux (`bdd2`).
* **Cache (`cache`) :** Machine dédiée au service de cache.
* **Supervision (`obs`) :** Serveur de supervision avec Prometheus et Grafana (extension E2).
* **Réseau privé :** Sous-réseau `192.168.5X.0/24` (où `X = 55 + numéro de groupe`).

Les rôles et les adresses IP des machines sont définis dans `config/noeuds.yml`.

---

## 🚀 Prérequis

Pour lancer l'environnement, vous devez installer les outils suivants sur votre machine hôte :
- **VirtualBox** (version >= 7.x recommandée)
- **Vagrant** (version >= 2.4.x)
- *Git* (pour cloner le dépôt)
* **Outils requis sur la machine hôte :**
  * [VirtualBox](https://www.virtualbox.org/) (version 6.1 ou supérieure)
  * [Vagrant](https://www.vagrantup.com/) (version 2.2 ou supérieure)
  * Git
* **Configuration matérielle recommandée :**
  * 8 Go de RAM minimum sur l'hôte (les extensions peuvent nécessiter davantage de mémoire).
* **Box Vagrant utilisée :** `bento/ubuntu-24.04` (version épinglée `202404.26.0`).

---

## ⚙️ Procédure de Déploiement (Mise en route)

L'un des objectifs majeurs (Exigence R1) de ce projet est la **reconstruction intégrale**. Voici comment déployer le tout à partir de zéro :

1. **Cloner le projet** et se rendre à la racine :
   ```bash
   git clone <URL_DU_DEPOT>
   cd projet
   ```

2. **Créer le fichier de variables d'environnement (`.env`)** :
   Le dépôt contient un fichier d'exemple (pour respecter la règle consistant à ne jamais comiter de mots de passe). Vous devez créer votre configuration :
   ```bash
   cp .env.exemple .env
   ```
   *(Vous pouvez ouvrir `.env` et ajuster les mots de passe si vous le souhaitez. Assurez-vous que `GROUPE=7` est bien défini).*

3. **Lancer le provisionnement Vagrant** :
   ```bash
   vagrant up
   ```
   *Note : Cette commande télécharge l'image Ubuntu officielle (environ 600 Mo) et configure l'intégralité des nœuds (Load Balancers, Base de données, Application, Observabilité).*

---

## 🌐 Accès aux Services

Une fois l'infrastructure montée, voici les points d'accès exposés :

- **API REST (IP Virtuelle de Haute Disponibilité)** :
  - Info Serveur : `http://192.168.62.10/info`
  - Santé Base de Données : `http://192.168.62.10/sante`
  - Consultation de Résultat : `http://192.168.62.10/resultat?matricule=<MATRICULE>`
  *(Si vous naviguez depuis votre hôte, vous pouvez aussi attaquer `http://localhost:8080/info` ou `http://localhost:8080/sante` via la redirection de port).*

- **Statistiques HAProxy** :
  - `http://192.168.62.10:8404` (monitoring du répartiteur actif).

---

## 🧪 Scénarios de Test et Tolérance aux Pannes

### 1. Tolérance d'un serveur applicatif
L'infrastructure détecte un nœud applicatif défaillant en moins de 5 secondes grâce à la sonde HAProxy.
- Coupez une application : `vagrant halt app1`
- Testez les requêtes, tout continue de fonctionner sur les nœuds restants.

### 2. Tolérance du répartiteur (Bascule VRRP)
L'IP virtuelle est portée par `lb1`. S'il meurt, `lb2` prend le relais instantanément.
- Coupez le load balancer primaire : `vagrant halt lb1`
- L'API reste joignable à `http://192.168.62.10/info`.

### 3. Tolérance de la base de données (Failover BDD)
Si la base de données primaire (`bdd1`) tombe (ex: `vagrant halt bdd1`), l'application renverra des erreurs 503 lors des accès aux données.
Une procédure de **basculement manuel** est nécessaire :
1. Connectez-vous à la réplique (`bdd2`) : `vagrant ssh bdd2`
2. Promouvez-la en maître : `sudo -u postgres psql -c 'SELECT pg_promote();'`
3. Sur chaque nœud applicatif (`app1`, `app2`), mettez à jour la configuration pour pointer vers `bdd2` (`192.168.62.32`) :
   ```bash
   sudo sed -i 's/192.168.62.31/192.168.62.32/g' /etc/api-app.env
   sudo systemctl restart api-app
   ```
Dès lors, les services redeviennent fonctionnels.

---

## 🔒 Sécurité et Qualité

- **Aucun secret dans le code (Exigence R7)** : Tous les mots de passe (PG_PASS, VRRP_AUTH_PASS) sont injectés dynamiquement depuis le fichier isolé `.env`.
- **Idempotence des scripts (Exigence R2)** : Vous pouvez lancer `vagrant up --provision` autant de fois que souhaité, les configurations ne casseront pas et les services ne se relanceront que si strictement nécessaire.
- **Réseau privé (Exigence R8)** : Une isolation stricte équipe nos VMs. Les bases de données sont inaccessibles par une machine autre qu'un serveur app ou l'autre base de données.

---
*Ce fichier couvre le Livrable L1 du projet RÉSULTATS-BF.*
1. Cloner le dépôt sur votre poste :

   ```bash
   git clone https://github.com/chamaelon/resultats_bf.git
   cd resultats_bf
   ```

2. Vérifier le `Vagrantfile` et le fichier `config/noeuds.yml` afin de confirmer le numéro de groupe et les adresses IP utilisées.

3. Démarrer l'infrastructure :

   ```bash
   vagrant up
   ```

4. Vérifier l'état des machines virtuelles :

   ```bash
   vagrant status
   ```

Le nœud `lb2` est déclaré facultatif (`required: false`). Il peut être démarré explicitement avec :

```bash
vagrant up lb2
```

**Attention :** la commande suivante détruit les machines virtuelles gérées par Vagrant et peut entraîner la perte des données qu'elles contiennent. Ne l'exécuter que si la reconstruction est autorisée.

```bash
vagrant destroy -f
vagrant up
```

---

## 4. Extension E1 — Haute disponibilité du répartiteur

L'extension E1 ajoute `lb2` comme répartiteur de secours. HAProxy assure la répartition de charge et Keepalived/VRRP gère le mécanisme de bascule selon la configuration déployée.

Les tests de `lb1` et `lb2` ont été effectués et le fonctionnement de la bascule a été vérifié.

La validation porte notamment sur :

* le fonctionnement du répartiteur principal `lb1` ;
* le fonctionnement du répartiteur de secours `lb2` ;
* l'accessibilité du service lors de l'arrêt du répartiteur principal ;
* la reprise du service par le répartiteur de secours.

---

## 5. Extension E2 — Supervision et observabilité

L'extension E2 ajoute le serveur `obs` afin de superviser les machines et les services de l'infrastructure.

Les composants utilisés sont :

* **Prometheus :** collecte et stockage des métriques.
* **Node Exporter :** exposition des métriques système des machines.
* **Grafana :** visualisation des métriques à l'aide de tableaux de bord.

La configuration de Prometheus prévoit une collecte toutes les cinq secondes. Les cibles sont définies à partir de la configuration des nœuds et des exporteurs concernés.

### Accès aux services

Remplacer `IP_OBS` par l'adresse IP de la machine `obs`, définie dans `config/noeuds.yml`.

* **Prometheus :** `http://IP_OBS:9090`
* **Grafana :** `http://IP_OBS:3000`

La disponibilité des métriques dépend du démarrage des machines, de la configuration des cibles et du fonctionnement des exporteurs.

---

## 6. Scénarios de validation V1 à V6

Les scénarios suivants permettent de vérifier le comportement de l'infrastructure. Les résultats observés doivent être consignés dans un compte rendu de tests.

| Test | Procédure | Vérification attendue |
|---|---|---|
| **V1 — Répartition de charge** | Envoyer plusieurs requêtes à l'endpoint `/info` via `lb1`. | Vérifier que les requêtes sont distribuées entre les serveurs applicatifs disponibles. |
| **V2 — Panne applicative** | Arrêter un serveur applicatif pendant l'envoi de requêtes. | Vérifier que le service reste accessible grâce aux serveurs applicatifs disponibles et relever les erreurs éventuelles. |
| **V3 — Montée en charge** | Effectuer un test de charge avec ApacheBench. | Relever le débit, le temps de réponse et le nombre de requêtes échouées. |
| **V4 — Panne de la base primaire** | Arrêter `bdd1` et observer le comportement de l'application et la procédure de reprise prévue. | Vérifier la disponibilité des données et relever les éventuelles interruptions. |
| **V5 — Reconstruction** | Reconstruire l'infrastructure lorsque cette opération est autorisée. | Vérifier que les machines et les services peuvent être recréés et démarrés correctement. |
| **V6 — Panne du répartiteur** | Arrêter `lb1` pendant l'envoi de requêtes. | Vérifier la reprise du service par `lb2` et relever le temps de bascule. |

### Exemple de commande pour V3

Remplacer `IP_LB1` par l'adresse IP de `lb1` définie dans `config/noeuds.yml`.

```bash
ab -n 2000 -c 50 http://IP_LB1/info
```

Les résultats peuvent être comparés en faisant varier le nombre de serveurs applicatifs, tout en tenant compte des ressources disponibles.

### Compte rendu des tests

Pour chaque scénario, consigner :

* la date et les conditions d'exécution ;
* les commandes exécutées ;
* le résultat obtenu ;
* les erreurs ou les requêtes perdues ;
* le temps de reprise, lorsqu'il est mesuré ;
* la conclusion : réussi, échoué ou à reprendre.

---

## 7. Vérifications et dépannage

### État des machines virtuelles

```bash
vagrant status
```

### Vérification des services de supervision

Sur la machine `obs`, vérifier l'état des services concernés lorsqu'ils sont installés :

```bash
systemctl status prometheus
systemctl status grafana-server
systemctl status prometheus-node-exporter
```

### En cas de problème

* Vérifier l'état des machines virtuelles.
* Contrôler les adresses IP définies dans `config/noeuds.yml`.
* Vérifier l'accessibilité des ports utilisés.
* Contrôler les cibles configurées dans Prometheus.
* Consulter les journaux du service concerné.
* Vérifier que les exporteurs sont démarrés et accessibles.

---

## 8. Sécurité et bonnes pratiques

* Ne jamais versionner de mots de passe, de secrets ou de fichiers `.env` personnels.
* Conserver les fichiers d'exemple nécessaires au déploiement.
* Examiner les modifications avant de les intégrer dans la branche `main`.
* N'effectuer les opérations destructives que lorsque cela est autorisé.
* Documenter les résultats réellement observés et ne pas inventer de mesures.
