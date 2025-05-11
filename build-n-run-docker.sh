#!/bin/bash
# filepath: /home/william/projet/Clea/build-and-run.sh
set -e

# rendre exécutable les scripts
chmod +x clea-supervisor/runpod_entrypoint.sh
chmod +x clea-db/init/install-postgres.sh
chmod +x start-local-supervisor.sh

# Construire l'image Docker
echo "Construction de l'image Docker Clea..."
docker build -t ghcr.io/willisback/clea-runpod:latest .

# Exécuter le conteneur
echo "Exécution du conteneur..."
docker run -it --gpus all -p 8888:8888 -e NGINX_PORT=8888 ghcr.io/willisback/clea-runpod:latest