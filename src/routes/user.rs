use actix_web::{
    get, post,
    web::{self, Data, Path},
    Responder,
};
use askama_actix::{Template, TemplateToResponse};
use log::error;
use serde::Deserialize;

use crate::{
    db::UserAndOptions,
    forms::FormResponseBuilder,
    routes::{ErrorTemplate, RenderErrorTemplate},
    ssh::SshPublicKey,
    ConnectionPool,
};

use crate::models::{NewPublicUserKey, NewUser, PublicUserKey, User};

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(users_page)
        .service(render_users)
        .service(select_users)
        .service(render_user_keys)
        .service(list_user_authorizations)
        .service(add_user)
        .service(assign_key_to_user)
        .service(delete_user)
        .service(add_user_dialog)
        .service(edit_user)
        .service(add_key_dialog)
        .service(show_user);
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
#[template(path = "users/selection_list.htm")]
struct UserSelectionTemplate {
    users: Vec<User>,
}

#[get("/select.htm")]
async fn select_users(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_users = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    Ok(match all_users {
        Ok(users) => UserSelectionTemplate { users }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "users/show_user.html")]
struct ShowUserTemplate {
    user: User,
}

#[get("/{name}")]
async fn show_user(
    conn: Data<ConnectionPool>,
    user: Path<String>,
) -> actix_web::Result<impl Responder> {
    let mut conn = conn.clone().get().unwrap();
    let maybe_user = web::block(move || User::get_user(&mut conn, user.to_string())).await?;

    Ok(match maybe_user {
        Ok(user) => ShowUserTemplate { user }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "users/add_dialog.htm")]
struct AddUserDialog {}

#[get("/add_dialog")]
async fn add_user_dialog() -> impl Responder {
    error!("User dialog handler");
    FormResponseBuilder::dialog("Add a user", "/user/add", AddUserDialog {})
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
        Ok(()) => {
            FormResponseBuilder::success(String::from("Deleted user")).add_trigger("reload-users")
        }
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
                    let fingerprint = russh::keys::PublicKey::try_from(&key)
                        .map(|k| k.fingerprint(russh::keys::HashAlg::Sha256).to_string());

                    (key, fingerprint)
                })
                .collect();
            ListUserKeysTemplate { keys: public_keys }.to_response()
        }
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "users/list_authorizations.htm")]
struct ListUserAuthorizationsTemplate {
    authorizations: Vec<UserAndOptions>,
}

#[get("/{username}/list_authorizations.htm")]
async fn list_user_authorizations(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> actix_web::Result<impl Responder> {
    let maybe_user_auth = web::block(move || {
        let mut connection = conn.get().unwrap();
        let user = User::get_user(&mut connection, username.to_string())?;

        user.get_authorizations(&mut connection)
    })
    .await?;

    Ok(match maybe_user_auth {
        Ok(authorizations) => ListUserAuthorizationsTemplate { authorizations }.to_response(),
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
    let Ok(algo) = russh::keys::Algorithm::new(&form.key_type) else {
        return Ok(FormResponseBuilder::error(
            "Invalid key algorithm".to_owned(),
        ));
    };

    let new_key = NewPublicUserKey::new(
        algo,
        form.key_base64.clone(),
        form.key_comment.clone(),
        form.user_id,
    );

    let res = web::block(move || PublicUserKey::add_key(&mut conn.get().unwrap(), new_key)).await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::created(String::from("Added key"))
            .add_trigger("reloadDiff".to_owned()),
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(Deserialize)]
struct EditUserForm {
    old_username: String,
    new_username: String,
    enabled: bool,
}

#[post("/edit")]
async fn edit_user(
    conn: Data<ConnectionPool>,
    form: web::Form<EditUserForm>,
) -> actix_web::Result<impl Responder> {
    let mut conn = conn.get().unwrap();
    match User::update_user(
        &mut conn,
        &form.old_username,
        &form.new_username,
        form.enabled,
    ) {
        Ok(_) => {
            let response = actix_web::HttpResponse::Found()
                .insert_header(("Location", format!("/user/{}", form.new_username)))
                .finish();
            Ok(response)
        }
        Err(error) => Ok(FormResponseBuilder::error(error)
            .add_trigger("reload".to_owned())
            .into_response()),
    }
}

#[derive(Template)]
#[template(path = "diff/assign_key_dialog.htm")]
struct AddKeyDialog {
    key: SshPublicKey,
}

#[post("/add_key")]
async fn add_key_dialog(key: web::Form<SshPublicKey>) -> impl Responder {
    FormResponseBuilder::dialog(
        "Assign this key to a user",
        "/user/assign_key",
        AddKeyDialog { key: key.0 },
    )
}
