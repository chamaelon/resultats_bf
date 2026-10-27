## M1 Informatique/ Virtualisation et Cloud Computing – Septembre 2026 Université Joseph Ki Zerbo IBAM

Enseignant : Dr SOMDA

## MASTER 1 — INFORMATIQUE

Module DevOps et infrastructures reproductibles

PROJET DE GROUPE

## RÉSULTATS-BF

Construire une infrastructure résiliente et scalable, entièrement décrite en code avec Vagrant

| Enseignant | SOMDA Flavien Hervé |
| --- | --- |
| Nature | Projet de groupe — 4 étudiants |
| Durée | 4 semaines |
| Évaluation | Note sur 20 — dossier, démonstration et code |
| Environnement | Vagrant + VirtualBox, sur poste personnel |
| Coût | Aucun — ni compte cloud, ni carte bancaire |

Année universitaire 2026 — 2027


## Sommaire


## 1. Le cas

Chaque année, la publication des résultats d’examens provoque le même incident : le site tombe dans les dix minutes qui suivent l’annonce. Rarement parce que le programme est mal écrit — presque toujours parce que son infrastructure n’a été pensée ni pour absorber un pic de consultations, ni pour survivre à la panne d’une seule machine.

Votre groupe est mandaté pour construire la plateforme RÉSULTATS-BF, qui permet à un candidat de consulter son résultat à partir de son numéro de matricule. Deux exigences non fonctionnelles priment sur tout le reste :

- Résilience — la panne d’une machine ne doit pas interrompre le service.

- Scalabilité — absorber davantage de trafic doit se faire en ajoutant des machines, sans réécrire la configuration.

La totalité de l’infrastructure doit être décrite en code et reconstructible sur n’importe quel poste, sans un seul geste manuel. Une infrastructure qui ne se reconstruit pas n’est pas une infrastructure : c’est un objet fragile que personne n’ose toucher.

À retenir — Ce projet n’est pas un exercice de programmation. L’application fournie est volontairement minuscule. Ce qui est évalué, c’est l’infrastructure autour d’elle, et votre capacité à prouver qu’elle tient.

## 2. Objectifs pédagogiques

À l’issue du projet, chaque membre du groupe doit être capable de :

- traduire deux exigences non fonctionnelles en choix d’architecture concrets, et justifier ces choix ;

- écrire une infrastructure entièrement reproductible, dont le provisionnement est idempotent ;

- identifier les points de défaillance unique d’une architecture et les supprimer un par un ;

- mesurer plutôt qu’affirmer : produire des chiffres de disponibilité et de débit, et les commenter honnêtement ;

- travailler à plusieurs sur un même dépôt, avec une répartition explicite des responsabilités.

## 3. Architecture cible

Le schéma ci-dessous décrit la cible complète, extensions comprises. Le socle obligatoire en est un sous- ensemble (voir le tableau qui suit).


*Figure 1 — Architecture cible de la plateforme RÉSULTATS-BF*

## 3.1. Inventaire des machines virtuelles

| Machine | Rôle | Adresse | RAM | Statut |
| --- | --- | --- | --- | --- |
| bdd1 | Base de données primaire — lecture et écriture | .31 | 768 Mo | Obligatoire |
| bdd2 | Réplique en flux, promouvable | .32 | 768 Mo | Obligatoire |
| app1 … appN | Serveurs applicatifs sans état (N ≥ 2) | .21 … .2N | 512 Mo | Obligatoire |
| lb1 | Répartiteur de charge actif | .11 | 512 Mo | Obligatoire |
| lb2 | Répartiteur passif, IP virtuelle VRRP | .12 | 512 Mo | Extension E1 |
| obs | Supervision — Prometheus et Grafana | .41 | 768 Mo | Extension E2 |

Le socle obligatoire représente cinq machines virtuelles et environ 3 Go de mémoire. Il doit tenir sur un poste de 8 Go. Les extensions se déploient une par une : n’allumez pas tout en même temps pendant le développement.

## 3.2. L’application

