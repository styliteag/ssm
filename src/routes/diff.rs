use crate::{
    routes::{should_update, ForceUpdate},
    ssh::{CachingSshClient, HostDiff},
    templates::AsHTML,
};
use actix_web::{
    body::BoxBody,
    get,
    http::StatusCode,
    post,
    web::{self, Data, Path},
    HttpResponse, Responder,
};
use askama_actix::{Template, TemplateToResponse};
use serde::Deserialize;

use crate::{
    forms::{FormResponseBuilder, Modal},
    routes::{ErrorTemplate, RenderErrorTemplate},
    ssh::SshPublicKey,
    ConnectionPool,
};

use crate::models::{Host, User};

pub fn diff_config(cfg: &mut web::ServiceConfig) {
    cfg.service(diff_page)
        .service(render_diff)
        .service(show_diff)
        .service(assign_key_dialog)
        .service(authorize_user_dialog);
}

#[derive(Template)]
#[template(path = "diff/index.html")]
struct DiffPageTemplate {
    hosts: Vec<Host>,
}

#[get("")]
async fn diff_page(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;

    Ok(match hosts {
        Ok(hosts) => DiffPageTemplate { hosts }.to_response(),
        Err(error) => ErrorTemplate { error }.to_response(),
    })
}

#[derive(Template)]
#[template(path = "diff/diff.htm")]
struct RenderDiffTemplate {
    host: Host,
    diff: HostDiff,
}

#[derive(Deserialize)]
struct ShowEmptyQuery {
    show_empty: Option<bool>,
}

#[get("/{host_name}.htm")]
async fn render_diff(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    force_update: ForceUpdate,
    show_empty: web::Query<ShowEmptyQuery>,
) -> actix_web::Result<impl Responder> {
    let res = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    let host = match res {
        Ok(maybe_host) => {
            let Some(host) = maybe_host else {
                return Ok(RenderErrorTemplate {
                    error: String::from("No such host."),
                }
                .to_response());
            };
            host
        }
        Err(error) => return Ok(RenderErrorTemplate { error }.to_response()),
    };

    let diff = caching_ssh_client
        .get_host_diff(host.clone(), should_update(force_update))
        .await;

    let show_empty = show_empty.0.show_empty.is_some_and(|b| b);

    match diff {
        (_, Ok(diff)) if diff.is_empty() && !show_empty => {
            Ok(HttpResponse::with_body(StatusCode::OK, BoxBody::new("")))
        }
        _ => Ok(RenderDiffTemplate { host, diff }.to_response()),
    }
}

#[derive(Template)]
#[template(path = "diff/show_diff.html")]
struct ShowDiffTemplate {
    host: Host,
}

#[get("/{name}")]
async fn show_diff(
    conn: Data<ConnectionPool>,
    host_name: Path<String>,
) -> actix_web::Result<impl Responder> {
    Ok(
        match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
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
#[template(path = "diff/assign_key_dialog.htm")]
struct AssignKeyDialog {
    key: SshPublicKey,
    users: Vec<User>,
}

#[post("/assign_key_dialog")]
async fn assign_key_dialog(
    conn: Data<ConnectionPool>,
    key: web::Form<SshPublicKey>,
) -> actix_web::Result<impl Responder> {
    let res = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    Ok(match res {
        Ok(users) => FormResponseBuilder::dialog(Modal {
            title: String::from("Assign this key to a user"),
            request_target: String::from("/users/assign_key"),
            template: AssignKeyDialog { key: key.0, users }.to_string(),
        }),
        Err(error) => FormResponseBuilder::error(error),
    })
}

#[derive(Template)]
#[template(path = "diff/authorize_user_dialog.htm")]
struct AuthorizeUserDialog {
    host: (String, i32),
    user: (String, i32),
    login: String,
}

#[derive(Deserialize)]
struct AuthorizeUserForm {
    /// Host name in key-manager
    host_name: String,
    /// Username in key-manager
    username: String,
    /// Username on the host
    login: String,
}

#[post("/authorize_user_dialog")]
async fn authorize_user_dialog(
    conn: Data<ConnectionPool>,
    form: web::Form<AuthorizeUserForm>,
) -> actix_web::Result<impl Responder> {
    let login = form.login.clone();
    let (user, host) = web::block(move || {
        let mut connection = conn.get().unwrap();

        let user = User::get_user(&mut connection, form.username.clone());
        let host = Host::get_from_name_sync(&mut connection, form.host_name.clone());
        (
            user.map(|u| (u.username, u.id)),
            host.map(|h| h.map(|h| (h.name, h.id))),
        )
    })
    .await?;

    let user = match user {
        Ok(u) => u,
        Err(error) => return Ok(FormResponseBuilder::error(error)),
    };

    let host = match host {
        Ok(h) => match h {
            Some(h) => h,
            None => return Ok(FormResponseBuilder::error(String::from("Host not found"))),
        },
        Err(error) => return Ok(FormResponseBuilder::error(error)),
    };

    Ok(FormResponseBuilder::dialog(Modal {
        title: String::from("Authorize user"),
        request_target: String::from("/hosts/user/authorize"),
        template: AuthorizeUserDialog { host, user, login }.to_string(),
    }))
}
