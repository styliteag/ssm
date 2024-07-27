#!/bin/sh

set -x

ls

# Start Rust App
echo "Starting Rust App in /app"
cd /app 
export DATABASE_URL=sqlite://db/ssm.db
export PRIVATE_KEY_FILE=/app/id_rsa
ls -l
if [ ! -f ./config.toml ]; then
    echo "Config file not found"
    echo "Creating config file"
    cat > config.toml <<- EOF
      # Database URL. Defaults to `sqlite://ssm.db`
      # database_url = 'postgresql://user@host'
      # database_url = 'sqlite://db/ssm.db'

      [ssh]
      # Path to private key file for authenticating with the Hosts
      private_key_file = '/app/id_ed25519'
      
      # Optional Passphrase for the given keyh
      # private_key_passphrase = 'passphrase'
EOF
    mkdir -p db
fi
# Create ssm.db if not exists
if [ ! -f ./db/ssm.db ]; then
    echo "Creating db/ssm.db"
    ./diesel setup
fi  
./ssh-key-manager