use diesel::result::Error;
use log::error;

mod host;
mod key;
mod user;

pub fn query<T>(query_result: Result<T, Error>) -> Result<T, String> {
    query_result.map_err(|e| {
        let error = e.to_string();
        error!("Error trying to execute sql query: {}", error);
        error
    })
}
