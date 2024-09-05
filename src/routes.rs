use actix_web::{
    body::BoxBody,
    get,
    http::StatusCode,
    post,
    web::{self, Data, Path},
    HttpResponse, HttpResponseBuilder, Responder,
};
use askama_actix::{Template, TemplateToResponse};
use log::debug;
use serde::Deserialize;

use crate::{
    db::{UserAndOptions, UsernameAndKey},
    forms::{FormResponseBuilder, Modal},
    sshclient::{ConnectionDetails, HostDiff, SshClient, SshPublicKey},
    ConnectionPool, DbConnection,
};

use crate::models::{Host, NewHost, NewPublicUserKey, NewUser, PublicUserKey, User};

#[derive(Template)]
#[template(path = "error.html")]
struct ErrorTemplate {
    error: String,
}

#[derive(Template)]
#[template(path = "render/error.html")]
struct RenderErrorTemplate {
    error: String,
}

#[derive(Template)]
#[template(path = "pages/404.html")]
struct NotFoundTemplate {}

pub async fn not_found() -> impl Responder {
    NotFoundTemplate {}
        .customize()
        .with_status(StatusCode::NOT_FOUND)
}

#[derive(Template)]
#[template(path = "pages/index.html")]
struct IndexTemplate {}

#[get("/")]
pub async fn index() -> impl Responder {
    IndexTemplate {}
}

#[derive(Template)]
#[template(path = "pages/users.html")]
struct UsersTemplate {}

#[get("/users")]
pub async fn users_page() -> impl Responder {
    UsersTemplate {}
}

#[derive(Template)]
#[template(path = "render/list_users.html")]
struct RenderUsersTemplate {
    users: Vec<User>,
}

#[get("/render/users")]
pub async fn render_users(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_users = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    Ok(match all_users {
        Ok(users) => RenderUsersTemplate { users }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "pages/show_user.html")]
struct ShowUserTemplate {
    user: User,
}
#[get("/users/{name}")]
pub async fn show_user(
    conn: Data<ConnectionPool>,
    user: Path<String>,
) -> actix_web::Result<impl Responder> {
    let maybe_user =
        web::block(move || User::get_user(&mut conn.get().unwrap(), user.to_string())).await?;

    Ok(match maybe_user {
        Ok(user) => ShowUserTemplate { user }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    })
}

#[post("/users/add")]
pub async fn add_user(
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
    confirm: Option<bool>,
}

#[derive(Template)]
#[template(path = "forms/delete_user_dialog.html")]
struct DeleteUserDialog {
    username: String,
}

#[post("/users/delete")]
pub async fn delete_user(
    conn: Data<ConnectionPool>,
    form: web::Form<DeleteUserForm>,
) -> actix_web::Result<impl Responder> {
    let username = form.0.username;
    let confirmation = form.0.confirm.is_some_and(|c| c);

    if confirmation {
        let res =
            web::block(move || User::delete_user(&mut conn.get().unwrap(), username.as_str()))
                .await?;
        Ok(match res {
            Ok(()) => FormResponseBuilder::success(String::from("Deleted user")),
            Err(e) => FormResponseBuilder::error(e),
        })
    } else {
        Ok(FormResponseBuilder::dialog(Modal {
            title: String::from("Are you sure you want to delete this user?"),
            request_target: String::from("/users/delete"),
            template: DeleteUserDialog { username }.to_string(),
        }))
    }
}

#[derive(Template)]
#[template(path = "forms/remove_key_dialog.html")]
struct RemoveKeyDialog {
    key: SshPublicKey,
}

#[derive(Deserialize)]
struct RemoveKeyDialogForm {
    host_name: String,
    #[serde(flatten)]
    key: SshPublicKey,
}

#[post("/render/diff/remove_key")]
pub async fn remove_key_dialog(form: web::Form<RemoveKeyDialogForm>) -> impl Responder {
    let host_name = form.0.host_name;

    FormResponseBuilder::dialog(Modal {
        title: format!("Remove this key from '{}'", host_name),
        request_target: format!("/hosts/{}/remove_key", host_name),
        template: RemoveKeyDialog { key: form.0.key }.to_string(),
    })
}

#[derive(Deserialize)]
struct RemoveKeyFromHostForm {
    key_base64: String,
}

#[post("/hosts/{name}/remove_key")]
pub async fn remove_key_from_host(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    host_name: Path<String>,
    key: web::Form<RemoveKeyFromHostForm>,
) -> actix_web::Result<impl Responder> {
    let res = ssh_client
        .remove_key(host_name.to_string(), key.0.key_base64)
        .await;

    Ok(match res {
        Ok(()) => FormResponseBuilder::success(String::from("Removed key from host")),
        Err(e) => FormResponseBuilder::error(e.to_string()),
    })
}

#[derive(Template)]
#[template(path = "forms/assign_key_dialog.html")]
struct AssignKeyDialog {
    key: SshPublicKey,
    users: Vec<User>,
}

#[post("/render/diff/assign_key")]
pub async fn assign_key_dialog(
    conn: Data<ConnectionPool>,
    key: web::Form<SshPublicKey>,
) -> actix_web::Result<impl Responder> {
    let res = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    Ok(match res {
        Ok(users) => FormResponseBuilder::dialog(Modal {
            title: String::from("Assign this key to a user"),
            request_target: String::from("/user/assign_key"),
            template: AssignKeyDialog { key: key.0, users }.to_string(),
        }),
        Err(error) => FormResponseBuilder::error(error),
    })
}

#[derive(Deserialize)]
struct AssignKeyDialogForm {
    user_id: i32,
    key_type: String,
    key_base64: String,
    key_comment: Option<String>,
}

#[post("/user/assign_key")]
pub async fn assign_key_to_user(
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
        Ok(()) => FormResponseBuilder::created(String::from("Added key")),
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(Template)]
#[template(path = "render/list_keys.html")]
struct KeyListTemplate {
    keys: Vec<SshPublicKey>,
}

#[get("/render/user/{username}/list_keys")]
pub async fn render_user_keys(
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
        Ok(keys) => KeyListTemplate { keys }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "pages/hosts.html")]
