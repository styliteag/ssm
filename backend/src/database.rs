use diesel::r2d2::{ConnectionManager, CustomizeConnection, Pool};
use diesel_migrations::MigrationHarness;
use log::error;

use crate::ConnectionPool;
use crate::DbConnection;
use crate::MIGRATIONS;

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

pub fn create_connection_pool(database_url: String) -> Result<ConnectionPool, std::io::Error> {
    let manager = ConnectionManager::<DbConnection>::new(database_url);
    let pool: ConnectionPool = Pool::builder()
        .connection_customizer(Box::new(SqliteConnectionCustomizer))
        .build(manager)
        .map_err(|e| {
            error!("Failed to create database connection pool: {}", e);
            std::io::Error::new(std::io::ErrorKind::ConnectionRefused, format!("Database URL should be a valid URI: {}", e))
        })?;

    {
        use diesel::{sql_query, RunQueryDsl};

        crate::logging::DatabaseLogger::log_connection_event("connecting", 0);
        let mut conn = pool.get().map_err(|e| {
            error!("Couldn't connect to database: {}", e);
            std::io::Error::new(std::io::ErrorKind::ConnectionRefused, format!("Couldn't connect to database: {}", e))
        })?;

        sql_query("PRAGMA foreign_keys = on")
            .execute(&mut conn)
            .map_err(|e| {
                error!("Couldn't activate foreign key support: {}", e);
                std::io::Error::new(std::io::ErrorKind::Other, format!("Couldn't activate foreign key support: {}", e))
            })?;

        conn.run_pending_migrations(MIGRATIONS)
            .map_err(|e| {
                error!("Error while running migrations: {}", e);
                std::io::Error::new(std::io::ErrorKind::Other, format!("Error while running migrations: {}", e))
            })?;
    }

    Ok(pool)
}

