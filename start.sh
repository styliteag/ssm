#!/bin/sh

set -x

cd /app
export DATABASE_URL=sqlite://db/ssm.db
export PRIVATE_KEY_FILE=/app/id_rsa

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

# Start Rust App
echo "Starting Rust App in /app"
./ssh-key-manager
