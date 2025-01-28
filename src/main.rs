use std::{env, net::IpAddr, path::PathBuf, sync::Arc, time::Duration};

use actix_identity::IdentityMiddleware;
use actix_session::{storage::CookieSessionStore, SessionMiddleware};
use actix_web::{
    dev::ServiceResponse,
    http::{header, StatusCode},
    middleware::{ErrorHandlerResponse, ErrorHandlers},
    web::{self, Data},
    App, HttpResponse, HttpServer,
};
use actix_web_static_files::ResourceFiles;
use config::Config;
use diesel::prelude::QueryResult;
use log::{error, info};
use serde::Deserialize;
use ssh::{CachingSshClient, SshClient};

use diesel::r2d2::ConnectionManager;
use diesel::r2d2::Pool;

use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
use russh::keys::key::PrivateKeyWithHashAlg;
use ssh_key::PrivateKey;

mod db;
mod forms;
mod middleware;
mod models;
mod routes;
mod schema;
mod ssh;
mod templates;

include!(concat!(env!("OUT_DIR"), "/generated.rs"));

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

#[derive(Debug, Deserialize, Clone)]
pub struct SshConfig {
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
    String::from("my-secret-key-please-change-me-in-production")
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

    let mut key =
        PrivateKey::read_openssh_file(key_path).expect("Failed to read key from '{key_path}'.");

    if let Some(key_passphrase) = configuration.ssh.private_key_passphrase.as_ref() {
        key = match key.decrypt(key_passphrase) {
            Ok(k) => k,
            Err(ssh_key::Error::Decrypted) => {
                error!("Tried to decrypt ssh key, but it is already decrypted.");
                std::process::exit(4);
            }
            Err(e) => {
                error!("Failed to decrypt ssh key: {e}");
                std::process::exit(3);
            }
        };
    };

    let hash = match key.algorithm() {
        ssh_key::Algorithm::Rsa { hash } => hash,
        _ => None,
    };

    // TODO: maybe a better error message
    let key = PrivateKeyWithHashAlg::new(Arc::new(key), hash)
        .expect("Failed to convert key to Private key");

    let config = Data::new(configuration.clone());
    let ssh_client = SshClient::new(pool.clone(), key, configuration.ssh);

    let caching_ssh_client = Data::new(CachingSshClient::new(pool.clone(), ssh_client.clone()));

    info!("Starting Secure SSH Manager");
    let secret_key = cookie::Key::derive_from(configuration.session_key.as_bytes());

    HttpServer::new(move || {
        let generated = generate();

        App::new()
            .wrap(middleware::AuthMiddleware)
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key.clone())
                    .cookie_name("ssm_session".to_owned())
                    .cookie_secure(false) // Set to true in production
                    .cookie_http_only(true)
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .wrap(
                ErrorHandlers::new().handler(StatusCode::UNAUTHORIZED, |res: ServiceResponse| {
                    let req = res.request().clone();
                    let response = HttpResponse::Found()
                        .insert_header((header::LOCATION, "/auth/login"))
                        .finish();
                    Ok(ErrorHandlerResponse::Response(ServiceResponse::new(
                        req,
                        response.map_into_left_body(),
                    )))
                }),
            )
            .app_data(Data::new(ssh_client.clone()))
            .app_data(caching_ssh_client.clone())
            .app_data(config.clone())
            .app_data(web::Data::new(pool.clone()))
            .service(ResourceFiles::new("/", generated).skip_handler_when_not_found())
            .service(web::scope("/auth").configure(routes::auth::auth_config))
            .configure(routes::route_config)
    })
    .bind((configuration.listen, configuration.port))?
    .run()
    .await
}
