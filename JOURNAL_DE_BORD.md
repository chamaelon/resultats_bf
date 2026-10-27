# Journal de bord — RÉSULTATS-BF

**Groupe :** 7  
**Module :** DevOps et infrastructures reproductibles — Master 1 Informatique  
**Période documentée :** campagne de consolidation du 27 octobre 2026  
**Équipe :** à compléter avec les noms officiels des quatre membres

> Ce journal synthétise la campagne technique documentée dans le dépôt ; il ne
> prétend pas reconstituer les quatre semaines de travail du groupe. Les rôles,
> noms, dates de réunions et décisions collectives doivent être complétés par
> les membres avant remise.

## Répartition des responsabilités

| Membre | Rôle retenu par le groupe | Contributions et commits à préciser |
|---|---|---|
| `[Nom, prénom]` | Architecture réseau et répartiteurs | Plan d’adressage, Vagrantfile, HAProxy, extension E1 |
| `[Nom, prénom]` | Application | API, routes, tests, service systemd |
| `[Nom, prénom]` | Données | Schéma, dataset, réplication et procédure de bascule |
| `[Nom, prénom]` | Essais et observabilité | Scénarios, mesures, supervision et rédaction |

**À compléter par l’équipe :** les contributions réellement faites par chaque
membre, les commits significatifs hors de son domaine et les éventuelles
rotations de responsabilité.

## Étapes et décisions techniques consignées

1. **Profil réseau retenu pour la campagne.** Le dépôt a été aligné sur le groupe 7,
   `192.168.62.0/24`, avec `NB_APP=2` pour le socle. Le Vagrantfile devient la
   source de génération des nœuds et de la liste de backends HAProxy.
2. **Mise en conformité des données et de l’API.** La table métier a été
   ramenée à `resultats(matricule, nom, serie, moyenne, admis)`. Un jeu de
   50 000 lignes reproductibles est généré en SQL et l’API expose les routes
   `/resultat`, `/sante` et `/info`.
3. **Déploiement du socle.** PostgreSQL primaire/réplica, deux applications
   et `lb1` ont été provisionnés. La réplication de 50 000 lignes a été
   confirmée.
4. **Validation du répartiteur.** V1 a produit 20 réponses HTTP 200, avec
   10 requêtes vers chaque application. Pour V2, la campagne a conservé à la
   fois un essai à deux travailleurs réussi et un essai de stress à dix
   travailleurs en échec, afin de ne pas confondre les niveaux de charge.
5. **Mesure de charge et bascule DB.** V3 n’a pas pu utiliser Apache Bench
   sur le poste ; son générateur de secours a fourni des chiffres
   indicatifs. V4 a promu `bdd2`. Le premier contrôle automatisé de
   `/resultat` utilisait un matricule lu sur la base arrêtée ; le script a
   été corrigé et un contrôle HTTP manuel sur `bdd2` promue a renvoyé 200.
6. **Bascule des répartiteurs.** V6 a confirmé le déplacement de la VIP vers
   `lb2` en 1,56 s, sous le seuil de 5 s.
7. **Reconstruction.** V5 a détruit les VM puis la reconstruction a dépassé
   le temps disponible pour la campagne. Une reprise et un provisionnement
   manuel d’app2 ont été nécessaires. Le socle a ensuite répondu HTTP 200 et
   la réplication était active ; l’exigence de reconstruction autonome
   demeure non validée.

## Difficultés rencontrées et enseignements

- Les VM et leurs scripts d’installation prennent un temps notable sur un
  poste où elles partagent un processeur. Il faut réserver une plage de temps
  suffisante pour une destruction/reconstruction et lancer V5 en dernier.
- Un rapport de scénario doit distinguer le début de l’action, la durée de la
  commande Vagrant et l’instant du retour du service. L’essai V2 a conduit à
  corriger l’origine temporelle et le calcul des intervalles.
- Un test de charge de secours ne remplace pas l’outil spécifié par le sujet.
  Les résultats V3 doivent rester explicitement indicatifs tant qu’Apache
  Bench n’a pas été utilisé.
- Une vérification post-bascule doit consulter le nœud promu, et pas l’ancien
  primaire qui est arrêté.
- Une plateforme accessible après réparation manuelle ne constitue pas une
  preuve de reconstruction sans intervention. Le compte rendu V5 conserve
  cette distinction.

## État de fin de campagne et actions de l’équipe

Au dernier contrôle, le socle obligatoire est actif : `bdd1`, `bdd2`, `app1`,
`app2` et `lb1`. L’API répond sur `/sante` et sur le matricule de contrôle ;
les bases contiennent 50 000 lignes et `bdd2` est en réplication. V1 et V6
sont réussis, V2 est réussi à charge modérée, V3 reste à refaire avec `ab`,
V4 doit être rejoué avec son script corrigé, V5 doit être refait sans
intervention manuelle et E2 doit être démontrée avant de la déclarer validée.

**Décisions/réunions réelles à ajouter par le groupe :**

- Date et participants de la réunion de choix de l’architecture : `[à compléter]`
- Répartition réelle des tâches et changements de rôle : `[à compléter]`
- Difficultés de coordination et solutions retenues : `[à compléter]`
- Date de la répétition de soutenance et actions décidées : `[à compléter]`
