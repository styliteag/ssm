use actix_web::{
    get,
    web::{self, Data},
    Responder,
};
use askama_actix::{Template, TemplateToResponse};

use crate::{db::UsernameAndKey, routes::ErrorTemplate, ConnectionPool};

use crate::models::PublicUserKey;

pub fn keys_config(cfg: &mut web::ServiceConfig) {
    cfg.service(list_keys);
}

#[derive(Template)]
#[template(path = "keys/index.html")]
struct KeysPageTemplate {
    keys: Vec<UsernameAndKey>,
}

#[get("")]
pub async fn list_keys(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_keys =
        web::block(move || PublicUserKey::get_all_keys_with_username(&mut conn.get().unwrap()))
            .await?;

    Ok(match all_keys {
        Ok(keys) => KeysPageTemplate { keys }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    })
}
