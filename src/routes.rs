use actix_web::{
    get,
    http::StatusCode,
    post,
    test::{call_and_read_body_json, read_body},
    web::{self, Data, Path},
    HttpRequest, HttpResponse, Responder,
};
use askama_actix::{Template, TemplateToResponse};
use async_ssh2_tokio::ToSocketAddrsWithHostname;
use log::{error, info};
use serde::Deserialize;

use crate::{
    sshclient::{self, ShortHost, SshClient, SshPublicKey},
    ConnectionPool,
};

use crate::models::*;

#[derive(Template)]
#[template(path = "pages/404.html")]
struct NotFoundTemplate {}

#[derive(Template)]
#[template(path = "error.html")]
struct ErrorTemplate<'a> {
    error: &'a str,
}

#[derive(Template)]
#[template(path = "render/error.html")]
struct RenderErrorTemplate<'a> {
    error: &'a str,
}

#[derive(Template)]
#[template(path = "pages/index.html")]
struct IndexTemplate {}

#[derive(Template)]
#[template(path = "render/list_hosts.html")]
struct RenderHostsTemplate {
    hosts: Vec<ShortHost>,
}

#[derive(Template)]
#[template(path = "render/list_keys.html")]
struct KeyListTemplate {
    keys: Vec<SshPublicKey>,
}

pub async fn not_found(_req: HttpRequest) -> impl Responder {
    NotFoundTemplate {}
        .customize()
        .with_status(StatusCode::NOT_FOUND)
}

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
    UsersTemplate {
        users: User::get_all_users(&mut connection),
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
        Some(user) => ShowUserTemplate { user }.to_response(),
        None => NotFoundTemplate {}.to_response(),
    }
}

#[get("/render/user/list_keys/{username}")]
pub async fn render_user_keys(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> impl Responder {
    let mut connection = conn.get().unwrap();

    match User::get_user(&mut connection, username.to_string()) {
        Some(user) => {
            let keys = user.get_keys(&mut connection).unwrap_or_else(|e| {
                error!(
                    "Failed to get keys while trying to render User template {}",
                    e
                );
                Vec::new()
            });
            KeyListTemplate { keys }.to_response()
        }
        None => NotFoundTemplate {}.to_response(),
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
    host_keys: Vec<SshPublicKey>,
}

#[get("/hosts/{name}")]
pub async fn show_host(conn: Data<ConnectionPool>, host: Path<String>) -> impl Responder {
    let mut connection = conn.get().unwrap();
    let maybe_host = Host::get_host(&mut connection, host.to_string());

    match maybe_host {
        Some(host) => {
            let host_keys = host.get_hostkeys(&mut connection).unwrap_or_else(|e| {
                error!(
                    "Failed to get hostkeys while trying to render Host template {}",
                    e
                );
                Vec::new()
            });
            ShowHostTemplate { host, host_keys }.to_response()
        }
        None => NotFoundTemplate {}.to_response(),
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
        .connect(host.addr, async_ssh2_tokio::ServerCheckMethod::NoCheck)
        .await
    {
        Ok(client) => {
            let Ok(host_keys) = ssh_client.get_hostkeys(&client).await else {
                return AddHostTemplate {
                    response: Err("Couldn't get servers public key".to_owned()),
                };
            };

            // TODO: prompt user to check host keys validity?
            dbg!(host_keys.clone());
            let _ = client.disconnect().await;

            let sock = client.get_connection_address();
            match Host::add_host(
                &mut conn.get().expect("test"),
                NewHost {
                    name: host.name.to_owned(),
                    // TODO: do this correct
                    hostname: sock.hostname(),
                    port: sock.port() as i16,
                },
                host_keys,
            ) {
                Ok(host) => AddHostTemplate {
                    response: Ok(host.name),
                },
                Err(e) => AddHostTemplate { response: Err(e) },
            }
        }
        Err(e) => AddHostTemplate {
            response: Err(e.to_string()),
        },
    }
}

#[get("/render/hosts")]
pub async fn render_hosts(conn: Data<ConnectionPool>) -> impl Responder {
    let all_hosts = Host::get_all_hosts(&mut conn.get().expect("error"));
    RenderHostsTemplate {
        hosts: all_hosts
            .iter()
            .map(|host| host.to_owned().to_short())
            .collect(),
    }
}

#[get("/render/host/list_keys/{host}")]
pub async fn render_host_keys(
    req: HttpRequest,
    ssh_client: Data<SshClient>,
    conn: Data<ConnectionPool>,
    host: Path<String>,
) -> impl Responder {
    // TODO: better variable names

    let maybe_host = Host::get_host(&mut conn.get().unwrap(), host.to_string());
    let keys = match maybe_host {
        Some(host) => {
            ssh_client
                .get_authorized_keys(host.to_owned().to_short())
                .await
        }
        // TODO: actually return a correct error
        None => {
            return RenderErrorTemplate {
                error: "Host not found.",
            }
            .customize()
            .with_status(StatusCode::BAD_REQUEST)
            .respond_to(&req)
        }
    };

    //TODO: Better error handling.
    match keys {
        Err(error) => {
            error!("Error trying to list authorized keys for host '{}'", error);
            RenderErrorTemplate {
                error: error.to_string().as_str(),
            }
            .customize()
            .with_status(StatusCode::INTERNAL_SERVER_ERROR)
            .respond_to(&req)
        }
        Ok(keys) => KeyListTemplate { keys }.customize().respond_to(&req),
    }
}

#[derive(Template)]
#[template(path = "pages/keys.html")]
struct KeysPageTemplate {
    keys: Vec<SshPublicKey>,
}

#[get("/keys")]
pub async fn list_keys(conn: Data<ConnectionPool>) -> impl Responder {
    let keys = PublicKey::get_all_keys_as::<SshPublicKey>(&mut conn.get().unwrap());

    KeysPageTemplate { keys }
}
