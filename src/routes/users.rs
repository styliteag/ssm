use actix_web::{
    get, post,
    web::{self, Data, Path},
    Responder,
};
use askama_actix::{Template, TemplateToResponse};
use serde::Deserialize;
use ssh_key::PublicKey;

use crate::{
    db::Authorization,
    forms::FormResponseBuilder,
    routes::{ErrorTemplate, RenderErrorTemplate},
    ConnectionPool,
};

use crate::models::{NewPublicUserKey, NewUser, PublicUserKey, User};

pub fn users_config(cfg: &mut web::ServiceConfig) {
    cfg.service(users_page)
        .service(render_users)
        .service(show_user)
        .service(render_user_keys)
        .service(add_user)
        .service(assign_key_to_user)
        .service(delete_user);
}

#[derive(Template)]
#[template(path = "users/index.html")]
struct UsersTemplate {}

#[get("")]
async fn users_page() -> impl Responder {
    UsersTemplate {}
}

#[derive(Template)]
#[template(path = "users/list.htm")]
struct RenderUsersTemplate {
    users: Vec<User>,
}

#[get("/list.htm")]
async fn render_users(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_users = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    Ok(match all_users {
        Ok(users) => RenderUsersTemplate { users }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "users/show_user.html")]
struct ShowUserTemplate {
    user: User,
    authorizations: Vec<Authorization>,
}
#[get("/{name}")]
async fn show_user(
    conn: Data<ConnectionPool>,
    user: Path<String>,
) -> actix_web::Result<impl Responder> {
    let mut conn2 = conn.clone().get().unwrap();
    let maybe_user = web::block(move || User::get_user(&mut conn2, user.to_string())).await?;

    Ok(match maybe_user {
        Ok(user) => {
            let user2 = user.clone();
            let authorizations =
                web::block(move || user2.get_authorizations(&mut conn.get().unwrap())).await?;

            match authorizations {
                Ok(authorizations) => ShowUserTemplate {
                    user,
                    authorizations,
                }
                .to_response(),
                Err(error) => ErrorTemplate { error }.to_response(),
            }
        }
        Err(error) => ErrorTemplate { error }.to_response(),
    })
}

#[post("/add")]
async fn add_user(
    conn: Data<ConnectionPool>,
    form: web::Form<NewUser>,
) -> actix_web::Result<impl Responder> {
    let new_user = form.0;

    let res = web::block(move || User::add_user(&mut conn.get().unwrap(), new_user)).await?;
    Ok(match res {
        Ok(_) => FormResponseBuilder::created(String::from("Added user"))
            .add_trigger(String::from("reload-users")),
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(Deserialize)]
struct DeleteUserForm {
    username: String,
}

#[post("/delete")]
async fn delete_user(
    conn: Data<ConnectionPool>,
    form: web::Form<DeleteUserForm>,
) -> actix_web::Result<impl Responder> {
    let username = form.0.username;

    let res =
        web::block(move || User::delete_user(&mut conn.get().unwrap(), username.as_str())).await?;
    Ok(match res {
        Ok(()) => FormResponseBuilder::success(String::from("Deleted user")),
        Err(e) => FormResponseBuilder::error(e),
    })
}
#[derive(Template)]
#[template(path = "users/list_keys.htm")]
struct ListUserKeysTemplate {
    keys: Vec<(PublicUserKey, Result<String, String>)>,
}

#[get("/{username}/list_keys.htm")]
async fn render_user_keys(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> actix_web::Result<impl Responder> {
    let maybe_user_keys = web::block(move || {
        let mut connection = conn.get().unwrap();
        let user = User::get_user(&mut connection, username.to_string())?;

        user.get_keys(&mut connection)
    })
    .await?;

    Ok(match maybe_user_keys {
        Ok(keys) => {
            let public_keys: Vec<(PublicUserKey, Result<String, String>)> = keys
                .into_iter()
                .map(|key| {
                    let fingerprint = PublicKey::try_from(&key)
                        .map(|k| k.fingerprint(ssh_key::HashAlg::Sha256).to_string());

                    (key, fingerprint)
                })
                .collect();
            ListUserKeysTemplate { keys: public_keys }.to_response()
        }
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Deserialize)]
struct AssignKeyDialogForm {
    user_id: i32,
    key_type: String,
    key_base64: String,
    key_comment: Option<String>,
}

#[post("/assign_key")]
async fn assign_key_to_user(
    conn: Data<ConnectionPool>,
    form: web::Form<AssignKeyDialogForm>,
) -> actix_web::Result<impl Responder> {
    let new_key = NewPublicUserKey {
        key_type: form.key_type.clone(),
        key_base64: form.key_base64.clone(),
        user_id: form.user_id,
        comment: form.key_comment.clone(),
    };

    let res = web::block(move || PublicUserKey::add_key(&mut conn.get().unwrap(), new_key)).await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::created(String::from("Added key"))
            .add_trigger("reloadDiff".to_owned()),
        Err(e) => FormResponseBuilder::error(e),
    })
}
