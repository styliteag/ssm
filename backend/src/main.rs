use std::{env, sync::Arc};
use actix_web::web::Data;
use cookie::Key;
use log::info;
use ssh::{CachingSshClient, SshClient};

use diesel::r2d2::{ConnectionManager, Pool};

use diesel_migrations::{embed_migrations, EmbeddedMigrations};

mod activity_logger;
mod api_types;
mod auth_setup;
mod config;
mod database;
mod db;
mod logging;
mod middleware;
mod models;
mod openapi;
mod routes;
mod scheduler;
mod schema;
mod server;
mod ssh;
mod ssh_setup;

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

// Re-export configuration types for use in other modules
pub use config::{Configuration, SshConfig};

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    color_eyre::install().map_err(|e| {
        eprintln!("Failed to install color_eyre: {}", e);
        std::io::Error::new(std::io::ErrorKind::Other, format!("Failed to install color_eyre: {}", e))
    })?;

    if std::env::var("RUST_SPANTRACE").is_err() {
        std::env::set_var("RUST_SPANTRACE", "0");
    }

    // Load configuration
    let (configuration, config_source) = config::get_configuration()
        .map_err(|e| {
            eprintln!("Configuration error: {}", e);
            std::io::Error::new(std::io::ErrorKind::InvalidInput, e)
        })?;

    // Validate session key is set
    let session_key = configuration.session_key.clone()
        .or_else(|| env::var("SESSION_KEY").ok())
        .ok_or_else(|| {
            let error_msg = "SESSION_KEY environment variable must be set for security. Please set it via environment variable or config file.";
            eprintln!("{}", error_msg);
            std::io::Error::new(std::io::ErrorKind::InvalidInput, error_msg)
        })?;

    // Initialize logging
    if env::var("RUST_LOG").is_err() {
        let loglevel = configuration.loglevel.clone();
        env::set_var("RUST_LOG", loglevel);
    }
    pretty_env_logger::init();
    logging::AppLogger::log_config_loaded(&config_source, 0);

    // Log the resolved configuration paths
    info!("Using database: {}", configuration.database_url);
    info!("Using htpasswd file: {}", configuration.htpasswd_path.display());
    info!("Using SSH key file: {}", configuration.ssh.private_key_file.display());
    info!("Using log level: {}", configuration.loglevel);

    // Ensure authentication file exists
    auth_setup::ensure_htpasswd_file(&configuration.htpasswd_path)?;

    // Setup database
    let pool = database::create_connection_pool(configuration.database_url.clone())?;

    // Load SSH key
    let key = ssh_setup::validate_and_load_ssh_key(
        &configuration.ssh.private_key_file,
        configuration.ssh.private_key_passphrase.as_deref(),
    )?;

    // Initialize SSH clients
    let config_data = Data::new(configuration.clone());
    let ssh_client = SshClient::new(pool.clone(), key, configuration.ssh.clone());
    let caching_ssh_client = Data::new(CachingSshClient::new(pool.clone(), ssh_client.clone()));

    logging::AppLogger::log_startup("ssm", env!("CARGO_PKG_VERSION"));
    let secret_key = Key::derive_from(session_key.as_bytes());

    // Initialize scheduler if configured
    let check_schedule = configuration.ssh.check_schedule.clone();
    let update_schedule = configuration.ssh.update_schedule.clone();
    if let Some(scheduler_task) = scheduler::init_scheduler(
        check_schedule,
        update_schedule,
        Arc::clone(&caching_ssh_client),
    )
    .await
    {
        tokio::spawn(scheduler_task);
    }

    // Start HTTP server
    server::start_server(
        &configuration,
        pool,
        Data::new(ssh_client),
        caching_ssh_client,
        config_data,
        secret_key,
    )
    .await
}
