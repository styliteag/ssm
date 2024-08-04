use std::{env, path::PathBuf};

use actix_files::Files;
use actix_web::{
    web::{self, Data},
    App, HttpServer,
};
use config::Config;
use diesel::prelude::QueryResult;
use log::{error, info};
use serde::Deserialize;
use sshclient::SshClient;

use async_ssh2_tokio::AuthMethod::PrivateKeyFile;

use diesel::r2d2::ConnectionManager;
use diesel::r2d2::Pool;

use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};

mod db;
mod models;
mod routes;
mod schema;
mod sshclient;

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

#[derive(Debug, Deserialize)]
pub struct SshConfig {
    /// Path to an OpenSSH Private Key
    private_key_file: PathBuf,
    /// Passphrase for the key
    private_key_passphrase: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Configuration {
    ssh: SshConfig,
    database_url: String,
}

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    color_eyre::install().expect("Couldn't intall color_eyre");

    if std::env::var("RUST_SPANTRACE").is_err() {
        std::env::set_var("RUST_SPANTRACE", "0");
    }
    if env::var("RUST_LOG").is_err() {
        env::set_var("RUST_LOG", "warn");
    }
    pretty_env_logger::init();

    // Load configuration
    let config_path = env::var("CONFIG").unwrap_or_else(|_| String::from("./config.toml"));
    let configuration: Configuration = Config::builder()
        .add_source(config::File::with_name(config_path.as_str()))
        .add_source(config::Environment::default())
        .set_default("database_url", String::from("sqlite://ssm.db"))
        .expect("String::from always returns a String.")
        .build()
        .unwrap_or_else(|e| {
            error!(
                "Error while reading configuration source: {}",
                e.to_string()
            );
            std::process::exit(3);
        })
        .try_deserialize()
        .unwrap_or_else(|e| {
            error!("Error while parsing configuration: {}", e.to_string());
            std::process::exit(3);
        });

    let manager = ConnectionManager::<DbConnection>::new(configuration.database_url);
    let pool: ConnectionPool = Pool::builder()
        .build(manager)
        .expect("Database URL should be a valid URI");

    {
        info!("Trying to run migrations");
        pool.get()
            .expect("Cant connect to database.")
            .run_pending_migrations(MIGRATIONS)
            .expect("Error while running migrations:");
    }

    let ssh_client = Data::new(SshClient::new(
        pool.clone(),
        PrivateKeyFile {
            key_file_path: configuration.ssh.private_key_file,
            key_pass: configuration.ssh.private_key_passphrase,
        },
    ));

    info!("Starting ssh-key-manager Server");
    HttpServer::new(move || {
        App::new()
            .app_data(ssh_client.clone())
            .app_data(web::Data::new(pool.clone()))
            .service(routes::index)
            .service(routes::hosts)
            .service(routes::users)
            .service(routes::show_user)
            .service(routes::render_user_keys)
            .service(routes::add_user)
            .service(routes::show_host)
            .service(routes::render_hosts)
            .service(routes::add_host)
            // .service(routes::render_host_keys)
            .service(routes::list_keys)
            .service(routes::assign_key_to_user)
            .service(routes::diff)
            .service(routes::render_diff)
            .service(routes::authorize_user)
            .service(Files::new("/", "./static"))
            .default_service(web::to(routes::not_found))
    })
    // TODO: make address and port configurable
    .bind(("0.0.0.0", 8080))?
    .run()
    .await
}
