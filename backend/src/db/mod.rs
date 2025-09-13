use std::str::FromStr;

use diesel::result::Error;
use log::error;
use russh::keys::{ssh_key::authorized_keys::ConfigOpts, Algorithm};
use serde::Serialize;
use utoipa::ToSchema;

use crate::{models::PublicUserKey, ssh::AuthorizedKey};

mod host;
pub mod key;
mod user;

/// User authorization information with SSH options
#[derive(Serialize, serde::Deserialize, Debug, ToSchema)]
pub struct UserAndOptions {
    /// Authorization ID
    pub id: i32,
    /// Username
    pub username: String,
    /// Login account
    pub login: String,
    /// SSH key options
    pub options: Option<String>,
    /// Optional comment for this authorization
    pub comment: Option<String>,
}

impl From<(i32, String, String, Option<String>, Option<String>)> for UserAndOptions {
    fn from(value: (i32, String, String, Option<String>, Option<String>)) -> Self {
        Self {
            id: value.0,
            username: value.1,
            login: value.2,
            options: value.3,
            comment: value.4,
        }
    }
}

/// A fictional authorized_keys entry for an allowed user
#[derive(Clone, Debug)]
pub struct AllowedUserOnHost {
    /// The Public key
    pub key: PublicUserKey,
    /// Which user this entry is for
    pub login: String,
    /// The key-manager username
    pub username: String,
    /// Key options, if set
    pub options: Option<String>,
}

impl From<AllowedUserOnHost> for AuthorizedKey {
    fn from(value: AllowedUserOnHost) -> Self {
        Self {
            options: value
                .options
                .map(|opts| ConfigOpts::new(opts).expect("Encountered invalid key"))
                .unwrap_or_default(),

            algorithm: Algorithm::from_str(value.key.key_type.as_str())
                .expect("Key algorithm in database is invalid"),
            base64: value.key.key_base64,
            comment: value.key.name,
        }
    }
}

impl From<(PublicUserKey, String, String, Option<String>)> for AllowedUserOnHost {
    fn from(value: (PublicUserKey, String, String, Option<String>)) -> Self {
        Self {
            key: value.0,
            login: value.1,
            username: value.2,
            options: value.3,
        }
    }
}

/// Username and one associated key
pub type UsernameAndKey = (String, PublicUserKey);

/// List of authorized_keys files
pub type AuthorizedKeysList = Vec<AllowedUserOnHost>;

/// Prints database Errors and returns a generic String
pub fn query<T>(query_result: Result<T, Error>) -> Result<T, String> {
    query_result.map_err(|e| {
        error!("Encountered a database error: {}", e);
        String::from("A database error occured. Please consult the logs.")
    })
}

/// Check usize and return an error when no entries were changed. Drops OK type
pub fn query_drop(query_result: Result<usize, Error>) -> Result<(), String> {
    match &query_result {
        Ok(rows) => match rows {
            0 => Err(String::from("Record not found.")),
            _ => Ok(()),
        },
        Err(_) => query(query_result).map(|_| ()),
    }
}
