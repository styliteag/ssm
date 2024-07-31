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

/// Same thing as query, but drops Ok type
pub fn query_drop<T>(query_result: Result<T, Error>) -> Result<(), String> {
    query(query_result).map(|_| ())
}
