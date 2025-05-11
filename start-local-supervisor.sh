#!/bin/bash
set -e

# Couleurs pour la lisibilité
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Variables d'environnement
export SUPERVISOR_USER=$(id -u -n)
export DB_USER=postgres
export DB_PASSWORD=password
export DB_NAME=vectordb
export DB_HOST=localhost
export DB_PORT=5432
export API_HOST=localhost
export API_PORT=8080
export WEBUI_HOST=localhost
export WEBUI_PORT=3000
export NGINX_HOST=localhost
export NGINX_PORT=8888
export ALLOW_ALL_ORIGINS=true
export FRONTEND_URLS=http://${NGINX_HOST}:${NGINX_PORT}

# Répertoires de base
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
export APP_ROOT="$SCRIPT_DIR"
export API_DIR="$APP_ROOT/clea-api"
export WEBUI_DIR="$APP_ROOT/clea-webui"
export NGINX_DIR="$APP_ROOT/clea-nginx"
export LOGS_DIR="$APP_ROOT/logs"
export NGINX_CONF_TEMPLATE="$NGINX_DIR/conf/nginx.conf.template"
export NGINX_CONF="$NGINX_DIR/conf/nginx.conf"
export SUPERVISOR_CONF_TEMPLATE="$APP_ROOT/clea-supervisor/supervisord.conf.template"
export SUPERVISOR_CONF="$APP_ROOT/clea-supervisord.conf"

cd "$APP_ROOT"
mkdir -p logs


# Définir l'utilisateur de supervision en fonction des droits actuels
if [ "$(id -u)" -eq 0 ]; then
  # Si exécuté avec sudo/root
  export SUPERVISOR_USER=root
else
  # Sinon utiliser l'utilisateur courant
  export SUPERVISOR_USER=$(id -u -n)
fi

#############################################################
###### BUILD PRODUCTION PROJECT #############################
#############################################################
# Créer le répertoire de configuration pour Nginx
mkdir -p "$NGINX_DIR/logs"
mkdir -p "$NGINX_DIR/temp/client_body"
mkdir -p "$NGINX_DIR/temp/proxy"
mkdir -p "$NGINX_DIR/conf"

# Copier le fichier mime.types
echo -e "${YELLOW}Configuration de Nginx...${NC}"
cp /etc/nginx/mime.types "$NGINX_DIR/conf/" || {
    echo -e "${YELLOW}Tentative alternative pour trouver mime.types...${NC}"
    find /usr -name mime.types -type f | head -1 | xargs -I{} cp {} "$NGINX_DIR/conf/"
}

# Préparer le frontend (build)
echo -e "${YELLOW}Construction du frontend en mode production...${NC}"
echo "VITE_API_URL=http://$API_HOST:$API_PORT" > $WEBUI_DIR/.env
cd "$WEBUI_DIR"
npm ci
export NODE_ENV=production
npm run prepare && npm run build && npm cache clean --force


############################################################################
# Démarrer le Superviseur
############################################################################
echo -e "${YELLOW}Démarrage du superviseur...${NC}"
bash "$APP_ROOT/clea-supervisor/runpod_entrypoint.sh"

