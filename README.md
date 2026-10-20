# Plateforme RÉSULTATS-BF 

Infrastructure hautement disponible, résiliente et entièrement décrite en code (Infrastructure as Code) avec **Vagrant** et **VirtualBox**.

* **Contexte :** Projet de groupe - Master 1 Informatique / Virtualisation et Cloud Computing  
* **Établissement :** Institut Supérieur de Informatique et de Management (IBAM), Université Joseph Ki Zerbo  
* **Enseignant :** Dr SOMDA Flavien Hervé  
* **Année universitaire :** 2026-2027  

---

## 1. Vue d'ensemble du projet

La plateforme **RÉSULTATS-BF** permet aux candidats de consulter leurs résultats d'examens par numéro de matricule. L'architecture a été pensée pour répondre à deux impératifs non fonctionnels majeurs :
1. **La résilience :** Le système continue de fonctionner malgré la panne d'un composant (serveur applicatif ou base de données).
2. **La scalabilité :** L'absorption d'un pic de trafic s'effectue horizontalement par simple ajout de serveurs, sans réécriture de la configuration.

### Architecture Cible (Socle Obligatoire + Extensions)
* **Répartition de charge (`lb1`) :** HAProxy configuré dynamiquement avec une sonde de santé (`/sante`).
* **Serveurs applicatifs (`app1` à `appN`) :** Services stateless (Python/Node.js) répartis sur un réseau privé.
* **Base de données (`bdd1` & `bdd2`) :** PostgreSQL avec un nœud primaire en lecture/écriture (`bdd1`) et une réplique en flux (`bdd2`).
* **Réseau privé :** Sous-réseau `192.168.5X.0/24` (où $X = 55 + \text{Numéro de Groupe}$).

---

## 2. Prérequis techniques

* **Outils requis sur la machine hôte :**
  * [VirtualBox](https://www.virtualbox.org/) (version 6.1 ou supérieure)
  * [Vagrant](https://www.vagrantup.com/) (version 2.2 ou supérieure)
* **Configuration matérielle recommandée :** 
  * 8 Go de RAM minimum sur l'hôte (le socle consomme environ 3 Go).
* **Box Vagrant utilisée :** `bento/ubuntu-24.04` (version épinglée `202404.23.0`).

---

## 3. Configuration de l'environnement

1. Cloner le dépôt sur votre poste :
   ```bash
   git clone <URL_DU_DEPOT>
   cd resultat-bf-vagrant