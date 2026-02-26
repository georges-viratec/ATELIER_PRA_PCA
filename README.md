ATELIER PRA/PCA
--

## Exercice 1
Les composants critiques sont les deux PVC.
PVC pra-data : Contient la base SQLite en production (/data/app.db). Sa perte entraîne la perte de toutes les données actuelles mais récupérables depuis les backups.
PVC pra-backup : Contient l'historique des sauvegardes (/backup/app-*.db). Sa perte signifie la perte de tous les points de restauration.
Perte simultanée des deux PVC : Aucune restaurantion possible dû à la perte des backups.
Les autres composants (pod, deployment, service, cronjob, image Docker) sont reconstructibles et ne contiennent pas de données persistantes. Leur perte n'entraîne qu'une indisponibilité temporaire, pas de perte de données.

## Exercice 2
Nous n'avons pas perdu les données car le CronJob backup effectue une copie de la base SQLite toutes les minutes depuis le PVC pra-data vers le PVC pra-backup.
Lors de la suppression du PVC pra-data nous avons perdu la base en production mais les sauvegardes dans le PVC pra-backup sont restées intactes. La procédure de restauration a simplement consisté à :

Recréer un PVC pra-data vide
Lancer le job de restore qui copie le dernier backup depuis pra-backup vers pra-data
Redémarrer l'application

C'est le principe même du PRA : avoir des sauvegardes sur un support différent du support de production permet de restaurer après un sinistre.


## Exercice 3

Recovery Point Objective -> 1 minute max
Recovery Time Objective -> 3 à 5 minutes

## Exercice 4

Cette solution présente des limitations critiques :Absence de réplication géographique : 
Les deux PVC sont sur le même cluster. Un sinistre datacenter détruit tout.
Backup et production non isolés : Les deux PVC partagent le même disque physique. Une panne disque détruit simultanément les données et les backups.
Pas de monitoring : Aucune surveillance de l'état des backups, de leur validité ou de leur âge.
Restauration manuelle : Pas de failover automatique, intervention humaine obligatoire.
Pas de tests de restauration : Aucune garantie que les backups sont valides.
Base SQLite inadaptée : Non conçue pour la production distribuée.
Infrastructure fragile : Cluster mono-master, stockage local non répliqué.

## Exercice 5

Architecture recommandée :
* Infrastructure : Cluster Kubernetes managé multi-zones (GKE/EKS/AKS) avec nodes répartis et master haute disponibilité.
* Stockage : Disques cloud répliqués entre zones avec snapshots automatiques. Backups exportés vers object storage dans une région différente.
* Base de données : Remplacer SQLite par PostgreSQL/MySQL managé avec réplication automatique et point-in-time recovery.
* Application : Plusieurs replicas
* Monitoring : Prometheus/Grafana avec alerting sur échec backup et dérive RPO. Tests de restauration automatisés.
* Disaster Recovery : Cluster secondaire dans une autre région avec réplication asynchrone et procédure de bascule.
* Sécurité : Chiffrement au repos et en transit, secrets managés, network policies.