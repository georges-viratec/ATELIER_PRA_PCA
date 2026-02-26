#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <timestamp>"
  echo "Example: $0 1709123456"
  exit 1
fi

TIMESTAMP=$1

echo "Etape 1: Arret application"
kubectl -n pra scale deployment flask --replicas=0
kubectl -n pra patch cronjob sqlite-backup -p '{"spec":{"suspend":true}}'
kubectl -n pra delete job --all

echo "Etape 2: Suppression PVC pra-data"
kubectl -n pra delete pvc pra-data

echo "Etape 3: Recreation infrastructure"
kubectl apply -f k8s/

echo "Etape 4: Restauration backup $TIMESTAMP"
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-${TIMESTAMP}
  namespace: pra
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: alpine
          command: ["/bin/sh","-c"]
          args:
            - |
              cp /backup/app-${TIMESTAMP}.db /data/app.db
          volumeMounts:
            - name: data
              mountPath: /data
            - name: backup
              mountPath: /backup
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pra-data
        - name: backup
          persistentVolumeClaim:
            claimName: pra-backup
EOF

kubectl -n pra wait --for=condition=complete job/restore-${TIMESTAMP} --timeout=180s

echo "Etape 5: Redemarrage application"
kubectl -n pra scale deployment flask --replicas=1
kubectl -n pra patch cronjob sqlite-backup -p '{"spec":{"suspend":false}}'

echo "Restauration terminee"