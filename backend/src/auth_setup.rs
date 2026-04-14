use std::path::PathBuf;
use log::{error, info};
use rand::Rng;
use rand::distr::Alphanumeric;

pub fn ensure_htpasswd_file(htpasswd_path: &PathBuf) -> Result<(), std::io::Error> {
    if !htpasswd_path.exists() {
        info!("htpasswd file not found, creating default admin user...");

        // Create directory if it doesn't exist
        if let Some(parent) = htpasswd_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                error!("Failed to create directory for htpasswd file: {}", e);
                std::process::exit(3);
            }
        }

        // Generate a random password
        let password: String = rand::rng()
            .sample_iter(&Alphanumeric)
            .take(16)
            .map(char::from)
            .collect();

        // Hash the password with bcrypt
        let hashed_password = bcrypt::hash(&password, bcrypt::DEFAULT_COST)
            .map_err(|e| {
                error!("Failed to hash password: {}", e);
                std::io::Error::new(std::io::ErrorKind::Other, format!("Failed to hash password: {}", e))
            })?;

        // Write to htpasswd file in Apache format
        let htpasswd_content = format!("admin:{}\n", hashed_password);
        if let Err(e) = std::fs::write(htpasswd_path, htpasswd_content) {
            error!("Failed to create htpasswd file: {}", e);
            std::process::exit(3);
        }

        println!("╔═══════════════════════════════════════════════════════════════╗");
        println!("║                          🚀 SSM SERVER STARTUP                ║");
        println!("╠═══════════════════════════════════════════════════════════════╣");
        println!("║ Default admin user created!                                   ║");
        println!("║                                                               ║");
        println!("║ Username: admin                                               ║");
        println!("║ Password: {:<51} ║", password);
        println!("║                                                               ║");
        println!("║ Save this password securely!                                  ║");
        println!("║ You can change it later using: htpasswd -B .htpasswd admin    ║");
        println!("╚═══════════════════════════════════════════════════════════════╝");
        println!();

        info!("Created default admin user in htpasswd file: {:?}", htpasswd_path);
    }

    Ok(())
}

