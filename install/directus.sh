#!/bin/bash

cd /usr/local/lib

DIRECTUS_APP_PATH=/usr/local/lib/directus-app
PROJECT_FILE_NAME=$(echo $PROJECT | sed "s/-/_/g")
PORT=${PORT:-8055}
DB_CLIENT=${DB_CLIENT:-mysql}
DB_HOST=${DB_HOST:-127.0.0.1}
DIRECTUS_VERSION=${DIRECTUS_VERSION:-9.0.0-rc.37}
DB_PORT=${DB_PORT:-3306}
DB_DATABASE=${DB_DATABASE:-directus_$PROJECT_FILE_NAME}
DB_USER=${DB_USER:-directus_user_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)}
DB_PASSWORD=${DB_PASSWORD:-$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-64)}
ADMIN_EMAIL=${ADMIN_EMAIL:-email@example.com}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-64)}
DIRECTUS_APP_KEY=$(uuidgen)
DIRECTUS_APP_SECRET=$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-64)

if [[ ! -f "$DIRECTUS_APP_PATH/package.json" ]] || [[ -v UPDATE ]]
then
  cd /usr/local/lib
  echo 'Creating directus project'
  mkdir directus-app && cd directus-app
  npm init -y
  npm install directus@$DIRECTUS_VERSION
fi

# Update files to read from custom configs
cd $DIRECTUS_APP_PATH
sed -i "s#permissions.flat()#lodash_1.flatten(permissions)#g" ./node_modules/directus/dist/utils/merge-permissions.js
sed -i "s|dotenv_1.default.config()|dotenv_1.default.config({path: process.env.DOTENV_CONFIG_PATH})|g" ./node_modules/directus/dist/env.js 
sed -i "s#dotenv_1.default.config({ path: path_1.default.resolve(__dirname, '../../', '.env') })#dotenv_1.default.config({ path: process.env.DOTENV_CONFIG_PATH || path_1.default.resolve(__dirname, '../../', '.env') })#g" ./node_modules/directus/dist/database/index.js

if [[ -v UPDATE ]];
then
  echo Updated
  exit 0
fi

if [[ -f $DIRECTUS_APP_PATH/config/$PROJECT_FILE_NAME.env ]]
then
  echo The Project already exist.
  exit -1
fi

if [[ ! -f $DIRECTUS_APP_PATH/config/$PROJECT_FILE_NAME.env ]]
then
  echo creating config file... $DIRECTUS_APP_PATH/$PROJECT_FILE_NAME.env
  mkdir -p $DIRECTUS_APP_PATH/config
cat > $DIRECTUS_APP_PATH/config/$PROJECT_FILE_NAME.env <<EOF
####################################################################################################
## General

PORT=$PORT
PUBLIC_URL="/"

####################################################################################################
## Database

DB_CLIENT="$DB_CLIENT"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_DATABASE="$DB_DATABASE"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"


####################################################################################################
## Rate Limiting

RATE_LIMITER_ENABLED=false
RATE_LIMITER_STORE=memory
RATE_LIMITER_POINTS=25
RATE_LIMITER_DURATION=1

####################################################################################################
## Cache

CACHE_ENABLED=false

####################################################################################################
## File Storage

STORAGE_LOCATIONS="local"
STORAGE_LOCAL_PUBLIC_URL="/uploads"
STORAGE_LOCAL_DRIVER="local"
STORAGE_LOCAL_ROOT="./uploads"

####################################################################################################
## Security

KEY="$DIRECTUS_APP_KEY"
SECRET="$DIRECTUS_APP_SECRET"

ACCESS_TOKEN_TTL="15m"
REFRESH_TOKEN_TTL="7d"
REFRESH_TOKEN_COOKIE_SECURE=false
REFRESH_TOKEN_COOKIE_SAME_SITE="lax"

####################################################################################################
## SSO (OAuth) Providers

OAUTH_PROVIDERS=""

####################################################################################################
## Extensions

EXTENSIONS_PATH="./extensions"

####################################################################################################
## Email

EMAIL_FROM="no-reply@directus.io"
EMAIL_TRANSPORT="sendmail"
EMAIL_SENDMAIL_NEW_LINE="unix"
EMAIL_SENDMAIL_PATH="/usr/sbin/sendmail"
EOF
fi

# Create database and user
if [[ $(mysql -e "SHOW DATABASES LIKE '$DB_DATABASE';" | wc -c) -eq 0 ]]
then
  echo creating DATABASE $DB_DATABASE
  mysql -e "CREATE DATABASE $DB_DATABASE;"
  mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
  mysql -e "GRANT ALL ON $DB_DATABASE.* TO '$DB_USER'@'localhost';"
  mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASSWORD';"
  mysql -e "flush privileges;"

  cd $DIRECTUS_APP_PATH
  DOTENV_CONFIG_PATH=$DIRECTUS_APP_PATH/config/$PROJECT_FILE_NAME.env ADMIN_EMAIL=$ADMIN_EMAIL PROJECT_NAME=$PROJECT ADMIN_PASSWORD=$ADMIN_PASSWORD npx directus bootstrap
  mkdir -p $HOME/.directus
  echo "$ADMIN_PASSWORD" > $HOME/.directus/$PROJECT_FILE_NAME
fi


cat > /lib/systemd/system/directus-$PROJECT.service <<EOF
[Unit]
Description=directus service for $PROJECT
After=network.target

[Service]
Environment=DOTENV_CONFIG_PATH=$DIRECTUS_APP_PATH/config/$PROJECT_FILE_NAME.env
WorkingDirectory=$DIRECTUS_APP_PATH
ExecStart=/usr/bin/npx directus start
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl restart directus-$PROJECT.service
sudo systemctl enable directus-$PROJECT.service
sudo systemctl status directus-$PROJECT.service

if [[ -f /etc/wspecs/global.conf ]]
then
  source $DIRECTUS_APP_PATH/config/$PROJECT_FILE_NAME.env
  source /etc/wspecs/global.conf
  BOX_KEY=$(cat /var/lib/wspecsbox/api.key)
  PRIMARY_DOMAIN=$(echo $PRIMARY_HOSTNAME | sed "s/box.//g")
  CUSTOM_DOMAIN=$PROJECT.$PRIMARY_DOMAIN

  cat > /usr/local/lib/wspecsbox/conf/$CUSTOM_DOMAIN.conf <<EOF
  location / {
    proxy_pass http://127.0.0.1:$PORT;
  }
EOF

  curl -X PUT -d "local" https://$PRIMARY_HOSTNAME/admin/dns/custom/$CUSTOM_DOMAIN --user "$BOX_KEY:"
  sleep 5s
  /usr/local/lib/wspecsbox/management/ssl_certificates.py
fi
