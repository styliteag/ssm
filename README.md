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
