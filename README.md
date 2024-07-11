# ssh-key-manager

Manages your ssh keys from a single interface.


## Development Setup

You can use the provided nix flake, either trough `nix develop` or with direnv.

Alternatively, you can manually setup the developement environment.

### Install and setup diesel

```sh
# Install the diesel cli, you can skip this if you already have it installed
cargo install diesel_cli --no-default-features --features sqlite
# Set up the Database. Make sure to have a `DATABASE_URL` in your environment
diesel setup
```

### Create the configuration

By default, ssh-key-manager will look for a file called `config.toml`.
Alternatively, you can use the `CONFIG` environment variable to change the location of the configuration file.

Another method is to use environment variables with the same name as the config values, capitalization doesn't matter.
Environment variables have priority over the toml configuration.

Example configuration:
```toml
# Database URL. Defaults to `sqlite://ssm.db`
database_url = 'postgresql://user@host'

[ssh]
# Path to private key file for authenticating with the Hosts
private_key_file = '/path/to/your/private_key'

# Optional Passphrase for the given keyh
private_key_passphrase = 'OptionalPassphrase'

# Which user to try authenticating as (in the future this will be per-host configurable)
user = 'root'
```
