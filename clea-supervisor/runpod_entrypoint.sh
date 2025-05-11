#!/bin/bash
# Fichier: clea-supervisor/runpod_entrypoint.sh
# Description: Script de démarrage pour l'image Docker runpod-Clea
# Utilisé par: Dockerfile (ligne CMD)
# Dépendances: supervisord.conf
set -e
set -x

# Créer la configuration Supervisor (à partir du template)
echo -e "${YELLOW}Configuration de Supervisor...${NC}"
# Vérifier si le fichier template existe
if [ -f "$SUPERVISOR_CONF_TEMPLATE" ]; then
    echo -e "${YELLOW}Utilisation du template Supervisor existant...${NC}"
    # Utiliser envsubst pour remplacer les variables dans le fichier
    envsubst < "$SUPERVISOR_CONF_TEMPLATE" > "$SUPERVISOR_CONF"
    echo -e "${GREEN}Configuration Supervisor générée avec succès${NC}"
else
    echo -e "${RED}ERREUR: Template supervisord.conf.template introuvable dans clea-supervisor/${NC}"
    echo -e "${YELLOW}Veuillez créer le fichier supervisord.conf.template dans clea-supervisor/${NC}"
    exit 1
fi
# Configurer Nginx à partir du template
echo -e "${YELLOW}Configuration de Nginx...${NC}"
if [ -f "$NGINX_CONF_TEMPLATE" ]; then
    echo -e "${YELLOW}Utilisation du template Nginx existant...${NC}"
    # Utiliser envsubst pour remplacer les variables
    envsubst < "$NGINX_CONF_TEMPLATE" > "$NGINX_CONF"
    # Remplacer __DOLLAR__ par $ dans le fichier de configuration pour les variables NGINX
    sed -i 's/__DOLLAR__/\$/g' "$NGINX_CONF"
    echo -e "${GREEN}Configuration Nginx générée avec succès${NC}"
else
    echo -e "${YELLOW}Template Nginx non trouvé. Création d'un nouveau...${NC}"
    echo -e "${YELLOW}Veuillez créer le fichier nginx.conf.template dans clea-nginx/conf/${NC}"
    exit 1
fi


echo -e "${GREEN}Tous les outils sont disponibles :${NC}"
echo -e "Node $(node --version), npm $(npm --version), uv $(uv --version)"

# 1. Démarrer PostgreSQL manuellement
echo -e "${YELLOW}Démarrage de PostgreSQL...${NC}"
su postgres -c "/usr/lib/postgresql/17/bin/postgres -D /var/lib/postgresql/17/main &"
PG_PID=$!

# 2. Attendre que PostgreSQL soit prêt
echo -e "${YELLOW}Attente de PostgreSQL...${NC}"
for i in {1..30}; do
    if pg_isready -U postgres -q; then
        echo -e "${GREEN}PostgreSQL est prêt!${NC}"
        break
    fi
    echo -e "${YELLOW}Attente de PostgreSQL ($i/30)...${NC}"
    sleep 1
done

if ! pg_isready -U postgres -q; then
    echo -e "${RED}PostgreSQL n'a pas démarré correctement après 30 secondes.${NC}"
    exit 1
fi

# 3. Initialiser la base de données avec pgvector
echo -e "${YELLOW}Vérification/création de la base de données...${NC}"
if ! psql -U postgres -lqt | grep -q $DB_NAME; then
    echo -e "${YELLOW}Création de la base de données $DB_NAME...${NC}"
    psql -U postgres -c "CREATE DATABASE $DB_NAME;"
    psql -U postgres -c "ALTER USER postgres WITH PASSWORD '$DB_PASSWORD';"
fi

# 4. Vérifier et installer pgvector
echo -e "${YELLOW}Installation de l'extension pgvector...${NC}"
if ! psql -U postgres -d $DB_NAME -c "SELECT * FROM pg_extension WHERE extname = 'vector';" | grep -q vector; then
    echo -e "${YELLOW}Installation de l'extension pgvector...${NC}"
    psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;"
    echo -e "${GREEN}Extension pgvector installée avec succès.${NC}"
else
    echo -e "${GREEN}Extension pgvector déjà installée.${NC}"
fi