Le service applicatif est volontairement minimal. Vous l’écrivez en Python ou en Node, en moins de cent lignes. Il expose trois points d’entrée :

| Point d’entrée | Comportement attendu |
| --- | --- |
| GET /resultat?matricule=… | Renvoie le résultat du candidat au format JSON, lu dans la base. |
| GET /sante | Renvoie 200 si la base répond, 503 sinon. C’est cette sonde que le répartiteur interroge : elle ne doit jamais renvoyer 200 par principe. |
| GET /info | Renvoie le nom d’hôte du serveur qui a répondu. Sert à observer la répartition. |


La base contient une table resultats (matricule, nom, serie, moyenne, admis) peuplée de 50 000 lignes engendrées par generate_series : il faut un volume suffisant pour que les mesures de charge veuillent dire quelque chose.

Contrainte structurante — Le serveur applicatif ne conserve aucun état : ni session en mémoire, ni fichier local, ni compteur. Tout état vit dans la base. C’est précisément ce qui rend l’ajout d’un serveur trivial — et son retrait indolore.


## 4. Exigences obligatoires

Ces huit exigences constituent le socle. Elles sont toutes vérifiées en démonstration.

| N° | Exigence | Vérification |
| --- | --- | --- |
| R1 | Reconstruction intégrale : vagrant destroy -f puis vagrant up reconstruit la plateforme entière, sans une seule commande tapée à la main ensuite. | Exécutée en direct devant l’enseignant. |
| R2 | Idempotence : vagrant provision rejoué deux fois de suite ne modifie rien et n’échoue pas. | Rejeu et comparaison des fichiers de configuration. |
| R3 | Le nombre de serveurs applicatifs est un paramètre. Passer de 2 à 4 se fait en changeant une seule valeur. | NB_APP=4 vagrant up, puis test de répartition. |
| R4 | Sonde de santé : le répartiteur n’envoie du trafic qu’aux serveurs qui répondent sur /sante, et écarte un serveur défaillant en moins de 5 secondes. | Scénario V2. |
| R5 | La base bdd2 est une réplique en flux de bdd1. Une écriture sur bdd1 est visible sur bdd2. | Insertion puis lecture sur la réplique. |
| R6 | Une procédure de bascule de la base est écrite, exécutable et chronométrée. | Scénario V4. |
| R7 | Aucun secret en clair dans le dépôt. Les mots de passe passent par des variables d’environnement, avec un fichier .env.exemple versionné et un .env qui ne l’est pas. | Lecture de l’historique Git. |
| R8 | Tout le trafic interne passe par le réseau privé. Seul le répartiteur expose un port vers l’hôte. | Inspection du Vagrantfile. |

Interdit — Écrire les adresses des serveurs applicatifs en dur dans la configuration du répartiteur. Cette configuration doit être engendrée à partir de la même source de vérité que le Vagrantfile. C’est le cœur de l’exigence R3 : sans cela, « scalable » n’est qu’un mot.

## 5. Extensions — deux au minimum

Au-delà du socle, chaque groupe choisit et réalise au moins deux extensions. Elles se répartissent naturellement entre les membres.

| Code | Extension | Ce qui doit être démontré |
| --- | --- | --- |
| E1 | Répartiteur redondant — lb2, keepalived, adresse IP virtuelle partagée en VRRP. | vagrant halt lb1 : le service reste joignable à la même adresse, en moins de 5 secondes. |
| E2 | Observabilité — Prometheus, node_exporter et Grafana sur la machine obs. | Un tableau de bord où l’on voit le débit monter pendant la charge, et un serveur disparaître pendant la panne. |
| E3 | Cache — Redis devant la base pour les consultations répétées. | Le gain mesuré en requêtes par seconde, et une discussion argumentée de l’invalidation. |
| E4 | Déploiement sans coupure — mise à jour de l’application serveur par serveur. | Une mise à jour complète pendant un test de charge, sans une seule requête en erreur. |


## 6. Scénarios de validation

