use std::{env, net::IpAddr, path::PathBuf, sync::Arc, time::Duration};

use actix_cors::Cors;
use actix_identity::IdentityMiddleware;
use actix_session::{storage::CookieSessionStore, SessionMiddleware};
use actix_web::{
    http::header,
    middleware::Logger,
    web::{self, Data},
    App, HttpServer,
};
use config::Config;
use croner::Cron;
use log::{error, info};
use serde::Deserialize;
use rand::{Rng, thread_rng};
use rand::distributions::Alphanumeric;
use ssh::{CachingSshClient, SshClient};

use diesel::r2d2::{ConnectionManager, CustomizeConnection, Pool};

use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
use russh::keys::load_secret_key;

mod api_types;
mod db;
mod logging;
mod middleware;
mod models;
mod openapi;
mod routes;
mod scheduler;
mod schema;
mod ssh;

#[cfg(test)]
mod tests;

#[cfg(test)]
macro_rules! test_only {
    () => {
        #[cfg(not(test))]
        panic!("This function can only be called during testing");
    };
}

#[cfg(test)]
pub(crate) use test_only;

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!();

#[derive(diesel::MultiConnection)]
pub enum DbConnection {
    Sqlite(diesel::SqliteConnection),
}

pub type ConnectionPool = Pool<ConnectionManager<DbConnection>>;

#[derive(Debug)]
struct SqliteConnectionCustomizer;

impl CustomizeConnection<DbConnection, diesel::r2d2::Error> for SqliteConnectionCustomizer {
    fn on_acquire(&self, conn: &mut DbConnection) -> Result<(), diesel::r2d2::Error> {
        use diesel::{sql_query, RunQueryDsl};
        
        match conn {
            DbConnection::Sqlite(_) => {
                sql_query("PRAGMA foreign_keys = ON")
                    .execute(conn)
                    .map_err(diesel::r2d2::Error::QueryError)?;
            }
        }
        Ok(())
    }
}

const fn default_timeout() -> Duration {
    Duration::from_secs(120)
}

fn deserialize_timeout<'de, D>(deserializer: D) -> Result<Duration, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let seconds = u64::deserialize(deserializer)?;
    Ok(Duration::from_secs(seconds))
}

fn deserialize_cron<'de, D>(deserializer: D) -> Result<Option<Cron>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let mut pat = String::deserialize(deserializer)?;

    // Set seconds to 0 if omitted
    // tokio-cron-scheduler only works with seconds.
    let num_parts = pat.split_whitespace().count();
    if num_parts == 5 {
        pat = format!("0 {pat}");
    }

    match Cron::new(pat.as_str()).with_seconds_required().parse() {
        Ok(cron) => Ok(Some(cron)),
        Err(e) => {
            eprintln!("Failed to parse Cron syntax '{pat}': {e}");
            std::process::exit(3);
        }
    }
}

fn no_cron() -> Option<Cron> {
    None
}

#[derive(Debug, Deserialize, Clone)]
pub struct SshConfig {
    /// Cron schedule when to check Hosts (default disabled)
    /// In the future this will trigger some sort of action
    /// e.g. send an Email
    #[serde(default = "no_cron", deserialize_with = "deserialize_cron")]
    check_schedule: Option<Cron>,

    /// Cron schedule when update the cache (default disabled)
    #[serde(default = "no_cron", deserialize_with = "deserialize_cron")]
    update_schedule: Option<Cron>,

    /// Path to an OpenSSH Private Key
    #[serde(default = "default_private_key_file")]
    private_key_file: PathBuf,
    /// Passphrase for the key
    private_key_passphrase: Option<String>,
    /// Connection timeout in seconds (default 2m)
    #[serde(default = "default_timeout", deserialize_with = "deserialize_timeout")]
    timeout: Duration,
}

fn default_database_url() -> String {
    "sqlite://ssm.db".to_owned()
}

const fn default_listen() -> IpAddr {
    use core::net::Ipv6Addr;
    IpAddr::V6(Ipv6Addr::UNSPECIFIED)
}

const fn default_port() -> u16 {
    8000
}

fn default_loglevel() -> String {
    "info".to_owned()
}

fn default_session_key() -> String {
    env::var("SESSION_KEY").unwrap_or_else(|_| {
        error!("SESSION_KEY environment variable not set! Using insecure default.");
        String::from("my-secret-key-please-change-me-in-production")
    })
}

fn default_htpasswd_path() -> PathBuf {
    PathBuf::from(".htpasswd")
}