# Arrêter tout service existant de façon plus robuste
echo -e "${YELLOW}Arrêt des services existants...${NC}"
# Arrêter supervisord s'il est en cours d'exécution
if [ -f "$SCRIPT_DIR/supervisord.pid" ]; then
    echo -e "${YELLOW}Arrêt de supervisord...${NC}"
    supervisorctl -c "$SUPERVISOR_CONF" stop all 2>/dev/null || true
    supervisorctl -c "$SUPERVISOR_CONF" shutdown 2>/dev/null || true
    sleep 2
fi

# S'assurer que tous les ports sont libres
for port in $API_PORT $WEBUI_PORT $NGINX_PORT; do
    if lsof -i :$port -t >/dev/null 2>&1; then
        echo -e "${YELLOW}Arrêt des processus sur le port $port...${NC}"
        for pid in $(lsof -i :$port -t); do
            echo "Arrêt du processus $pid"
            kill -9 $pid 2>/dev/null || true
        done
        sleep 1
    fi
done

# Vérification spécifique pour les processus Python sur le port API
echo -e "${YELLOW}Recherche de tous les processus Python utilisant le port API...${NC}"
python_pids=$(pgrep -f "python.*$API_PORT" || true)
if [ -n "$python_pids" ]; then
    echo -e "${YELLOW}Processus Python trouvés : $python_pids - Arrêt forcé...${NC}"
    for pid in $python_pids; do
        echo "Arrêt du processus Python $pid"
        kill -9 $pid 2>/dev/null || true
    done
    sleep 2
fi

# Vérification finale pour s'assurer que le port API est réellement libre
if lsof -i :$API_PORT >/dev/null 2>&1; then
    echo -e "${RED}ERREUR: Port $API_PORT toujours occupé après nettoyage!${NC}"
    echo -e "${YELLOW}Voici les processus persistants:${NC}"
    lsof -i :$API_PORT
    echo -e "${YELLOW}Tentative d'arrêt avec fuser...${NC}"
    fuser -k -n tcp $API_PORT || true
    sleep 3
    
    # Vérification ultime
    if lsof -i :$API_PORT >/dev/null 2>&1; then
        echo -e "${RED}Échec critique: Port $API_PORT impossible à libérer. Utilisation d'un port alternatif...${NC}"
        export API_PORT=8081
        echo -e "${YELLOW}Nouveau port API: $API_PORT${NC}"
    fi
fi

# Vérifier spécifiquement si nginx tourne encore
nginx_pid=$(pgrep -f "nginx.*$SCRIPT_DIR/clea-nginx" || true)
if [ -n "$nginx_pid" ]; then
    echo -e "${YELLOW}Arrêt forcé de Nginx (PID: $nginx_pid)...${NC}"
    kill -9 $nginx_pid 2>/dev/null || true
    sleep 1
fi

# Nettoyer le socket de supervisord s'il existe
if [ -e "$SCRIPT_DIR/supervisor.sock" ]; then
    rm -f "$SCRIPT_DIR/supervisor.sock"
fi

# Après avoir tué les processus sur le port 8888
echo -e "${YELLOW}Attente pour libération complète du port $NGINX_PORT...${NC}"
sleep 5

# Vérifier à nouveau si le port est vraiment libre
if lsof -i :$NGINX_PORT >/dev/null 2>&1; then
    echo -e "${RED}Le port $NGINX_PORT est toujours utilisé après le nettoyage. Voir quels processus:${NC}"
    lsof -i :$NGINX_PORT
    echo -e "${YELLOW}Utilisation du port alternatif 8889...${NC}"
fi


######### Démarrer supervisord #########
echo -e "${YELLOW}Démarrage de supervisord...${NC}"
########################################
exec /usr/bin/supervisord -c "$SUPERVISOR_CONF" &
SUPERVISORD_PID=$!
# Attendre que PostgreSQL soit prêt
echo "Attente du démarrage de PostgreSQL..."
for i in {1..30}; do
    if pg_isready -U postgres -q; then
        break
    fi
    echo "Attente de PostgreSQL ($i/30)..."
    sleep 1
done