Ces scénarios sont le cœur de l’évaluation. Chacun doit figurer dans le dossier avec la commande exacte, le résultat brut et votre commentaire. Une affirmation sans mesure ne vaut rien.

| N° | Scénario | Comportement attendu | Mesure à relever |
| --- | --- | --- | --- |
| V1 | Répartition 20 appels successifs à /info | Les N serveurs apparaissent tour à tour. | Écart entre le serveur le plus et le moins sollicité (< 20 %). |
| V2 | Panne d’un serveur applicatif vagrant halt app1 pendant une charge | Le service reste disponible ; plus aucune erreur au-delà de 5 secondes. | Nombre de requêtes perdues et durée de la période dégradée. |
| V3 | Montée en charge ab -n 2000 -c 50, avec N=2 puis N=4 | Le débit augmente lorsque l’on ajoute des serveurs. | Requêtes par seconde dans les deux configurations. |
| V4 | Panne de la base primaire vagrant halt bdd1 | Le service renvoie proprement 503 sur /sante — jamais une page blanche ni une erreur de connexion brute. | Temps total de la procédure de bascule sur bdd2. |
| V5 | Reconstruction vagrant destroy -f puis vagrant up | Plateforme fonctionnelle sans aucune intervention. | Durée totale de la reconstruction. |
| V6 | Panne du répartiteur (E1) vagrant halt lb1 | Le service reste joignable à la même adresse. | Temps de reprise après bascule VRRP. |

Honnêteté des mesures — Vos quatre machines virtuelles se partagent le processeur d’un seul ordinateur. Doubler le nombre de serveurs applicatifs ne doublera donc pas le débit, et il est possible qu’il baisse. Ce n’est pas un échec : c’est un résultat, et le dossier qui l’explique correctement vaut mieux que celui qui affiche une belle courbe inventée.

## 7. Contraintes techniques

## 7.1. Plage d’adresses imposée

Depuis la version 6.1.28, VirtualBox n’autorise par défaut les réseaux privés hôte-seul que dans la plage 192.168.56.0/21, soit de 192.168.56.0 à 192.168.63.255. Toute autre adresse exige de modifier le fichier /etc/vbox/networks.conf sur chaque poste : c’est interdit dans ce projet, car cela rendrait votre dépôt non reproductible.

Chaque groupe reçoit donc un numéro G, de 1 à 8, et travaille sur le sous-réseau 192.168.X.0/24 avec X = 55 + G.

| Groupe | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Sous-réseau |   |   |   | …56.0/24 …57.0/24 …58.0/24 …59.0/24 …60.0/24 …61.0/24 …62.0/24 …63.0/24 |   |   |   |   |

## 7.2. Autres contraintes

- Boîte imposée : bento/ubuntu-24.04, avec une version épinglée, identique pour tous les membres du groupe.


- Mémoire : le socle obligatoire doit tenir dans 3 Go. Si vous dépassez, réduisez la taille des machines virtuelles — la salle ne changera pas.

- Aucune ressource payante, aucun compte cloud, aucune image construite à la main : tout part de la boîte publique et de vos scripts.

- Le provisionnement doit fonctionner derrière une connexion lente. Groupez vos apt-get install ; ne téléchargez pas la même chose quatre fois.


## 8. Livrables

| Code | Livrable | Attendu |
| --- | --- | --- |
| L1 | Dépôt Git | Vagrantfile, scripts/, app/, config/, README.md, .env.exemple. Historique lisible, avec des commits de chaque membre. |
| L2 | Dossier d’architecture 10 à 15 pages | Contexte, architecture et justification des choix, schéma, procédures d’exploitation (bascule, ajout d’un serveur), résultats des scénarios V1 à V6 sous forme de tableaux, limites connues et ce que vous feriez autrement. |
| L3 | Journal de bord 1 à 2 pages | Répartition des rôles, décisions prises et pourquoi, difficultés rencontrées et comment elles ont été levées. |
| L4 | Démonstration 20 minutes | Sur une machine vierge, destruction puis reconstruction en direct, puis exécution de trois scénarios tirés au sort par l’enseignant. |