fn default_private_key_file() -> PathBuf {
    PathBuf::from("keys/id_ssm")
}

fn default_ssh_config() -> SshConfig {
    SshConfig {
        check_schedule: None,
        update_schedule: None,
        private_key_file: default_private_key_file(),
        private_key_passphrase: None,
        timeout: default_timeout(),
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct Configuration {
    #[serde(default = "default_ssh_config")]
    ssh: SshConfig,
    #[serde(default = "default_database_url")]
    database_url: String,
    #[serde(default = "default_listen")]
    listen: IpAddr,
    #[serde(default = "default_port")]
    port: u16,
    #[serde(default = "default_loglevel")]
    loglevel: String,
    #[serde(default = "default_session_key")]
    session_key: String,
    #[serde(default = "default_htpasswd_path")]
    htpasswd_path: PathBuf,
}

fn get_configuration() -> (Configuration, String) {
    let config_path = env::var("CONFIG").unwrap_or_else(|_| String::from("./config.toml"));
    let config_builder = Config::builder();

    let (config_builder, config_source) = if std::path::Path::new(&config_path).exists() {
        use config::FileFormat::Toml;
        (
            config_builder.add_source(config::File::new(&config_path, Toml).required(false)),
            format!("Loading configuration from '{}'", &config_path),
        )
    } else {
        (
            config_builder,
            format!("No configuration file found at '{}'", &config_path),
        )
    };

    // config:Environment::default() is used to override the configuration file with environment variables
    // Environment variables take precedence over config file settings
    // This is useful for Docker Compose, where we can set environment variables to override the configuration file
    // For example, we can set the DATABASE_URL, HTPASSWD, SSH_KEY, and SESSION_KEY environment variables to override the configuration file
    // This is also useful for development, where we can set the environment variables to override the configuration file
    // This is also useful for production, where we can set the environment variables to override the configuration file
    // This is also useful for testing, where we can set the environment variables to override the configuration file
    let mut config: Configuration = config_builder
        .add_source(config::Environment::default())
        .build()
        .unwrap_or_else(|e| {
            eprintln!("Error while reading configuration source: {e}");
            logging::AppLogger::log_config_error(&format!("Error while reading configuration source: {e}"), true);
            std::process::exit(3);
        })
        .try_deserialize()
        .unwrap_or_else(|e| {
            eprintln!("Error while parsing configuration: {e}");
            logging::AppLogger::log_config_error(&format!("Error while parsing configuration: {e}"), true);
            std::process::exit(3);
        });

    // Override with specific environment variables that don't follow config crate naming conventions
    if let Ok(htpasswd_path) = std::env::var("HTPASSWD") {
        config.htpasswd_path = std::path::PathBuf::from(htpasswd_path);
    }
    if let Ok(ssh_key_path) = std::env::var("SSH_KEY") {
        config.ssh.private_key_file = std::path::PathBuf::from(ssh_key_path);
    }
    if let Ok(session_key) = std::env::var("SESSION_KEY") {
        config.session_key = session_key;
    }

    (config, config_source)
}

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    color_eyre::install().expect("Couldn't intall color_eyre");

    if std::env::var("RUST_SPANTRACE").is_err() {
        std::env::set_var("RUST_SPANTRACE", "0");
    }

    let (configuration, config_source) = get_configuration();

    if env::var("RUST_LOG").is_err() {
        let loglevel = configuration.loglevel.clone();
        env::set_var("RUST_LOG", loglevel);
    }
    pretty_env_logger::init();
    logging::AppLogger::log_config_loaded(&config_source, 0); // We don't count keys loaded easily, so using 0

    // Log the resolved configuration paths
    info!("Using database: {}", configuration.database_url);
    info!("Using htpasswd file: {}", configuration.htpasswd_path.display());
    info!("Using SSH key file: {}", configuration.ssh.private_key_file.display());
    info!("Using log level: {}", configuration.loglevel);

    if !configuration.htpasswd_path.exists() {
        info!("htpasswd file not found, creating default admin user...");

        // Create directory if it doesn't exist
        if let Some(parent) = configuration.htpasswd_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                error!("Failed to create directory for htpasswd file: {}", e);
                std::process::exit(3);
            }
        }

        // Generate a random password
        let password: String = thread_rng()
            .sample_iter(&Alphanumeric)
            .take(16)
            .map(char::from)
            .collect();

        // Hash the password with bcrypt
        let hashed_password = bcrypt::hash(&password, bcrypt::DEFAULT_COST)
            .expect("Failed to hash password");

        // Write to htpasswd file in Apache format
        let htpasswd_content = format!("admin:{}\n", hashed_password);
        if let Err(e) = std::fs::write(&configuration.htpasswd_path, htpasswd_content) {
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

        info!("Created default admin user in htpasswd file: {:?}", configuration.htpasswd_path);
    }

    let database_url = configuration.database_url.clone();
    let manager = ConnectionManager::<DbConnection>::new(database_url);
    let pool: ConnectionPool = Pool::builder()
        .connection_customizer(Box::new(SqliteConnectionCustomizer))
        .build(manager)
        .expect("Database URL should be a valid URI");

    {
        use diesel::{sql_query, RunQueryDsl};

        logging::DatabaseLogger::log_connection_event("connecting", 0);
        let mut conn = pool.get().expect("Couldn't connect to database");

        sql_query("PRAGMA foreign_keys = on")
            .execute(&mut conn)
            .expect("Couldn't activate foreign key support");

        conn.run_pending_migrations(MIGRATIONS)
            .expect("Error while running migrations:");
    }

    let key_path = &configuration.ssh.private_key_file;

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
        eprintln!("mkdir -p {}", key_path.parent().unwrap().display());
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

    let key = load_secret_key(
        key_path,
        configuration.ssh.private_key_passphrase.as_deref(),
    )
    .expect("Failed to load private key:");

    let config = Data::new(configuration.clone());
    let ssh_client = SshClient::new(pool.clone(), key, configuration.ssh.clone());

    let caching_ssh_client = Data::new(CachingSshClient::new(pool.clone(), ssh_client.clone()));

    logging::AppLogger::log_startup("ssm", env!("CARGO_PKG_VERSION"));
    let secret_key = cookie::Key::derive_from(configuration.session_key.as_bytes());

    if let Some(scheduler_task) = scheduler::init_scheduler(
        configuration.ssh.check_schedule,
        configuration.ssh.update_schedule,
        Arc::clone(&caching_ssh_client),
    )
    .await
    {
        tokio::spawn(scheduler_task);
    };

    let server = HttpServer::new(move || {
        // Configure CORS for frontend
        let cors = Cors::default()
            .allowed_origin_fn(|origin, _req_head| {
                // Allow localhost development origins - return the specific origin, not "*"
                // This fixes login functionality when credentials are included
                if let Ok(origin_str) = origin.to_str() {
                    origin_str.starts_with("http://localhost:")
                        || origin_str.starts_with("https://localhost:")
                        || origin_str.starts_with("http://127.0.0.1:")
                        || origin_str.starts_with("https://127.0.0.1:")
                } else {
                    false
                }
            })
            .allowed_methods(vec!["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
            .allowed_headers(vec![
                header::AUTHORIZATION,
                header::ACCEPT,
                header::CONTENT_TYPE,
                actix_web::http::header::HeaderName::from_static("x-csrf-token"),
            ])
            .supports_credentials();

        App::new()
            .wrap(cors)
            .wrap(Logger::new("%a \"%r\" %s %b \"%{Referer}i\" \"%{User-Agent}i\" %T"))
            .wrap(middleware::CsrfProtection)      // Outermost - runs first
            .wrap(middleware::AuthEnforcement)     // Enforce authentication by default
            .wrap(IdentityMiddleware::default())   // Identity middleware needs to run before our auth middleware
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key.clone())
                    .cookie_name("ssm_session".to_owned())
                    .cookie_secure(std::env::var("HTTPS_ENABLED").is_ok()) // Only secure in HTTPS mode
                    .cookie_http_only(true)
                    .cookie_same_site(actix_web::cookie::SameSite::Lax)
                    .build(),
            )
            .app_data(Data::new(ssh_client.clone()))
            .app_data(caching_ssh_client.clone())
            .app_data(config.clone())
            .app_data(web::Data::new(pool.clone()))
            .configure(routes::route_config)
    })
    .bind((configuration.listen, configuration.port))?
    .run();

    info!("Server started successfully on {}:{}", configuration.listen, configuration.port);

    let result = server.await;

    // Log shutdown based on the result
    match &result {
        Ok(()) => {
            logging::AppLogger::log_shutdown("ssm", "server completed normally");
        }
        Err(e) => {
            logging::AppLogger::log_shutdown("ssm", &format!("server error: {}", e));
        }
    }

    result
}
