use actix_web::{
    get, post,
    web::{self, Data},
    Responder,
};
use askama_actix::{Template, TemplateToResponse};
use serde::Deserialize;

use crate::{
    db::UsernameAndKey, forms::FormResponseBuilder, routes::ErrorTemplate, ConnectionPool,
};

use crate::models::PublicUserKey;

pub fn keys_config(cfg: &mut web::ServiceConfig) {
    cfg.service(list_keys).service(delete);
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

#[derive(Deserialize)]
struct DeleteKeyForm {
    id: i32,
}

#[post("delete")]
pub async fn delete(
    conn: Data<ConnectionPool>,
    form: web::Form<DeleteKeyForm>,
) -> actix_web::Result<impl Responder> {
    let res =
        web::block(move || PublicUserKey::delete_key(&mut conn.get().unwrap(), form.id)).await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::success("Deleted key".to_owned())
            .add_trigger("reload-keys".to_owned())
            .into_response(),
        Err(e) => FormResponseBuilder::error(e).into_response(),
    })
}
