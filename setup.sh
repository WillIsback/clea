#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/WillIsback/Clea.git"
REPO_DIR="Clea"

# 1️⃣ Clone + submodules
if [ ! -d "$REPO_DIR" ]; then
  git clone --recurse-submodules "$REPO_URL" "$REPO_DIR"
else
  echo "→ Le dossier $REPO_DIR existe déjà, on met juste à jour les submodules"
  cd "$REPO_DIR"
  git pull
  git submodule update --init --recursive
  cd -
fi

cd "$REPO_DIR"

# 2️⃣ Détection OS
OS="$(uname | tr '[:upper:]' '[:lower:]')"
echo "→ Système détecté : $OS"

install_linux() {
  echo "→ Installation des dépendances système (apt)..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates gnupg lsb-release \
    build-essential git wget \
    nginx supervisor \
    pkg-config cmake protobuf-compiler libprotobuf-dev \
    locales gettext
  
  echo "→ Configuration des locales FR..."
  sudo sed -i '/fr_FR.UTF-8/s/^# //g' /etc/locale.gen
  sudo locale-gen

  echo "→ Node.js 22.x via Nodesource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get update
  sudo apt-get install -y nodejs
  sudo rm -rf /var/lib/apt/lists/*

  echo "→ PostgreSQL + pgvector..."
  bash clea-db/init/install-postgres.sh
}

install_mac() {
  echo "→ Installation des dépendances système (brew)..."
  which brew >/dev/null || {
    echo "Homebrew non trouvé : installation automatique..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  }

  brew update
  brew install curl git node nginx postgresql protobuf cmake gettext

  echo "→ Lancement de PostgreSQL..."
  brew services start postgresql

  echo "→ Installation de supervisor (via pip)..."
  pip3 install --user supervisor

  echo "→ Configuration des locales FR (si nécessaire)..."
  sudo mkdir -p /usr/local/var/locale
  sudo cp /usr/share/locale/fr_FR.* /usr/local/var/locale/ || true
}

install_windows() {
  echo "→ Windows détecté, on suppose Git Bash + Chocolatey..."
  choco install -y git curl python python3 nodejs-lts postgresql nginx

  echo "→ Ajout de supervisor via pip..."
  pip install supervisor

  echo "→ Démarrage du service PostgreSQL..."
  net start postgresql  

  echo "→ (Si WSL disponible, vous pouvez plutôt installer sous Ubuntu...)"
}

case "$OS" in
  linux*)
    install_linux
    ;;
  darwin*)
    install_mac
    ;;
  msys*|mingw*|cygwin*)
    install_windows
    ;;
  *)
    echo "OS non supporté par ce script : $OS"
    exit 1
    ;;
esac

# 3️⃣ Variables d'environnement
export APP_ROOT="$PWD"
export API_DIR="$APP_ROOT/clea-api"
export WEBUI_DIR="$APP_ROOT/clea-webui"
export NGINX_DIR="$APP_ROOT/clea-nginx"
export LOGS_DIR="$APP_ROOT/logs"

export DB_USER=postgres
export DB_PASSWORD=password
export DB_NAME=vectordb
export DB_HOST=localhost
export DB_PORT=5432
export API_HOST=localhost
export API_PORT=8080
export WEBUI_HOST=localhost
export WEBUI_PORT=3000
export NGINX_PORT=8888
export NGINX_HOST=localhost
export API_URL=/api
export ALLOW_ALL_ORIGINS=true
export TORCH_DEVICE=cuda
export FRONTEND_URLS="http://localhost:${NGINX_PORT}"
export PYTHONUNBUFFERED=1
export COMPOSE_BAKE=true
export PYTHONPATH="$APP_ROOT"

# 4️⃣ Création des dossiers
echo "→ Création de l’arborescence"
mkdir -p "${API_DIR}" "${WEBUI_DIR}" "${LOGS_DIR}" \
         "${NGINX_DIR}/logs" "${NGINX_DIR}/conf" \
         "${NGINX_DIR}/temp/client_body" "${NGINX_DIR}/temp/proxy" \
         "${NGINX_DIR}/temp/fastcgi" "${NGINX_DIR}/temp/uwsgi" \
         "${NGINX_DIR}/temp/scgi"

# 6️⃣ API Python
echo "→ Installation de l’API Python"
cd "$API_DIR"
# installe uv (votre gestionnaire de venv + paquet)
uv venv
uv pip install --system -r requirements.txt

# 7️⃣ Build du front-end
echo "→ Build du front-end"
cd "$WEBUI_DIR"
npm ci
export NODE_ENV=production
echo "PUBLIC_API_URL=${API_HOST}:${API_PORT}/api" > .env
npm run prepare && npm run build && npm cache clean --force

# 8️⃣ Configuration finale
echo "→ Rendre l’entrypoint exécutable"
chmod +x "$APP_ROOT/clea-supervisor/runpod_entrypoint.sh"

cat <<EOF

✅ Installation terminée !

Pour lancer l’ensemble, vous pouvez par exemple :

  # Démarrer la solution directement :
  $APP_ROOT/clea-supervisor/runpod_entrypoint.sh

  # Démarrer en recompilant :
  $APP_ROOT/start-local-supervisor.sh

  # Démarrer nginx
  sudo nginx -c $NGINX_DIR/conf/nginx.conf

  # Lancer supervisor
  supervisord -c $APP_ROOT/clea-supervisor/supervisord.conf

EOF
