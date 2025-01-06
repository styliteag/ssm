use std::{env, fs, net::IpAddr, path::PathBuf};

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
use log::info;
use serde::Deserialize;
use sshclient::SshClient;

use diesel::r2d2::ConnectionManager;
use diesel::r2d2::Pool;

use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
use russh::keys::decode_secret_key;

mod db;
mod forms;
mod middleware;
mod models;
mod routes;
mod schema;
mod sshclient;
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

#[derive(Debug, Deserialize, Clone)]
pub struct SshConfig {
    /// Path to an OpenSSH Private Key
    private_key_file: PathBuf,
    /// Passphrase for the key
    private_key_passphrase: Option<String>,
}

fn default_database_url() -> String {
    "sqlite://ssm.db".to_owned()
}

fn default_listen() -> IpAddr {
    use core::net::Ipv6Addr;
    IpAddr::V6(Ipv6Addr::UNSPECIFIED)
}

fn default_port() -> u16 {
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

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    color_eyre::install().expect("Couldn't intall color_eyre");

    if std::env::var("RUST_SPANTRACE").is_err() {
        std::env::set_var("RUST_SPANTRACE", "0");
    }

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

    let configuration: Configuration = config_builder
        .add_source(config::Environment::default())
        .build()
        .unwrap_or_else(|e| {
            eprintln!(
                "Error while reading configuration source: {}",
                e.to_string()
            );
            std::process::exit(3);
        })
        .try_deserialize()
        .unwrap_or_else(|e| {
            eprintln!("Error while parsing configuration: {}", e.to_string());
            std::process::exit(3);
        });

    if env::var("RUST_LOG").is_err() {
        let loglevel = configuration.loglevel.clone();
        env::set_var("RUST_LOG", loglevel);
    }
    pretty_env_logger::init();
    info!("{}", config_source);

    let database_url = configuration.database_url.clone();
    let manager = ConnectionManager::<DbConnection>::new(database_url);
    let pool: ConnectionPool = Pool::builder()
        .build(manager)
        .expect("Database URL should be a valid URI");

    {
        use diesel::{sql_query, RunQueryDsl};

        info!("Trying to run migrations");
        let mut conn = pool.get().expect("Cant connect to database");

        sql_query("PRAGMA foreign_keys = on")
            .execute(&mut conn)
            .expect("Couldn't activate foreign key support");

        conn.run_pending_migrations(MIGRATIONS)
            .expect("Error while running migrations:");
    }

    let key = decode_secret_key(
        fs::read_to_string(configuration.ssh.private_key_file.clone())
            .expect("Couldn't read private key file")
            .as_str(),
        configuration.ssh.private_key_passphrase.as_deref(),
    )
    .expect("Couldn't decipher private key");

    let ssh_client = Data::new(SshClient::new(pool.clone(), key));
    let config = Data::new(configuration.clone());

    info!("Starting Secure SSH Manager");
    let secret_key = cookie::Key::derive_from(configuration.session_key.as_bytes());

    HttpServer::new(move || {
        let generated = generate();

        App::new()
            .wrap(middleware::AuthMiddleware)
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key.clone())
                    .cookie_name("ssm_session".to_string())
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
            .app_data(ssh_client.clone())
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
