.PHONY: help setup build deploy test-status test-pca test-pra list-backups restore clean destroy

# Variables
IMAGE_TAG ?= 1.1
CLUSTER_NAME = pra
NAMESPACE = pra

help: ## Affiche l'aide
	@echo "Commandes disponibles :"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Installe l'environnement (K3d, Packer, Ansible)
	@echo "=== Installation K3d ==="
	curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
	@echo ""
	@echo "=== Creation du cluster K3d ==="
	k3d cluster create $(CLUSTER_NAME) --servers 1 --agents 2 || true
	kubectl get nodes
	@echo ""
	@echo "=== Installation Packer ==="
	PACKER_VERSION=1.11.2; \
	curl -fsSL -o /tmp/packer.zip "https://releases.hashicorp.com/packer/$${PACKER_VERSION}/packer_$${PACKER_VERSION}_linux_amd64.zip"; \
	sudo unzip -o /tmp/packer.zip -d /usr/local/bin; \
	rm -f /tmp/packer.zip
	@echo ""
	@echo "=== Installation Ansible ==="
	python3 -m pip install --user ansible kubernetes PyYAML jinja2
	export PATH="$$HOME/.local/bin:$$PATH"; \
	ansible-galaxy collection install kubernetes.core

build: ## Build l'image Docker avec Packer
	@echo "=== Build de l'image $(IMAGE_TAG) ==="
	packer init .
	packer build -var "image_tag=$(IMAGE_TAG)" .
	docker images | grep pra/flask-sqlite

deploy: ## Deploy l'infrastructure sur Kubernetes
	@echo "=== Import de l'image dans K3d ==="
	k3d image import pra/flask-sqlite:$(IMAGE_TAG) -c $(CLUSTER_NAME)
	@echo ""
	@echo "=== Deploiement sur Kubernetes ==="
	kubectl apply -f k8s/
	kubectl -n $(NAMESPACE) rollout status deployment/flask --timeout=180s
	@echo ""
	@echo "=== Forward du port 8080 ==="
	pkill -f "port-forward.*flask" || true
	sleep 2
	kubectl -n $(NAMESPACE) port-forward svc/flask 8080:80 >/tmp/web.log 2>&1 &
	@echo ""
	@echo "=== Application deployee ==="
	@echo "Testez avec : curl http://localhost:8080/"

all: setup build deploy ## Installation complete (setup + build + deploy)

test-routes: ## Teste toutes les routes de l'application
	@echo "=== Test des routes ==="
	@echo ""
	@echo "1. Route /"
	curl -s http://localhost:8080/ | jq '.' || curl -s http://localhost:8080/
	@echo ""
	@echo "2. Route /health"
	curl -s http://localhost:8080/health | jq '.' || curl -s http://localhost:8080/health
	@echo ""
	@echo "3. Route /add"
	curl -s "http://localhost:8080/add?message=Test_$$(date +%s)" | jq '.' || curl -s "http://localhost:8080/add?message=Test"
	@echo ""
	@echo "4. Route /count"
	curl -s http://localhost:8080/count | jq '.' || curl -s http://localhost:8080/count
	@echo ""
	@echo "5. Route /consultation"
	curl -s http://localhost:8080/consultation | jq '.' || curl -s http://localhost:8080/consultation
	@echo ""
	@echo "6. Route /status (Atelier 1)"
	curl -s http://localhost:8080/status | jq '.' || curl -s http://localhost:8080/status

test-status: ## Teste la route /status (Atelier 1)
	@echo "=== Test de la route /status ==="
	curl -s http://localhost:8080/status | jq '.'

add-data: ## Ajoute 5 messages de test
	@echo "=== Ajout de messages de test ==="
	@for i in 1 2 3 4 5; do \
		curl -s "http://localhost:8080/add?message=Message_$$i" | jq '.message'; \
		sleep 1; \
	done
	@echo ""
	@curl -s http://localhost:8080/count | jq '.'

test-pca: ## Teste le scenario PCA (crash du pod)
	@echo "=== Scenario 1 : PCA - Crash du pod ==="
	@echo ""
	@echo "Etat avant :"
	@kubectl -n $(NAMESPACE) get pods
	@POD=$$(kubectl -n $(NAMESPACE) get pods -l app=flask -o jsonpath='{.items[0].metadata.name}'); \
	echo ""; \
	echo "Suppression du pod : $$POD"; \
	kubectl -n $(NAMESPACE) delete pod $$POD
	@echo ""
	@echo "Attente de la recreation..."
	@sleep 5
	@kubectl -n $(NAMESPACE) get pods
	@echo ""
	@echo "Redemarrage du port-forward..."
	@pkill -f "port-forward.*flask" || true
	@sleep 2
	@kubectl -n $(NAMESPACE) port-forward svc/flask 8080:80 >/tmp/web.log 2>&1 &
	@sleep 2
	@echo ""
	@echo "Verification des donnees :"
	@curl -s http://localhost:8080/count | jq '.'
	@echo ""
	@echo "=== PCA OK : Aucune perte de donnees ==="

