use std::env;

use actix_files::Files;
use actix_web::{
    web::{self, Data},
    App, HttpRequest, HttpResponse, HttpServer, Responder,
};
use diesel::prelude::QueryResult;
use diesel::{Connection, SqliteConnection};
use log::{info, warn};
use sshclient::SshClient;

use async_ssh2_tokio::AuthMethod::PrivateKeyFile;

use diesel::r2d2::ConnectionManager;
use diesel::r2d2::Pool;

mod db;
mod models;
mod routes;
mod schema;
mod sshclient;

#[derive(diesel::MultiConnection)]
pub enum DbConnection {
    Postgresql(diesel::PgConnection),
    Sqlite(diesel::SqliteConnection),
}

pub type ConnectionPool = Pool<ConnectionManager<DbConnection>>;

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

    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| {
        let database_url = "sqlite://ssm.db";
        warn!("No database url set. Falling back to {}", database_url);
        database_url.to_owned()
    });

    let manager = ConnectionManager::<DbConnection>::new(database_url);
    let pool: ConnectionPool = Pool::builder()
        .build(manager)
        .expect("database URL should be valid path to SQLite DB file");

    let ssh_client = Data::new(SshClient::new(
        pool.clone(),
        PrivateKeyFile {
            key_file_name: "/home/jeidnx/.ssh/stylite-test".to_owned(),
            key_pass: None,
        },
        "root".to_owned(),
    ));

    info!("Starting server");
    HttpServer::new(move || {
        App::new()
            .app_data(ssh_client.clone())
            .app_data(web::Data::new(pool.clone()))
            .service(routes::index)
            .service(routes::hosts)
            .service(routes::users)
            .service(routes::show_user)
            .service(routes::render_user_keys)
            .service(routes::show_host)
            .service(routes::render_hosts)
            .service(routes::add_host)
            .service(routes::render_host_keys)
            .service(routes::list_keys)
            .service(Files::new("/", "./static").use_last_modified(true))
            .default_service(web::to(routes::not_found))
    })
    .bind(("127.0.0.1", 8080))?
    .run()
    .await
}
