use actix_web::{
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
    sshclient::{ConnectionDetails, HostDiff, SshClient, SshPublicKey},
    ConnectionPool, DbConnection,
};

use crate::models::{Host, NewHost, NewPublicUserKey, NewUser, PublicUserKey, User};

struct Modal {
    title: String,
    request_target: String,
    template: String,
    button_text: String,
}

enum FormResponse {
    /// A successful Response with a message
    Success(String),
    /// An error Response with a message
    Error(String),
    /// Show a modal to the user
    Dialog(Modal),
}

#[derive(Template)]
#[template(path = "render/form_response.html")]
struct FormResponseTemplate {
    res: FormResponse,
}

/// Build a response to a post request.
fn return_form_boxed(
    status_code: StatusCode,
    trigger: Option<String>,
    form_response: FormResponse,
) -> HttpResponse {
    let mut builder = HttpResponseBuilder::new(status_code);
    if matches!(form_response, FormResponse::Dialog(_)) {
        builder.insert_header(("X-MODAL", "open"));
    };
    if let Some(trigger_value) = trigger {
        builder.insert_header((String::from("HX-Trigger"), trigger_value));
    };

    builder.body(FormResponseTemplate { res: form_response }.to_string())
}

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
        Ok(_) => return_form_boxed(
            StatusCode::CREATED,
            Some(String::from("reload-users")),
            FormResponse::Success(String::from("Added user.")),
        ),
        Err(e) => return_form_boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            None,
            FormResponse::Error(e),
        ),
    })
}

#[derive(Deserialize)]
struct DeleteUserForm {
    username: String,
    confirm: Option<bool>,
}

#[derive(Template)]
#[template(path = "render/delete_user.html")]
struct DeleteUserResponse {
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
            Ok(()) => return_form_boxed(
                StatusCode::OK,
                None,
                FormResponse::Success(String::from("Deleted user.")),
            ),
            Err(e) => return_form_boxed(
                StatusCode::UNPROCESSABLE_ENTITY,
                None,
                FormResponse::Error(e),
            ),
        })
    } else {
        Ok(return_form_boxed(
            StatusCode::OK,
            None,
            FormResponse::Dialog(Modal {
                title: String::from("Are you sure you want to delete this user?"),
                request_target: String::from("/users/delete"),
                template: DeleteUserResponse { username }.to_string(),
                button_text: String::from("Delete"),
            }),
        ))
    }
}

#[derive(Deserialize)]
struct AssignKeyForm {
    user_id: i32,
    key_type: String,
    key_base64: String,
    key_comment: Option<String>,
}

#[post("/user/add_key")]
pub async fn assign_key_to_user(
    conn: Data<ConnectionPool>,
    form: web::Form<AssignKeyForm>,
) -> actix_web::Result<impl Responder> {
    let new_key = NewPublicUserKey {
        key_type: form.key_type.clone(),
        key_base64: form.key_base64.clone(),
        user_id: form.user_id,
        comment: form.key_comment.clone(),
    };

    let res = web::block(move || PublicUserKey::add_key(&mut conn.get().unwrap(), new_key)).await?;

    Ok(match res {
        Ok(()) => return_form_boxed(
            StatusCode::CREATED,
            None,
            FormResponse::Success(String::from("Added key.")),
        ),
        Err(e) => return_form_boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            None,
            FormResponse::Error(e),
        ),
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
                HostDataError::HostNotFound => return_form_boxed(
                    StatusCode::NOT_FOUND,
                    None,
                    FormResponse::Error(String::from("Host not found on server.")),
                ),
                HostDataError::DatabaseError(e) => return_form_boxed(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    None,
                    FormResponse::Error(e),
                ),
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
#[template(path = "render/host_hostkey_response.html")]
struct HostkeyResponseTemplate {
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
                    return Ok(return_form_boxed(
                        StatusCode::NOT_FOUND,
                        None,
                        FormResponse::Error(String::from("Couldn't find jump host")),
                    ));
                }
            }
        }
    } else {
        None
    };
    let Ok(address) = ConnectionDetails::new_from_signed(form.hostname.clone(), form.port) else {
        return Ok(return_form_boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            None,
            FormResponse::Error(String::from("Invalid port number")),
        ));
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
            Err(e) => {
                return Ok(return_form_boxed(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    None,
                    FormResponse::Error(e.to_string()),
                ))
            }
        };

        let Ok(key_fingerprint) = web::block(move || key_receiver.recv()).await? else {
            return Ok(return_form_boxed(
                StatusCode::UNPROCESSABLE_ENTITY,
                None,
                FormResponse::Error(String::from("Connection timed out.")),
            ));
        };

        return Ok(return_form_boxed(
            StatusCode::OK,
            None,
            FormResponse::Dialog(Modal {
                title: String::from("Please check the hostkey"),
                request_target: String::from("/hosts/add"),
                template: HostkeyResponseTemplate {
                    name: form.name,
                    username: form.username,
                    hostname: form.hostname,
                    port: form.port,
                    jumphost: form.jumphost,
                    key_fingerprint,
                }
                .to_string(),
                button_text: String::from("Continue"),
            }),
        ));
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
        return Ok(return_form_boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            None,
            FormResponse::Error(error.to_string()),
        ));
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
        Ok(()) => return_form_boxed(
            StatusCode::CREATED,
            Some(String::from("reload-hosts")),
            FormResponse::Success(String::from("Host sucessfully added.")),
        ),
        Err(e) => return_form_boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            None,
            FormResponse::Error(e),
        ),
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

#[get("/render/diff/{name}")]
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
        Ok(()) => return_form_boxed(
            StatusCode::OK,
            None,
            FormResponse::Success(String::from("Authorized user.")),
        ),
        Err(e) => return_form_boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            None,
            FormResponse::Error(e),
        ),
    })
}
