use actix_web::{
    get,
    http::StatusCode,
    post,
    web::{self, Data, Path},
    HttpRequest, HttpResponse, Responder,
};
use askama_actix::{Template, TemplateToResponse};
use async_ssh2_tokio::ToSocketAddrsWithHostname;
use log::error;
use serde::Deserialize;

use crate::{
    db::{UserAndOptions, UsernameAndKey},
    sshclient::{HostDiff, ShortHost, SshClient, SshPublicKey},
    ConnectionPool, DbConnection,
};

use crate::models::*;

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

pub async fn not_found(_req: HttpRequest) -> impl Responder {
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
struct UsersTemplate {
    users: Vec<User>,
}

#[get("/users")]
pub async fn users(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let maybe_users = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    Ok(match maybe_users {
        Ok(users) => UsersTemplate { users }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
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
        Ok(_) => HttpResponse::with_body(StatusCode::CREATED, String::from("Added user.")),
        Err(e) => HttpResponse::with_body(StatusCode::INTERNAL_SERVER_ERROR, e),
    })
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
        comment: form.key_comment.to_owned(),
    };

    let res = web::block(move || PublicUserKey::add_key(&mut conn.get().unwrap(), new_key)).await?;

    Ok(match res {
        Ok(_) => HttpResponse::with_body(StatusCode::CREATED, String::from("Added key.")),
        Err(e) => HttpResponse::with_body(StatusCode::INTERNAL_SERVER_ERROR, e),
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
pub async fn hosts() -> impl Responder {
    HostsTemplate {}
}

#[derive(Template)]
#[template(path = "pages/show_host.html")]
struct ShowHostTemplate {
    host: Host,
    host_keys: Vec<HostKey>,
    authorized_users: Vec<UserAndOptions>,
    users: Vec<User>,
}

type HostData = (Host, Vec<HostKey>, Vec<UserAndOptions>, Vec<User>);

enum HostDataError {
    HostNotFound,
    DatabaseError(String),
}

fn get_all_host_data(conn: &mut DbConnection, host: String) -> Result<HostData, HostDataError> {
    let maybe_host = Host::get_host(conn, host).map_err(HostDataError::DatabaseError)?;

    let host = match maybe_host {
        Some(e) => e,
        None => return Err(HostDataError::HostNotFound),
    };

    let host_keys = host
        .get_hostkeys(conn)
        .map_err(HostDataError::DatabaseError)?;

    let authorized_users = host
        .get_authorized_users(conn)
        .map_err(HostDataError::DatabaseError)?;

    let user_list = User::get_all_users(conn).map_err(HostDataError::DatabaseError)?;

    Ok((host, host_keys, authorized_users, user_list))
}

#[get("/hosts/{name}")]
pub async fn show_host(
    conn: Data<ConnectionPool>,
    host: Path<String>,
) -> actix_web::Result<impl Responder> {
    let res =
        web::block(move || get_all_host_data(&mut conn.get().unwrap(), host.to_string())).await?;

    let (host, host_keys, authorized_users, user_list) = match res {
        Ok(host_data) => host_data,
        Err(e) => {
            return Ok(match e {
                HostDataError::HostNotFound => HttpResponse::with_body(
                    StatusCode::NOT_FOUND,
                    String::from("Host not found on server."),
                ),
                HostDataError::DatabaseError(e) => {
                    HttpResponse::with_body(StatusCode::INTERNAL_SERVER_ERROR, e)
                }
            }
            .map_into_boxed_body())
        }
    };

    Ok(ShowHostTemplate {
        host,
        host_keys,
        authorized_users,
        users: user_list,
    }
    .to_response())
}

#[derive(Template)]
#[template(path = "render/add_host.html")]
struct AddHostTemplate {
    response: Result<String, String>,
}

#[post("/hosts/add")]
pub async fn add_host(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    form: web::Form<ShortHost>,
) -> actix_web::Result<impl Responder> {
    let host = form.0;

    let (host_keys, hostname, port) = match ssh_client
        .connect(
            host.addr,
            host.user.as_str(),
            async_ssh2_tokio::ServerCheckMethod::NoCheck,
        )
        .await
    {
        Ok(client) => match ssh_client.get_hostkeys(&client).await {
            Ok(keys) => {
                let sock = client.get_connection_address();
                let hostname = sock.hostname();
                let port = sock.port() as i16;

                SshClient::try_disconnect(client).await;

                (keys, hostname, port)
            }
            Err(e) => {
                return Ok(AddHostTemplate {
                    response: Err(e.to_string()),
                })
            }
        },
        Err(e) => {
            return Ok(AddHostTemplate {
                response: Err(e.to_string()),
            })
        }
    };

    let new_host = NewHost {
        name: host.name.clone(),
        hostname,
        username: host.user,
        port,
    };
    let res =
        web::block(move || Host::add_host(&mut conn.get().unwrap(), new_host, &host_keys)).await?;

    Ok(match res {
        Ok(_) => AddHostTemplate {
            response: Ok(host.name),
        },
        Err(e) => AddHostTemplate { response: Err(e) },
    })
}

#[derive(Template)]
#[template(path = "render/list_hosts.html")]
struct RenderHostsTemplate {
    hosts: Vec<ShortHost>,
}

#[get("/render/hosts")]
pub async fn render_hosts(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;

    Ok(match all_hosts {
        Ok(all_hosts) => RenderHostsTemplate {
            hosts: all_hosts.iter().map(Host::to_short).collect(),
        }
        .to_response(),
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
struct DiffPageTemplate {}

#[get("/diff")]
pub async fn diff() -> impl Responder {
    DiffPageTemplate {}
}

#[derive(Template)]
#[template(path = "render/diff.html")]
struct RenderDiffTemplate {
    hosts: Vec<HostDiff>,

    /// Users to associate keys with them
    users: Vec<User>,
}

#[get("/render/diff")]
pub async fn render_diff(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
) -> actix_web::Result<impl Responder> {
    use futures::future::join_all;

    let res = web::block(move || {
        let mut connection = conn.get().unwrap();

        let host_list = Host::get_all_hosts(&mut connection)?;
        let user_list = User::get_all_users(&mut connection)?;

        Ok((host_list, user_list))
    })
    .await?;

    let (host_list, user_list) = match res {
        Ok(t) => t,
        Err(error) => return Ok(RenderErrorTemplate { error }.to_response()),
    };

    let host_diff_futures = host_list.iter().map(|host| ssh_client.get_host_diff(host));

    let host_diffs = join_all(host_diff_futures)
        .await
        .iter()
        .filter_map(|val| match val {
            Ok(e) => Some(e),
            Err(e) => {
                error!("{}", e.to_string());
                None
            }
        })
        .cloned()
        .collect();

    Ok(RenderDiffTemplate {
        hosts: host_diffs,
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
            form.options.to_owned(),
        )
    })
    .await?;

    Ok(match res {
        Ok(_) => HttpResponse::with_body(StatusCode::OK, String::from("Authorized user.")),
        Err(e) => HttpResponse::with_body(StatusCode::INTERNAL_SERVER_ERROR, e),
    })
}