# Initialiser la base de données si nécessaire
if ! psql -U postgres -lqt | grep -q $DB_NAME; then
    echo "Initialisation de la base de données..."
    
    # Créer la base et configurer l'utilisateur
    psql -U postgres -c "CREATE DATABASE $DB_NAME;"
    psql -U postgres -c "ALTER USER postgres WITH PASSWORD '$DB_PASSWORD';"
    
    # Installer l'extension pgvector
    psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;"
    echo "Base de données initialisée avec succès !"
else
    echo "La base de données $DB_NAME existe déjà."
fi


# Afficher l'URL d'accès
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Plateforme runpod-Clea démarrée avec succès!${NC}"
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}URL d'accès: http://${NGINX_HOST}:${NGINX_PORT}${NC}"
echo -e "${GREEN}==================================${NC}"
function cleanup {
    echo -e "\n${YELLOW}Arrêt des services...${NC}"
    
    # Étape 1: Arrêt gracieux via supervisor
    echo -e "${YELLOW}Arrêt des services via supervisor...${NC}"
    supervisorctl -c "$SUPERVISOR_CONF" stop all || true
    sleep 2
    supervisorctl -c "$SUPERVISOR_CONF" shutdown || true
    sleep 3
    
    if [ -n "$SUPERVISORD_PID" ]; then
        kill -TERM "$SUPERVISORD_PID" 2>/dev/null || true
    fi
    # Étape 2: Vérification et arrêt forcé des processus restants
    echo -e "${YELLOW}Vérification des processus restants...${NC}"
    
    # Arrêter nginx
    nginx_pids=$(pgrep -f "nginx.*$NGINX_DIR" || true)
    if [ -n "$nginx_pids" ]; then
        echo -e "${YELLOW}Arrêt forcé de Nginx (PID: $nginx_pids)...${NC}"
        for pid in $nginx_pids; do
            kill -9 $pid 2>/dev/null || true
        done
    fi
    
    # Arrêter tous les processus sur les ports utilisés
    for port in $API_PORT $WEBUI_PORT $NGINX_PORT; do
        port_pids=$(lsof -i :$port -t 2>/dev/null || true)
        if [ -n "$port_pids" ]; then
            echo -e "${YELLOW}Fermeture forcée des processus sur le port $port (PID: $port_pids)...${NC}"
            for pid in $port_pids; do
                kill -9 $pid 2>/dev/null || true
            done
        fi
    done
    
    # Étape 3: Utiliser fuser pour les cas extrêmes
    for port in $API_PORT $WEBUI_PORT $NGINX_PORT; do
        if lsof -i :$port >/dev/null 2>&1; then
            echo -e "${YELLOW}Utilisation de fuser pour libérer le port $port...${NC}"
            fuser -k -n tcp $port 2>/dev/null || true
        fi
    done
    
    # Étape 4: Nettoyage des fichiers temporaires
    echo -e "${APP_ROOT}Nettoyage des fichiers temporaires...${NC}"
    if [ -f "$APP_ROOT/supervisord.pid" ]; then
        rm -f "$APP_ROOT/supervisord.pid"
    fi
    if [ -S "$APP_ROOT/supervisor.sock" ]; then
        rm -f "$APP_ROOT/supervisor.sock"
    fi
    if [ -f "$NGINX_DIR/nginx.pid" ]; then
        rm -f "$NGINX_DIR/nginx.pid"
    fi

    # Étape 5: Vérification finale
    sleep 2
    ports_still_in_use=""
    for port in $API_PORT $WEBUI_PORT $NGINX_PORT; do
        if lsof -i :$port >/dev/null 2>&1; then
            ports_still_in_use+=" $port"
        fi
    done
    
    if [ -z "$ports_still_in_use" ]; then
        echo -e "${GREEN}Tous les services ont été correctement arrêtés et les ports sont libres.${NC}"
    else
        echo -e "${RED}Attention: Les ports suivants sont toujours utilisés:$ports_still_in_use${NC}"
        echo -e "${RED}Vous devrez peut-être redémarrer votre terminal ou système pour les libérer.${NC}"
    fi
    
    echo -e "${GREEN}Au revoir!${NC}"
    exit 0
}
# Intercepter plus de signaux pour un arrêt plus fiable
trap cleanup EXIT INT TERM

# Afficher les logs en temps réel
echo -e "${YELLOW}Affichage des logs (Ctrl+C pour quitter)...${NC}"
tail -f "$APP_ROOT/logs/"*