struct HostsTemplate {}

#[get("/hosts")]
pub async fn hosts_page() -> impl Responder {
    HostsTemplate {}
}

#[derive(Template)]
#[template(path = "pages/show_host.html")]
struct ShowHostTemplate {
    host: Host,
    jumphost: Option<String>,
    authorized_users: Vec<UserAndOptions>,
    users: Vec<User>,
}

type HostData = (Host, Option<String>, Vec<UserAndOptions>, Vec<User>);

enum HostDataError {
    HostNotFound,
    DatabaseError(String),
}

fn get_all_host_data(conn: &mut DbConnection, host: String) -> Result<HostData, HostDataError> {
    let maybe_host = Host::get_host_name(conn, host).map_err(HostDataError::DatabaseError)?;

    let Some(host) = maybe_host else {
        return Err(HostDataError::HostNotFound);
    };

    let jumphost = if let Some(id) = host.jump_via {
        Host::get_host_id(conn, id)
            .map_err(HostDataError::DatabaseError)?
            .map(|h| h.name)
    } else {
        None
    };

    let authorized_users = host
        .get_authorized_users(conn)
        .map_err(HostDataError::DatabaseError)?;

    let user_list = User::get_all_users(conn).map_err(HostDataError::DatabaseError)?;

    Ok((host, jumphost, authorized_users, user_list))
}

#[get("/hosts/{name}")]
pub async fn show_host(
    conn: Data<ConnectionPool>,
    host: Path<String>,
) -> actix_web::Result<impl Responder> {
    let res =
        web::block(move || get_all_host_data(&mut conn.get().unwrap(), host.to_string())).await?;

    let (host, jumphost, authorized_users, user_list) = match res {
        Ok(host_data) => host_data,
        Err(e) => {
            return Ok(match e {
                HostDataError::HostNotFound => {
                    FormResponseBuilder::not_found(String::from("Host not found")).into_response()
                }
                HostDataError::DatabaseError(e) => FormResponseBuilder::error(e).into_response(),
            })
        }
    };

    Ok(ShowHostTemplate {
        host,
        jumphost,
        authorized_users,
        users: user_list,
    }
    .to_response())
}

#[derive(Template)]
#[template(path = "forms/hostkey_dialog.html")]
struct HostkeyDialog {
    name: String,
    username: String,
    hostname: String,
    port: i32,
    key_fingerprint: String,
    jumphost: Option<i32>,
}

#[derive(Deserialize)]
struct HostAddForm {
    name: String,
    username: String,
    hostname: String,
    port: i32,
    jumphost: Option<i32>,
    key_fingerprint: Option<String>,
}