test-pra: ## Teste le scenario PRA (perte du PVC)
	@echo "=== Scenario 2 : PRA - Perte du PVC pra-data ==="
	@echo ""
	@echo "Phase 1 : Simulation du sinistre"
	kubectl -n $(NAMESPACE) scale deployment flask --replicas=0
	kubectl -n $(NAMESPACE) patch cronjob sqlite-backup -p '{"spec":{"suspend":true}}'
	kubectl -n $(NAMESPACE) delete job --all
	kubectl -n $(NAMESPACE) delete pvc pra-data
	@echo ""
	@echo "Phase 2 : Recreation infrastructure"
	kubectl apply -f k8s/
	@sleep 5
	@pkill -f "port-forward.*flask" || true
	@sleep 2
	@kubectl -n $(NAMESPACE) port-forward svc/flask 8080:80 >/tmp/web.log 2>&1 &
	@sleep 2
	@echo ""
	@echo "Verification perte de donnees :"
	@curl -s http://localhost:8080/count | jq '.'
	@echo ""
	@echo "Phase 3 : Restauration"
	kubectl apply -f pra/50-job-restore.yaml
	@sleep 5
	@echo ""
	@echo "Verification restauration :"
	@curl -s http://localhost:8080/count | jq '.'
	@echo ""
	@echo "Phase 4 : Relance des backups"
	kubectl -n $(NAMESPACE) patch cronjob sqlite-backup -p '{"spec":{"suspend":false}}'
	@echo ""
	@echo "=== PRA OK : Donnees restaurees ==="

list-backups: ## Liste les backups disponibles
	@echo "=== Backups disponibles ==="
	@kubectl -n $(NAMESPACE) run list-backups --rm -it --image=alpine \
		--overrides='{"spec":{"containers":[{"name":"list","image":"alpine","command":["sh","-c","apk add --no-cache coreutils >/dev/null 2>&1 && ls -lht /backup/*.db"],"stdin":true,"tty":true,"volumeMounts":[{"name":"backup","mountPath":"/backup"}]}],"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"pra-backup"}}]}}'

restore: ## Restaure un backup specifique (make restore TIMESTAMP=1234567890)
	@if [ -z "$(TIMESTAMP)" ]; then \
		echo "Erreur : TIMESTAMP requis"; \
		echo "Usage : make restore TIMESTAMP=1234567890"; \
		exit 1; \
	fi
	@echo "=== Restauration du backup $(TIMESTAMP) ==="
	kubectl -n $(NAMESPACE) scale deployment flask --replicas=0
	kubectl -n $(NAMESPACE) patch cronjob sqlite-backup -p '{"spec":{"suspend":true}}'
	kubectl -n $(NAMESPACE) delete job --all
	kubectl -n $(NAMESPACE) delete pvc pra-data
	kubectl apply -f k8s/
	@sleep 5
	@echo "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: restore-$(TIMESTAMP)\n  namespace: $(NAMESPACE)\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n      containers:\n        - name: restore\n          image: alpine\n          command: [\"/bin/sh\",\"-c\"]\n          args:\n            - |\n              cp /backup/app-$(TIMESTAMP).db /data/app.db\n          volumeMounts:\n            - name: data\n              mountPath: /data\n            - name: backup\n              mountPath: /backup\n      volumes:\n        - name: data\n          persistentVolumeClaim:\n            claimName: pra-data\n        - name: backup\n          persistentVolumeClaim:\n            claimName: pra-backup" | kubectl apply -f -
	@sleep 5
	kubectl -n $(NAMESPACE) scale deployment flask --replicas=1
	kubectl -n $(NAMESPACE) patch cronjob sqlite-backup -p '{"spec":{"suspend":false}}'
	@pkill -f "port-forward.*flask" || true
	@sleep 2
	@kubectl -n $(NAMESPACE) port-forward svc/flask 8080:80 >/tmp/web.log 2>&1 &
	@echo "=== Restauration terminee ==="

status: ## Affiche l'etat du cluster
	@echo "=== Etat du cluster ==="
	@echo ""
	@echo "Cluster K3d :"
	@k3d cluster list || echo "K3d non installe"
	@echo ""
	@echo "Nodes Kubernetes :"
	@kubectl get nodes || echo "Cluster non accessible"
	@echo ""
	@echo "Namespace $(NAMESPACE) :"
	@kubectl -n $(NAMESPACE) get all 2>/dev/null || echo "Namespace non cree"
	@echo ""
	@echo "PVC :"
	@kubectl -n $(NAMESPACE) get pvc 2>/dev/null || echo "Aucun PVC"
	@echo ""
	@echo "Images Docker :"
	@docker images | grep pra/flask-sqlite || echo "Aucune image"

logs: ## Affiche les logs du pod Flask
	@kubectl -n $(NAMESPACE) logs -l app=flask --tail=50 -f

clean: ## Nettoie le deploiement (garde le cluster)
	@echo "=== Nettoyage du deploiement ==="
	kubectl delete namespace $(NAMESPACE) --ignore-not-found=true
	@pkill -f "port-forward.*flask" || true
	@echo "=== Nettoyage termine ==="

destroy: ## Detruit tout (cluster inclus)
	@echo "=== Destruction complete ==="
	k3d cluster delete $(CLUSTER_NAME) || true
	@pkill -f "port-forward.*flask" || true
	docker rmi pra/flask-sqlite:$(IMAGE_TAG) || true
	@echo "=== Destruction terminee ==="