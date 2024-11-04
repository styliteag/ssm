use std::str::FromStr;

use diesel::result::Error;
use log::error;
use ssh_key::{authorized_keys::ConfigOpts, Algorithm};

use crate::{models::PublicUserKey, sshclient::AuthorizedKey};

mod host;
mod key;
mod user;

/// Username, user on host and ssh options
pub type UserAndOptions = (String, String, Option<String>);

/// A fictional authorized_keys entry for an allowed user
#[derive(Clone, Debug)]
pub struct AllowedUserOnHost {
    /// The Public key
    pub key: PublicUserKey,
    /// Which user this entry is for
    pub user_on_host: String,
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
                .and_then(|opts| ConfigOpts::new(opts).ok())
                .expect("Checked on db entry"),
            algorithm: Algorithm::from_str(value.key.key_type.as_str())
                .expect("Checked on db entry"),
            base64: value.key.key_base64,
            comment: value.key.comment,
        }
    }
}

impl From<(PublicUserKey, String, String, Option<String>)> for AllowedUserOnHost {
    fn from(value: (PublicUserKey, String, String, Option<String>)) -> Self {
        AllowedUserOnHost {
            key: value.0,
            user_on_host: value.1,
            username: value.2,
            options: value.3,
        }
    }
}

/// Username and one associated key
pub type UsernameAndKey = (String, PublicUserKey);

/// A list of allowed hosts for a user: name, user on host, options
pub type Authorization = (String, String, Option<String>);

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
