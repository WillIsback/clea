#!/bin/bash
set -e

echo "Installation de PostgreSQL 17..."

# Ajouter le dépôt PostgreSQL
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
. /etc/os-release
echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt/ ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# Mettre à jour et installer PostgreSQL 17
apt-get update
apt-get install -y --no-install-recommends postgresql-17 postgresql-server-dev-17 postgresql-client-17

# Installer pgvector depuis les sources
cd /tmp
git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
cd pgvector
make
make install
cd /
rm -rf /tmp/pgvector

# Configurer PostgreSQL pour accepter les connexions de localhost
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" /etc/postgresql/17/main/postgresql.conf
sed -i "s/peer/trust/" /etc/postgresql/17/main/pg_hba.conf
sed -i "s/ident/md5/" /etc/postgresql/17/main/pg_hba.conf
echo "host all all 127.0.0.1/32 md5" >> /etc/postgresql/17/main/pg_hba.conf

# Configurer les locales pour PostgreSQL
apt-get install -y --no-install-recommends locales
sed -i '/fr_FR.UTF-8/s/^# //g' /etc/locale.gen
locale-gen

# Nettoyer les paquets
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "PostgreSQL 17 et pgvector installés avec succès"
