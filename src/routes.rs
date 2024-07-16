use actix_web::{
    get,
    http::StatusCode,
    post,
    web::{self, Data, Path},
    HttpRequest, Responder,
};
use askama_actix::{Template, TemplateToResponse};
use async_ssh2_tokio::ToSocketAddrsWithHostname;

use crate::{
    sshclient::{ShortHost, SshClient, SshPublicKey},
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
    host_keys: Vec<SshPublicKey>,
}

#[get("/hosts/{name}")]
pub async fn show_host(conn: Data<ConnectionPool>, host: Path<String>) -> impl Responder {
    let mut connection = conn.get().unwrap();
    match Host::get_host(&mut connection, host.to_string()) {
        Ok(maybe_host) => match maybe_host {
            Some(host) => match host.get_hostkeys(&mut connection) {
                Ok(host_keys) => ShowHostTemplate { host, host_keys }.to_response(),
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
                };
            };

            // TODO: prompt user to check host keys validity
            let _ = client.disconnect().await;

            let sock = client.get_connection_address();
            match Host::add_host(
                &mut conn.get().expect("test"),
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
                },
                Err(e) => AddHostTemplate { response: Err(e) },
            }
        }
        Err(e) => AddHostTemplate {
            response: Err(e.to_string()),
        },
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

// #[get("/render/host/{host}/list_keys")]
// pub async fn render_host_keys(
//     req: HttpRequest,
//     conn: Data<ConnectionPool>,
//     host: Path<String>,
// ) -> impl Responder {
//     let mut connection = conn.get().unwrap();

//     match Host::get_host(&mut connection, host.to_string()) {
//         Ok(maybe_host) => match maybe_host {
//             Some(host) => match host.get_authorized_keys(&mut connection) {
//                 Ok(keys) => KeyListTemplate { keys }.customize().respond_to(&req),
//                 Err(error) => RenderErrorTemplate { error }.customize().respond_to(&req),
//             },
//             None => RenderErrorTemplate {
//                 error: String::from("Couldn't find specified host"),
//             }
//             .customize()
//             .with_status(StatusCode::BAD_REQUEST)
//             .respond_to(&req),
//         },

//         Err(error) => RenderErrorTemplate { error }
//             .customize()
//             .with_status(StatusCode::INTERNAL_SERVER_ERROR)
//             .respond_to(&req),
//     }
// }

#[derive(Template)]
#[template(path = "pages/keys.html")]
struct KeysPageTemplate {
    keys: Vec<SshPublicKey>,
}

#[get("/keys")]
pub async fn list_keys(conn: Data<ConnectionPool>) -> impl Responder {
    match PublicKey::get_all_keys_as::<SshPublicKey>(&mut conn.get().unwrap()) {
        Ok(keys) => KeysPageTemplate { keys }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    }
}