Le README est un livrable à part entière — Un lecteur qui ne connaît pas votre projet doit pouvoir cloner le dépôt et obtenir une plateforme fonctionnelle en suivant le README, sans vous poser une seule question. C’est le premier test de reproductibilité, et il ne coûte rien.

## 9. Organisation de l’équipe

Quatre rôles, un par membre. Chacun est responsable de son domaine, mais tous doivent savoir démontrer l’ensemble : en soutenance, l’enseignant choisit qui répond.

| Rôle | Périmètre |
| --- | --- |
| Architecte réseau et répartition | Plan d’adressage, Vagrantfile, répartiteur, sonde de santé, extension E1. |
| Ingénieur applicatif | Service HTTP, absence d’état, gestion des erreurs de base, extension E4. |
| Ingénieur données | PostgreSQL, jeu de données, réplication, procédure de bascule, extension E3. |
| Ingénieur essais et observabilité | Scénarios V1 à V6, campagne de mesures, extension E2, rédaction des résultats. |

Rotation obligatoire : chaque membre doit avoir au moins un commit significatif en dehors de son propre domaine. L’historique Git en fait foi.

## 10. Planning et jalons

| Semaine | Travail attendu | Jalon |
| --- | --- | --- |
| S1 — Conception | Schéma d’architecture, plan d’adressage, dépôt initialisé, socle de trois machines virtuelles qui démarre. | J1 — vagrant up fonctionne de bout en bout. |
| S2 — Répartition | N serveurs applicatifs, configuration du répartiteur engendrée, sonde de santé opérationnelle. | J2 — les scénarios V1 et V2 passent. |
| S3 — Données et extensions | Réplication, procédure de bascule, deux extensions réalisées. | J3 — le scénario V4 passe. |


| Semaine | Travail attendu | Jalon |
| --- | --- | --- |
| S4 — Mesures et rédaction | Campagne de mesures V3, rédaction du dossier, répétition de la démonstration. | Rendu et soutenance. |

Conseil de planning — Exécutez vagrant destroy -f puis vagrant up au moins une fois par semaine, sur le poste d’un autre membre. C’est ainsi, et seulement ainsi, que l’on découvre à temps les gestes manuels oubliés — plutôt que la veille du rendu.


## 11. Barème

| Critère | Détail | Points |
| --- | --- | --- |
| Reconstruction intégrale (R1) | La plateforme se reconstruit sans aucun geste manuel, sur un poste vierge. | 4 |
| Scalabilité (R3) | Nombre de serveurs paramétrable, configuration du répartiteur engendrée, aucune adresse en dur. | 3 |
| Résilience (R4, R5, R6) | Sonde de santé effective, réplication fonctionnelle, procédure de bascule exécutable. | 4 |
| Qualité technique (R2, R7, R8) | Idempotence, absence de secrets, cloisonnement réseau, lisibilité des scripts. | 2 |
| Extensions | Deux extensions réalisées et démontrées. | 2 |
| Dossier et mesures | Clarté, justification des choix, mesures présentées et commentées honnêtement. | 3 |
| Démonstration | Maîtrise individuelle, capacité à répondre sur une partie que l’on n’a pas écrite. | 2 |
| Total |   | 20 |

## 11.1. Pénalités

| Constat | Effet |
| --- | --- |
| Adresses des serveurs applicatifs écrites en dur dans la configuration du répartiteur | − 2 points |
| vagrant up échoue sur une machine vierge | Note plafonnée à 8 |
| Mot de passe en clair dans l’historique Git | − 2 points |
| Mesures non reproductibles ou manifestement inventées | − 4 points |
| Membre incapable d’expliquer une partie du travail rendu | Note individuelle ajustée |

## 12. Pièges connus

Ces six erreurs coûtent chaque année plusieurs jours à au moins un groupe. Les connaître à l’avance est un avantage déloyal — profitez-en.

- Un service qui écoute sur 127.0.0.1 n’est joignable par personne d’autre que lui-même. C’est la panne numéro un de ce projet : faites écouter vos services sur 0.0.0.0.

