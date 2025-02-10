> [!NOTE]
> This is pre-release software. Use at your own risk.

# Secure SSH Manager

Manage your ssh keys from a simple Web UI.

## Development Setup

You can use the provided nix flake, either trough `nix develop` or with direnv.

Alternatively, you can manually setup the developement environment.

### Install and setup diesel (optional)

``` sh
# Install the diesel cli, you can skip this if you already have it installed
cargo install diesel_cli --no-default-features --features sqlite
# Set up the Database. Make sure to have a `DATABASE_URL` in your environment
diesel setup
```

### Setup passwd file
```sh
htpasswd -B -c .htpasswd user
```

### Create the configuration

By default, ssh-key-manager will look for a file called `config.toml`.
Alternatively, you can use the `CONFIG` environment variable to change the location of the configuration file.

Another method is to use environment variables with the same name as the config values, capitalization doesn't matter.
Environment variables have priority over the toml configuration.

Example configuration:

``` toml
# Database URL. Defaults to `sqlite://ssm.db`
database_url = 'postgresql://user@host'

# Webinterface listen address
listen = "127.0.0.1"

# Webinterface port
port = 8080

# Loglevel, can be overriden with RUST_LOG environment variable
loglevel = "info"

[ssh]
# Path to private key file for authenticating with the Hosts
private_key_file = '/path/to/your/private_key'

# Optional Passphrase for the given keyh
private_key_passphrase = 'OptionalPassphrase'
```

### Manually stop ssm from writing keyfiles
If you want to prevent ssm from overwriting some of your keyfiles there are two options:

 - create `.ssh/system_readonly` (inside the `$HOME` of the user which is used to connect to the host): disables updating for all keyfile on this host.
 - create `.ssh/user_readonly` (inside any users `$HOME`): disables updating just this users keyfiles.

You can optionally provide a reason in the file, which will be displayed in ssm.