#[post("/hosts/add")]
pub async fn add_host(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    form: web::Form<HostAddForm>,
) -> actix_web::Result<impl Responder> {
    let form = form.0;

    // TODO: better error handling for jumphost
    let cloned_conn = conn.clone();
    let maybe_jumphost: Option<Host> = if let Some(via) = form.jumphost {
        if via < 0 {
            None
        } else {
            match web::block(move || Host::get_host_id(&mut cloned_conn.get().unwrap(), via))
                .await?
            {
                Ok(j) => j,
                Err(_) => {
                    return Ok(FormResponseBuilder::not_found(String::from(
                        "Couldn't find jump host",
                    )));
                }
            }
        }
    } else {
        None
    };
    let Ok(address) = ConnectionDetails::new_from_signed(form.hostname.clone(), form.port) else {
        return Ok(FormResponseBuilder::error(String::from(
            "Invalid port number",
        )));
    };
    debug!(
        "Trying to connect to {} on port {} via jumphost: {:?}",
        &address.hostname, &address.port, maybe_jumphost
    );
    let Some(key_fingerprint) = form.key_fingerprint else {
        let connection_res = match maybe_jumphost {
            Some(via) => ssh_client.get_hostkey_via(via, address).await,
            None => ssh_client.get_hostkey(address).await,
        };

        let key_receiver = match connection_res {
            Ok(r) => r,
            Err(e) => return Ok(FormResponseBuilder::error(e.to_string())),
        };

        let Ok(key_fingerprint) = web::block(move || key_receiver.recv()).await? else {
            return Ok(FormResponseBuilder::error(String::from(
                "Connection timed out",
            )));
        };

        return Ok(FormResponseBuilder::dialog(Modal {
            title: String::from("Please check the hostkey"),
            request_target: String::from("/hosts/add"),
            template: HostkeyDialog {
                name: form.name,
                username: form.username,
                hostname: form.hostname,
                port: form.port,
                jumphost: form.jumphost,
                key_fingerprint,
            }
            .to_string(),
        }));
    };

    if let Err(error) = {
        match maybe_jumphost {
            Some(ref via) => {
                ssh_client
                    .try_authenticate_via(
                        via.clone(),
                        address,
                        key_fingerprint.clone(),
                        form.username.clone(),
                    )
                    .await
            }
            None => {
                ssh_client
                    .try_authenticate(address, key_fingerprint.clone(), form.username.clone())
                    .await
            }
        }
    } {
        return Ok(FormResponseBuilder::error(error.to_string()));
    };

    let new_host = NewHost {
        name: form.name.clone(),
        hostname: form.hostname,
        port: form.port,
        username: form.username,
        key_fingerprint,
        jump_via: maybe_jumphost.map(|h| Some(h.id)).unwrap_or(None),
    };
    let res = web::block(move || Host::add_host(&mut conn.get().unwrap(), &new_host)).await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::created(String::from("Added host"))
            .add_trigger(String::from("reload-hosts")),
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(Template)]
#[template(path = "render/list_hosts.html")]
struct RenderHostsTemplate {
    hosts: Vec<Host>,
}

#[get("/render/hosts")]
pub async fn render_hosts(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;

    Ok(match all_hosts {
        Ok(all_hosts) => RenderHostsTemplate { hosts: all_hosts }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "pages/keys.html")]
struct KeysPageTemplate {
    keys: Vec<UsernameAndKey>,
}

#[get("/keys")]
pub async fn list_keys(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_keys =
        web::block(move || PublicUserKey::get_all_keys_with_username(&mut conn.get().unwrap()))
            .await?;

    Ok(match all_keys {
        Ok(keys) => KeysPageTemplate { keys }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "pages/diff.html")]
struct DiffPageTemplate {
    hosts: Vec<Host>,
}

#[get("/diff")]
pub async fn diff_page(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    Ok(
        match web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await? {
            Ok(hosts) => DiffPageTemplate { hosts }.to_response(),
            Err(error) => ErrorTemplate { error }.to_response(),
        },
    )
}

#[derive(Template)]
#[template(path = "pages/show_diff.html")]
struct ShowDiffTemplate {
    host: Host,
}

#[get("/diff/{name}")]
pub async fn show_diff(
    conn: Data<ConnectionPool>,
    host_name: Path<String>,
) -> actix_web::Result<impl Responder> {
    Ok(
        match web::block(move || {
            Host::get_host_name(&mut conn.get().unwrap(), host_name.to_string())
        })
        .await?
        {
            Ok(host) => {
                let Some(host) = host else {
                    return Ok(ErrorTemplate {
                        error: String::from("Host not found"),
                    }
                    .to_response());
                };
                ShowDiffTemplate { host }.to_response()
            }
            Err(error) => ErrorTemplate { error }.to_response(),
        },
    )
}

#[derive(Template)]
#[template(path = "render/diff.html")]
struct RenderDiffTemplate {
    diff: HostDiff,

    // Users to associate keys with
    users: Vec<User>,
}

#[get("/render/host_diff/{host_name}")]
pub async fn render_diff(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    host_name: Path<String>,
) -> actix_web::Result<impl Responder> {
    let res = web::block(move || {
        let mut connection = conn.get().unwrap();

        let host_list = Host::get_host_name(&mut connection, host_name.to_string())?;
        let user_list = User::get_all_users(&mut connection)?;

        Ok((host_list, user_list))
    })
    .await?;

    let (host, user_list) = match res {
        Ok((maybe_host, users)) => {
            let Some(host) = maybe_host else {
                return Ok(RenderErrorTemplate {
                    error: String::from("No such host."),
                }
                .to_response());
            };
            (host, users)
        }
        Err(error) => return Ok(RenderErrorTemplate { error }.to_response()),
    };

    let diff = ssh_client.get_host_diff(host).await;

    Ok(RenderDiffTemplate {
        diff,
        users: user_list,
    }
    .to_response())
}

#[derive(Deserialize)]
struct AuthorizeUserForm {
    host_id: i32,
    user_id: i32,
    options: Option<String>,
}

#[post("/hosts/user/authorize")]
pub async fn authorize_user(
    conn: Data<ConnectionPool>,

    form: web::Form<AuthorizeUserForm>,
) -> actix_web::Result<impl Responder> {
    let res = web::block(move || {
        Host::authorize_user(
            &mut conn.get().unwrap(),
            form.host_id,
            form.user_id,
            form.options.clone(),
        )
    })
    .await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::success(String::from("Authorized user")),
        Err(e) => FormResponseBuilder::error(e),
    })
}
