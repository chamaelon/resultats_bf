# RÉSULTATS-BF — Infrastructure résiliente et scalable avec Vagrant

Projet de groupe du module **DevOps et infrastructures reproductibles** — Master 1 Informatique, IBAM (Institut Burkinabè des Arts et Métiers), Université Joseph KI-ZERBO.
Enseignant : Dr SOMDA Flavien Hervé — Année universitaire 2026-2027.

**Dépôt :** https://github.com/chamaelon/resultats_bf
**Équipe :** 17 — **Numéro réseau attribué (G) :** 7 — **Réseau privé :** `192.168.62.0/24`

---

## 1. Présentation

La plateforme **RÉSULTATS-BF** permet à un candidat de consulter son résultat d'examen à partir de son numéro de matricule. L'infrastructure répond à deux exigences non fonctionnelles :

- **Résilience** : la panne d'une machine n'interrompt pas le service.
- **Scalabilité** : on absorbe plus de trafic en ajoutant des serveurs, sans réécrire la configuration.

Toute l'infrastructure est décrite en code (Vagrant + scripts shell) et se reconstruit sur n'importe quel poste avec une seule commande.

---

## 2. Architecture

```
                 Poste hôte  ──  localhost:8080 ──►  lb1:80
                      │
                      ▼   IP virtuelle VRRP 192.168.62.5
          ┌────────────────────────┐
          │  lb1 (actif)  .11      │   HAProxy + keepalived
          │  lb2 (secours) .12     │
          └───────────┬────────────┘
                      │  HTTP, sonde /sante
          ┌───────────┴────────────┐
          │  app1 .21   app2 .22   │   API Node.js sans état
          │  ...  appN .2N         │
          └─────┬────────────┬─────┘
                │            │
        cache .51 (Redis)    │  SQL 5432
                      ┌──────┴──────────────┐
                      │ bdd1 .31 (primaire) │──► bdd2 .32 (réplique en flux)
                      └─────────────────────┘
          obs .41 : Prometheus + Grafana (collecte des métriques)
```

| Machine | Rôle | Adresse | RAM | Statut |
|---|---|---|---|---|
| `bdd1` | PostgreSQL primaire (lecture et écriture) | 192.168.62.31 | 768 Mo | Socle |
| `bdd2` | Réplique en flux, promouvable | 192.168.62.32 | 768 Mo | Socle |
| `app1` … `appN` | API Node.js sans état (N = `NB_APP`, 2 par défaut) | 192.168.62.21 … .2N | 512 Mo | Socle |
| `lb1` | Répartiteur HAProxy actif, VRRP MASTER | 192.168.62.11 | 512 Mo | Socle |
| `lb2` | Répartiteur de secours, VRRP BACKUP | 192.168.62.12 | 512 Mo | Extension E1 |
| `obs` | Supervision : Prometheus et Grafana | 192.168.62.41 | 768 Mo | Extension E2 |
| `cache` | Cache Redis des consultations | 192.168.62.51 | 512 Mo | Extension E3 |

**Source unique de vérité :** le `Vagrantfile` décrit les machines et écrit `config/noeuds.yml`. La configuration de HAProxy est **engendrée** à partir de ce fichier : aucune adresse de serveur applicatif n'est écrite en dur.

---

## 3. Prérequis

