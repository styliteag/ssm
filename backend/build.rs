use std::process::Command;
use std::path::Path;
use std::fs;

fn main() {
    // Print build information
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=config.toml");
    println!("cargo:rerun-if-env-changed=CARGO_PKG_VERSION");
    println!("cargo:rerun-if-env-changed=CONFIG");
    println!("cargo:rerun-if-env-changed=DATABASE_URL");

    // Create assets directory for custom downloads if needed
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let assets_dir = Path::new(&out_dir).join("assets");
    fs::create_dir_all(&assets_dir).unwrap();

    // Print current package version for debugging
    println!("cargo:warning=Building SSM version {}", env!("CARGO_PKG_VERSION"));

    // Perform build-time checks
    println!("cargo:warning=Running pre-build checks...");

    check_config_file();
    check_ssh_key_file();
    check_htpasswd_file();
    check_database_migrations();
    check_curl_availability();

    println!("cargo:warning=Pre-build checks completed successfully");
}

/// Check if configuration file exists and is valid
fn check_config_file() {
    let config_path = std::env::var("CONFIG").unwrap_or_else(|_| "config.toml".to_string());
    let config_path = Path::new(&config_path);

    if !config_path.exists() {
        println!("cargo:warning=Configuration file not found: {}", config_path.display());
        println!("cargo:warning=Copy config.toml.example to config.toml and configure it");
        return;
    }

    match fs::read_to_string(config_path) {
        Ok(content) => {
            // Basic TOML validation
            if content.contains("[") && content.contains("]") {
                println!("cargo:warning=Configuration file looks valid: {}", config_path.display());
            } else {
                println!("cargo:warning=Configuration file may be malformed: {}", config_path.display());
            }
        }
        Err(e) => {
            println!("cargo:warning=Cannot read configuration file {}: {}", config_path.display(), e);
        }
    }
}

/// Check if SSH private key file exists and is accessible
fn check_ssh_key_file() {
    // Try to read SSH key path from config, fallback to default
    let ssh_key_path = if Path::new("config.toml").exists() {
        match fs::read_to_string("config.toml") {
            Ok(content) => {
                // Simple regex-like search for private_key_file
                if let Some(line) = content.lines().find(|l| l.contains("private_key_file")) {
                    if let Some(path_start) = line.find('"') {
                        if let Some(path_end) = line[path_start + 1..].find('"') {
                            Some(line[path_start + 1..path_start + 1 + path_end].to_string())
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            Err(_) => None,
        }
    } else {
        None
    };

    let ssh_key_path = ssh_key_path.unwrap_or_else(|| "/Users/bonis/.ssh/id_ssm".to_string());
    let ssh_key_path = Path::new(&ssh_key_path);

    if ssh_key_path.exists() {
        match fs::metadata(ssh_key_path) {
            Ok(metadata) => {
                // Check if file is readable
                if metadata.is_file() {
                    println!("cargo:warning=SSH private key found: {}", ssh_key_path.display());
                } else {
                    println!("cargo:warning=SSH key path exists but is not a file: {}", ssh_key_path.display());
                }
            }
            Err(e) => {
                println!("cargo:warning=Cannot access SSH key file {}: {}", ssh_key_path.display(), e);
            }
        }
    } else {
        println!("cargo:warning=SSH private key not found: {}", ssh_key_path.display());
        println!("cargo:warning=SSH operations may fail without a valid private key");
    }
}

/// Check if htpasswd authentication file exists
fn check_htpasswd_file() {
    let htpasswd_paths = [".htpasswd", "backend/.htpasswd"];

    for path in &htpasswd_paths {
        let htpasswd_path = Path::new(path);
        if htpasswd_path.exists() {
            match fs::read_to_string(htpasswd_path) {
                Ok(content) => {
                    if content.lines().count() > 0 {
                        println!("cargo:warning=Htpasswd file found with users: {}", htpasswd_path.display());
                        return;
                    } else {
                        println!("cargo:warning=Htpasswd file exists but is empty: {}", htpasswd_path.display());
                    }
                }
                Err(e) => {
                    println!("cargo:warning=Cannot read htpasswd file {}: {}", htpasswd_path.display(), e);
                }
            }
        }
    }

    println!("cargo:warning=No htpasswd file found. Authentication may not work.");
    println!("cargo:warning=Create with: htpasswd -c .htpasswd username");
}

/// Check if database migrations exist
fn check_database_migrations() {
    let migrations_dir = Path::new("migrations");

    if migrations_dir.exists() && migrations_dir.is_dir() {
        match fs::read_dir(migrations_dir) {
            Ok(entries) => {
                let migration_count = entries.count();
                if migration_count > 0 {
                    println!("cargo:warning=Found {} database migrations", migration_count);
                } else {
                    println!("cargo:warning=Migrations directory exists but is empty");
                }
            }
            Err(e) => {
                println!("cargo:warning=Cannot read migrations directory: {}", e);
            }
        }
    } else {
        println!("cargo:warning=Migrations directory not found");
        println!("cargo:warning=Database operations may fail without migrations");
    }
}

/// Check if curl is available for utoipa-swagger-ui downloads
fn check_curl_availability() {
    match Command::new("curl").arg("--version").output() {
        Ok(output) if output.status.success() => {
            println!("cargo:warning=curl found, utoipa-swagger-ui should build successfully");
        }
        _ => {
            println!("cargo:warning=curl not found! utoipa-swagger-ui may fail to download assets");
            println!("cargo:warning=Consider installing curl or using a different Swagger UI solution");
        }
    }
}

#[allow(dead_code)]
fn download_swagger_ui_fallback(_assets_dir: &Path) {
    // Fallback download using reqwest if available
    println!("cargo:warning=Attempting fallback download of Swagger UI...");

    // This would require adding reqwest as a build dependency
    // For now, just warn the user
    println!("cargo:warning=Fallback download not implemented yet");
    println!("cargo:warning=Consider adding reqwest as a build dependency for offline builds");
}