- Un provisionnement en run: "always" qui ajoute une ligne avec >> accumule les doublons à chaque démarrage. Testez l’idempotence en le rejouant deux fois.

- Ne placez jamais le répertoire de données de PostgreSQL dans un dossier synchronisé : les verrous et la durabilité n’y fonctionnent pas.

- L’ordre de démarrage compte : la base doit être déclarée, et prête, avant les serveurs applicatifs. Mieux encore, faites en sorte que l’application supporte une base absente au démarrage et réessaie.


- Un script écrit sous Windows avec des fins de ligne CRLF échoue dans la machine virtuelle. Réglez .gitattributes une fois pour toutes, au début.

- Le répartiteur qui n’interroge pas la sonde /sante continuera d’envoyer du trafic à un serveur mort. Vérifiez la configuration, pas l’intention.


## Annexe A — Squelette du Vagrantfile

Ce squelette illustre la source unique de vérité exigée par R3 : la même table décrit les machines virtuelles et alimente la configuration du répartiteur. Il est incomplet à dessein — c’est un point de départ, pas une solution.

```
\# -*- mode: ruby -*-
require 'yaml'
require 'fileutils'
GROUPE = (ENV['GROUPE'] || 1).to_i # numéro de groupe, 1 à 8
NB_APP = (ENV['NB_APP'] || 2).to_i # nombre de serveurs applicatifs
RESEAU = "192.168.#{55 + GROUPE}"
BOITE = "bento/ubuntu-24.04"
VERSION = "202404.23.0"
# Source unique de vérité : le Vagrantfile ET la configuration du
# répartiteur sont engendrés à partir de cette table.
NOEUDS = []
NOEUDS << { nom: "bdd1", ip: "#{RESEAU}.31", mem: 768, role: "bdd" }
NOEUDS << { nom: "bdd2", ip: "#{RESEAU}.32", mem: 768, role: "replique" }
(1..NB_APP).each do |i|
NOEUDS << { nom: "app#{i}", ip: "#{RESEAU}.#{20 + i}", mem: 512, role: "app" }
end
NOEUDS << { nom: "lb1", ip: "#{RESEAU}.11", mem: 512, role: "lb" }
# Les scripts liront ce fichier dans /vagrant/config/noeuds.yml
FileUtils.mkdir_p("config")
File.write("config/noeuds.yml", NOEUDS.to_yaml)
Vagrant.configure("2") do |config|
config.vm.box = BOITE
config.vm.box_version = VERSION
NOEUDS.each do |n|
config.vm.define n[:nom] do |m|
m.vm.hostname = n[:nom]
m.vm.network "private_network", ip: n[:ip]
m.vm.network "forwarded_port", guest: 80, host: 8080 if n[:role] == "lb"
m.vm.provider "virtualbox" do |vb|
vb.memory = n[:mem]
vb.cpus = 1
end
m.vm.provision "shell", path: "scripts/#{n[:role]}.sh"
end
end
end
```

Ajouter deux serveurs applicatifs se résume alors à NB_APP=4 vagrant up — et la configuration du répartiteur doit suivre toute seule, puisqu’elle est engendrée depuis config/noeuds.yml. Si elle ne suit pas, R3 n’est pas satisfaite.


## Annexe B — Grille d’évaluation

Groupe : ……………………………… Membres : ……………………………………………………………………………

| Critère | Barème Obtenu |   | Observations |
| --- | --- | --- | --- |
| Reconstruction intégrale (R1) | 4 |   |   |
| Scalabilité (R3) | 3 |   |   |
| Résilience (R4, R5, R6) | 4 |   |   |
| Qualité technique (R2, R7, R8) | 2 |   |   |
| Extensions | 2 |   |   |
| Dossier et mesures | 3 |   |   |
| Démonstration | 2 |   |   |
| Pénalités éventuelles | — |   |   |
| TOTAL | 20 |   |   |

Scénarios tirés au sort en démonstration : …………… …………… ……………

Appréciation générale :
