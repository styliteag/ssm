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
use ssh::{CachingSshClient, SshClient};

use diesel::r2d2::ConnectionManager;
use diesel::r2d2::Pool;

use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
use russh::keys::load_secret_key;

mod api_types;
mod db;
mod middleware;
mod models;
mod openapi;
mod routes;
mod scheduler;
mod schema;
mod ssh;

#[cfg(test)]
mod tests;

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!();

#[derive(diesel::MultiConnection)]
pub enum DbConnection {
    #[cfg(feature = "postgres")]
    Postgresql(diesel::PgConnection),
    #[cfg(feature = "mysql")]
    Mysql(diesel::MysqlConnection),

    Sqlite(diesel::SqliteConnection),
}

pub type ConnectionPool = Pool<ConnectionManager<DbConnection>>;

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
    8080
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

#[derive(Debug, Deserialize, Clone)]
pub struct Configuration {
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

    (
        config_builder
            .add_source(config::Environment::default())
            .build()
            .unwrap_or_else(|e| {
                eprintln!("Error while reading configuration source: {e}");
                std::process::exit(3);
            })
            .try_deserialize()
            .unwrap_or_else(|e| {
                eprintln!("Error while parsing configuration: {e}");
                std::process::exit(3);
            }),
        config_source,
    )
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
    info!("{}", config_source);

    if !configuration.htpasswd_path.exists() {
        error!(
            "htpasswd file does not exist: {:?}",
            configuration.htpasswd_path
        );
        std::process::exit(3);
    }

    let database_url = configuration.database_url.clone();
    let manager = ConnectionManager::<DbConnection>::new(database_url);
    let pool: ConnectionPool = Pool::builder()
        .build(manager)
        .expect("Database URL should be a valid URI");

    {
        use diesel::{sql_query, RunQueryDsl};

        info!(
            "Trying to connect to database '{}'",
            configuration.database_url
        );
        let mut conn = pool.get().expect("Couldn't connect to database");

        sql_query("PRAGMA foreign_keys = on")
            .execute(&mut conn)
            .expect("Couldn't activate foreign key support");

        conn.run_pending_migrations(MIGRATIONS)
            .expect("Error while running migrations:");
    }

    let key_path = &configuration.ssh.private_key_file;

    let key = load_secret_key(
        key_path,
        configuration.ssh.private_key_passphrase.as_deref(),
    )
    .expect("Failed to load private key:");

    let config = Data::new(configuration.clone());
    let ssh_client = SshClient::new(pool.clone(), key, configuration.ssh.clone());

    let caching_ssh_client = Data::new(CachingSshClient::new(pool.clone(), ssh_client.clone()));

    info!("Starting Secure SSH Manager");
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

    HttpServer::new(move || {
        // Configure CORS for frontend
        let cors = Cors::default()
            .allowed_origin("http://localhost:3000") // React dev server
            .allowed_origin("http://localhost:5173") // Vite dev server
            .allowed_origin("http://127.0.0.1:3000")
            .allowed_origin("http://127.0.0.1:5173")
            .allowed_methods(vec!["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
            .allowed_headers(vec![
                header::AUTHORIZATION,
                header::ACCEPT,
                header::CONTENT_TYPE,
            ])
            .supports_credentials();

        App::new()
            .wrap(cors)
            .wrap(Logger::new("%a \"%r\" %s %b \"%{Referer}i\" \"%{User-Agent}i\" %T"))
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key.clone())
                    .cookie_name("ssm_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(Data::new(ssh_client.clone()))
            .app_data(caching_ssh_client.clone())
            .app_data(config.clone())
            .app_data(web::Data::new(pool.clone()))
            .configure(routes::route_config)
    })
    .bind((configuration.listen, configuration.port))?
    .run()
    .await
}