- [VirtualBox](https://www.virtualbox.org/) 7.x
- [Vagrant](https://www.vagrantup.com/) 2.4 ou plus
- Git
- Un poste avec **8 Go de RAM** : les 8 machines utilisent environ 4,8 Go. Fermez les applications lourdes avant de lancer.
- Une connexion Internet pour le premier lancement : téléchargement de la boîte `bento/ubuntu-24.04` (version épinglée `202404.26.0`) et des paquets.

---

## 4. Démarrage rapide

### 4.1. Cloner le dépôt

```bash
git clone https://github.com/chamaelon/resultats_bf.git
cd resultats_bf
```

### 4.2. Créer les fichiers de configuration

Les mots de passe ne sont jamais versionnés (exigence R7). Le dépôt contient deux modèles, `.env.exemple`, à copier en `.env` :

Linux / macOS :

```bash
cp .env.exemple .env
cp app/api/.env.exemple app/api/.env
```

Windows (PowerShell) :

```powershell
copy .env.exemple .env
copy app\api\.env.exemple app\api\.env
```

Ouvrez ensuite les deux fichiers `.env` et vérifiez les valeurs :

| Fichier | Variable | Rôle |
|---|---|---|
| `.env` | `GROUPE=7` | Numéro **réseau** G attribué (7), et non le numéro d'équipe (17) : réseau `192.168.(55 + G).0/24`. VirtualBox n'accepte que G de 1 à 8 |
| `.env` | `NB_APP=2` | Nombre de serveurs applicatifs |
| `app/api/.env` | `PORT` | Port d'écoute de l'API (80) |
| `app/api/.env` | `PG_USER`, `PG_PASSWORD`, `PG_PORT`, `PG_DB` | Accès PostgreSQL — **`PG_PASSWORD` est obligatoire** |
| `app/api/.env` | `REDIS_PORT`, `REDIS_PASSWORD`, `CACHE_TTL`, `CACHE_PREFIX` | Cache Redis |
| `app/api/.env` | `VRRP_AUTH_PASS` | Mot de passe VRRP de keepalived (**8 caractères maximum**) |

> Les deux fichiers `.env` sont ignorés par Git. Ne commitez jamais de vrai mot de passe.

### 4.3. Lancer l'infrastructure

```bash
vagrant up
```

Le premier lancement prend de 30 à 60 minutes. Les machines sont créées dans cet ordre : `bdd1`, `bdd2`, `cache`, `app1`, `app2`, `lb1`, `lb2`, `obs`. Les bases sont prêtes avant les serveurs applicatifs.

Vérifiez l'état des machines :

```bash
vagrant status
```

Toutes doivent être `running`.

### 4.4. Vérifier que le service répond

Sous Windows, utilisez `curl.exe` et non `curl`.

```bash
curl http://localhost:8080/info        # nom du serveur qui répond : app1 ou app2, en alternance
curl http://localhost:8080/sante       # 200 si la base répond, 503 sinon
curl http://192.168.62.5/info          # même service, via l'IP virtuelle VRRP
```

---

## 5. Accès aux services

| Service | Adresse |
|---|---|
| API depuis l'hôte (redirection de port vers `lb1`) | `http://localhost:8080` |
| API via l'IP virtuelle haute disponibilité | `http://192.168.62.5` |
| Statistiques HAProxy de `lb1` / `lb2` | `http://192.168.62.11:8404/stats` / `http://192.168.62.12:8404/stats` |
| Prometheus | `http://192.168.62.41:9090` |
| Grafana | `http://192.168.62.41:3000` |

Points d'entrée de l'API :

| Point d'entrée | Comportement |
|---|---|
| `GET /resultat?matricule=…` | Résultat du candidat au format JSON, lu dans la base (via le cache Redis) |
| `GET /sante` | 200 si la base répond, 503 sinon. C'est la sonde interrogée par HAProxy |
| `GET /info` | Nom d'hôte du serveur qui a répondu, pour observer la répartition |

---

## 6. Commandes d'exploitation

### 6.1. Ajouter des serveurs applicatifs (exigence R3)

Une seule valeur à changer : `NB_APP`.

Linux / macOS :

```bash
NB_APP=4 vagrant up
NB_APP=4 vagrant provision lb1 lb2
```

Windows (PowerShell) :

```powershell
$env:NB_APP="4"; vagrant up
vagrant provision lb1 lb2
```

`vagrant up` crée `app3` et `app4`. `vagrant provision lb1 lb2` régénère la configuration HAProxy depuis `config/noeuds.yml` : les nouveaux serveurs reçoivent du trafic dès que leur sonde `/sante` répond. Pour rendre le changement permanent, modifiez `NB_APP` dans `.env`.

### 6.2. Bascule de la base de données (exigence R6)

Si `bdd1` tombe, `/sante` renvoie 503 et HAProxy retire les serveurs applicatifs. La bascule vers `bdd2` est **manuelle**, pour éviter deux primaires simultanés (« split-brain ») en cas de simple coupure réseau.

1. Promouvoir la réplique :

   ```bash
   vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"
   ```

2. Sur chaque serveur applicatif (`app1`, `app2`, …), pointer vers `bdd2` et redémarrer l'API :

   ```bash
   vagrant ssh app1
   sudo sed -i 's/192.168.62.31/192.168.62.32/g' /etc/api-app.env
   echo 192.168.62.32 | sudo tee /etc/api-app.primaire
   sudo systemctl restart api-app
   ```

   La ligne `tee` mémorise le nouveau primaire : un futur `vagrant provision` ne repointera pas l'API vers `bdd1`.

3. Vérifier : `curl http://localhost:8080/sante` doit renvoyer 200.

Le script `scripts/validation_scenario_v4` exécute et chronomètre cette procédure. Pour revenir à l'état initial (`bdd1` primaire), reconstruisez la plateforme (section 6.3).

### 6.3. Reconstruction complète (exigence R1)

> ⚠️ Cette commande **supprime toutes les machines** et leurs données.

```bash
vagrant destroy -f
vagrant up
```

### 6.4. Autres commandes utiles

| Commande | Effet |
|---|---|
| `vagrant halt app1` | Éteint une machine (simulation de panne) |
| `vagrant up app1` | La redémarre |
| `vagrant provision` | Rejoue les scripts ; idempotent (exigence R2), rien ne change au second passage |
| `vagrant ssh lb1` | Se connecte à une machine |
| `vagrant status` | État de toutes les machines |

---

## 7. Scénarios de validation (V1 à V6)

Chaque scénario a un script prêt dans `scripts/`, en version PowerShell (`.ps1`) et Bash (`.sh`). Lancez-les depuis la racine du dépôt :

```powershell
powershell -ExecutionPolicy Bypass -File scripts\validation_scenario_v1.ps1
```

```bash
bash scripts/validation_scenario_v1.sh
```

Chaque script produit un rapport dans `mesures/` : commande exacte, résultat brut, mesures, verdict. La section « Commentaire » est à compléter par l'équipe.

| Scénario | Ce qui est testé | Attendu | Mesure relevée |
|---|---|---|---|
| **V1** Répartition | 20 appels à `/info` | Les N serveurs apparaissent tour à tour | Écart entre le plus et le moins sollicité (< 20 %) |
| **V2** Panne d'une app | `vagrant halt app1` pendant une charge | Plus aucune erreur au-delà de 5 s | Requêtes perdues, durée de la période dégradée |
| **V3** Montée en charge | `ab -n 2000 -c 50` avec N = 2 puis N = 4 | Le débit augmente avec N | Requêtes par seconde dans les deux cas |
| **V4** Panne de la base | `vagrant halt bdd1`, puis bascule | `/sante` renvoie proprement 503, jamais d'erreur brute | Durée de la procédure de bascule |
| **V5** Reconstruction | `vagrant destroy -f` puis `vagrant up` | Plateforme fonctionnelle sans intervention | Durée totale |
| **V6** Panne du répartiteur (E1) | `vagrant halt lb1` | Service joignable à la même adresse `192.168.62.5` | Temps de reprise après bascule VRRP |

Ordre conseillé : V1, V2, V6, V3, puis V4 et V5. **V4** laisse `bdd2` en primaire, **V5** détruit et reconstruit tout.

Pendant **V3**, libérez de la mémoire si nécessaire avec `vagrant halt obs`.

---

## 8. Sécurité et qualité

| Exigence | Mise en œuvre |
|---|---|
| **R2** Idempotence | Les scripts vérifient l'état avant d'agir : HAProxy n'est rechargé que si sa configuration a changé |
| **R7** Aucun secret dans le dépôt | Mots de passe dans les `.env` (ignorés par Git) ; seuls les `.env.exemple` sont versionnés |
| **R8** Cloisonnement réseau | Tout le trafic interne passe par `192.168.62.0/24` ; seul `lb1` expose un port vers l'hôte (8080) |

---

## 9. Structure du dépôt

```
resultats_bf/
├── Vagrantfile            # description des machines (source unique de vérité)
├── .env.exemple           # modèle : GROUPE, NB_APP
├── config/
│   ├── noeuds.yml         # engendré par le Vagrantfile, lu par les scripts
│   └── vip.env            # adresse IP virtuelle VRRP
├── scripts/               # provisionnement des machines + scénarios de validation
├── app/
│   ├── api/               # API Node.js (TypeScript) + .env.exemple
│   └── database/          # schéma SQL et jeu de données (50 000 lignes)
└── mesures/               # rapports générés par les scénarios V1 à V6
```

---

## 10. Dépannage

| Problème | Solution |
|---|---|
| `PG_PASSWORD absent` pendant `vagrant up` | Créez `app/api/.env` (section 4.2), puis `vagrant provision bdd1` et `vagrant up` |
| Port 8080 déjà utilisé | Une autre VM tourne encore : `vagrant global-status`, puis `vagrant halt <id>` |
| Le poste rame, une VM ne démarre pas | Mémoire insuffisante : fermez des applications ou éteignez `obs` (`vagrant halt obs`) |
| `bad interpreter` ou `$'\r'` dans un script | Fins de ligne Windows : le `.gitattributes` les corrige, reclonez le dépôt |
| Avertissement « guest additions do not match » | Sans conséquence, ignorez-le |
| `/sante` renvoie 503 | La base ne répond pas : vérifiez `vagrant status bdd1` ou appliquez la bascule (section 6.2) |
