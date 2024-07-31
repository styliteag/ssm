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
    ConnectionPool,
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
pub async fn users(conn: Data<ConnectionPool>) -> impl Responder {
    let mut connection = conn.get().unwrap();

    match User::get_all_users(&mut connection) {
        Ok(users) => UsersTemplate { users }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    }
}

#[derive(Template)]
#[template(path = "pages/show_user.html")]
struct ShowUserTemplate {
    user: User,
}
#[get("/users/{name}")]
pub async fn show_user(conn: Data<ConnectionPool>, user: Path<String>) -> impl Responder {
    let mut connection = conn.get().unwrap();

    match User::get_user(&mut connection, user.to_string()) {
        Ok(user) => ShowUserTemplate { user }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    }
}

#[derive(Template)]
#[template(path = "render/add_user.html")]
struct AddUserTemplate {
    response: Result<String, String>,
}

#[post("/users/add")]
pub async fn add_user(conn: Data<ConnectionPool>, form: web::Form<NewUser>) -> impl Responder {
    let new_user = form.0;

    let res = User::add_user(&mut conn.get().unwrap(), new_user);
    AddUserTemplate { response: res }
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
) -> impl Responder {
    dbg!(&form.key_comment);
    match PublicUserKey::add_key(
        &mut conn.get().unwrap(),
        NewPublicUserKey {
            key_type: form.key_type.clone(),
            key_base64: form.key_base64.clone(),
            user_id: form.user_id,
            comment: form.key_comment.to_owned(),
        },
    ) {
        Ok(_) => HttpResponse::with_body(
            StatusCode::OK,
            String::from(
                "Added
            key.",
            ),
        ),
        Err(e) => HttpResponse::with_body(StatusCode::INTERNAL_SERVER_ERROR, e),
    }

    //TODO: insert user key and assign user to host
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
) -> impl Responder {
    let mut connection = conn.get().unwrap();

    match User::get_user(&mut connection, username.to_string()) {
        Ok(user) => match user.get_keys(&mut connection) {
            Ok(keys) => KeyListTemplate { keys }.to_response(),
            Err(error) => RenderErrorTemplate { error }.to_response(),
        },
        Err(error) => RenderErrorTemplate { error }.to_response(),
    }
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

#[get("/hosts/{name}")]
pub async fn show_host(conn: Data<ConnectionPool>, host: Path<String>) -> impl Responder {
    let mut connection = conn.get().unwrap();
    match Host::get_host(&mut connection, host.to_string()) {
        Ok(maybe_host) => match maybe_host {
            Some(host) => match host.get_hostkeys(&mut connection) {
                Ok(host_keys) => {
                    let authorized_users = host.get_authorized_users(&mut connection).unwrap();
                    ShowHostTemplate {
                        host,
                        users: User::get_all_users(&mut connection).unwrap(),

                        host_keys,
                        authorized_users,
                    }
                    .to_response()
                }
                Err(error) => ErrorTemplate { error }.to_response(),
            },
            None => ErrorTemplate {
                error: String::from("Specified host not found."),
            }
            .to_response(),
        },
        Err(error) => ErrorTemplate { error }.to_response(),
    }
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
) -> impl Responder {
    let host = form.0;
    match ssh_client
        .connect(
            host.addr,
            host.user.as_str(),
            async_ssh2_tokio::ServerCheckMethod::NoCheck,
        )
        .await
    {
        Ok(client) => {
            let Ok(host_keys) = ssh_client.get_hostkeys(&client).await else {
                return AddHostTemplate {
                    response: Err(String::from("Couldn't get servers public key")),
                }
                .to_response();
            };

            // TODO: prompt user to check host keys validity

            let connection = &mut conn.get().unwrap();
            let sock = client.get_connection_address();
            match Host::add_host(
                connection,
                NewHost {
                    name: host.name.clone(),
                    // TODO: do this correct
                    hostname: sock.hostname(),
                    username: host.user,
                    port: sock.port() as i16,
                },
                &host_keys,
            ) {
                Ok(host) => AddHostTemplate {
                    response: Ok(host.name),
                }
                .to_response(),
                Err(e) => AddHostTemplate { response: Err(e) }.to_response(),
            }
        }
        Err(e) => AddHostTemplate {
            response: Err(e.to_string()),
        }
        .to_response(),
    }
}

#[derive(Template)]
#[template(path = "render/list_hosts.html")]
struct RenderHostsTemplate {
    hosts: Vec<ShortHost>,
}

#[get("/render/hosts")]
pub async fn render_hosts(conn: Data<ConnectionPool>) -> impl Responder {
    match Host::get_all_hosts(&mut conn.get().expect("error")) {
        Ok(all_hosts) => RenderHostsTemplate {
            hosts: all_hosts.iter().map(Host::to_short).collect(),
        }
        .to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    }
}

#[derive(Template)]
#[template(path = "pages/keys.html")]
struct KeysPageTemplate {
    keys: Vec<UsernameAndKey>,
}

#[get("/keys")]
pub async fn list_keys(conn: Data<ConnectionPool>) -> impl Responder {
    match PublicUserKey::get_all_keys_with_username(&mut conn.get().unwrap()) {
        Ok(keys) => KeysPageTemplate { keys }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    }
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
) -> impl Responder {
    use futures::future::join_all;

    let mut connection = conn.get().unwrap();

    let user_list = match User::get_all_users(&mut connection) {
        Ok(u) => u,
        Err(error) => return RenderErrorTemplate { error }.to_response(),
    };

    match Host::get_all_hosts(&mut connection) {
        Ok(host_list) => {
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

            RenderDiffTemplate {
                hosts: host_diffs,
                users: user_list,
            }
            .to_response()
        }
        Err(error) => RenderErrorTemplate { error }.to_response(),
    }
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
) -> impl Responder {
    match Host::authorize_user(
        &mut conn.get().unwrap(),
        form.host_id,
        form.user_id,
        form.options.to_owned(),
    ) {
        Ok(_) => HttpResponse::with_body(StatusCode::OK, String::from("Authorized user.")),
        Err(e) => HttpResponse::with_body(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}
