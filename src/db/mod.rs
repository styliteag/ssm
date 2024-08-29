use diesel::result::Error;
use log::error;

use crate::models::PublicUserKey;

mod host;
mod key;
mod user;

/// Username and ssh options
pub type UserAndOptions = (String, Option<String>);

/// Publickey and the associated options
pub type UserkeyAndOptions = (PublicUserKey, Option<String>);

/// Username and one associated key
pub type UsernameAndKey = (String, PublicUserKey);

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
