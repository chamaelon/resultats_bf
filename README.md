# Projet RÉSULTATS-BF - Infrastructure DevOps

## 📌 Présentation du Projet
Ce projet a été réalisé dans le cadre du module **DevOps et infrastructures reproductibles** (M1 Informatique) encadré par le Dr SOMDA Flavien Hervé.
Il vise à déployer une infrastructure hautement disponible, résiliente et automatisée pour la consultation des résultats de concours de la fonction publique au Burkina Faso.

L'infrastructure est entièrement pilotée par le code (Infrastructure as Code) via **Vagrant** et **VirtualBox**, et satisfait les exigences de scalabilité, de reproductibilité et de sécurité.

**Groupe :** 7
**Réseau privé du groupe :** `192.168.62.0/24`

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

---

## 🚀 Prérequis

Pour lancer l'environnement, vous devez installer les outils suivants sur votre machine hôte :
- **VirtualBox** (version >= 7.x recommandée)
- **Vagrant** (version >= 2.4.x)
- *Git* (pour cloner le dépôt)

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
