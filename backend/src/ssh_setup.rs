use std::path::PathBuf;
use log::error;
use russh::keys::load_secret_key;
use russh::keys::PrivateKey;

pub fn validate_and_load_ssh_key(key_path: &PathBuf, passphrase: Option<&str>) -> Result<PrivateKey, std::io::Error> {
    if !key_path.exists() {
        eprintln!("╔══════════════════════════════════════════════════════════════════════════════╗");
        eprintln!("║                          🔑 SSH KEY REQUIRED                                 ║");
        eprintln!("╠══════════════════════════════════════════════════════════════════════════════╣");
        eprintln!("║ SSH private key file not found: {:<44} ║", key_path.display());
        eprintln!("║                                                                              ║");
        eprintln!("║ Please generate an SSH key pair and ensure the private key file exists,      ║");
        eprintln!("║ or set the SSH_KEY environment variable to point to your private key.        ║");
        eprintln!("║                                                                              ║");
        eprintln!("║ To generate an ed25519 SSH key pair:                                         ║");
        eprintln!();
        if let Some(parent) = key_path.parent() {
            eprintln!("mkdir -p {}", parent.display());
        } else {
            eprintln!("mkdir -p keys");
        }
        eprintln!("ssh-keygen -t ed25519 -f {} -C 'ssm-server'", key_path.display());
        eprintln!("chmod 600 {}", key_path.display());
        eprintln!("chmod 644 {}.pub", key_path.display());
        eprintln!();
        eprintln!("║                                                                              ║");
        eprintln!("║ Or set the SSH_KEY environment variable:                                     ║");
        eprintln!("║   SSH_KEY=/path/to/your/private/key cargo run                                ║");
        eprintln!("╚══════════════════════════════════════════════════════════════════════════════╝");
        std::process::exit(1);
    }

    load_secret_key(key_path, passphrase)
        .map_err(|e| {
            error!("Failed to load private key: {}", e);
            std::io::Error::new(std::io::ErrorKind::InvalidInput, format!("Failed to load private key: {}", e))
        })
}

