use std::sync::Arc;

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
    routes::{should_update, ErrorTemplate, ForceUpdate, RenderErrorTemplate},
    ssh::{CachingSshClient, KeyDiffItem, SshClient, SshClientError, SshFirstConnectionHandler},
    ConnectionPool,
};

use crate::models::{Host, NewHost};

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(hosts_page)
        .service(render_hosts)
        .service(get_logins)
        .service(add_host_dialog)
        .service(authorize_user_dialog)
        .service(add_host)
        .service(authorize_user)
        .service(gen_authorized_keys)
        .service(set_authorized_keys)
        .service(add_host_key)
        .service(delete)
        .service(delete_authorization)
        .service(list_host_authorizations)
        .service(edit_host_form)
        .service(edit_host)
        .service(show_host);
}

#[derive(Template)]
#[template(path = "hosts/index.html")]
struct HostsTemplate {}

#[get("")]
async fn hosts_page() -> impl Responder {
    HostsTemplate {}
}

#[derive(Template)]
#[template(path = "hosts/logins.htm")]
struct LoginsTemplate {
    logins: Result<Vec<String>, SshClientError>,
}

#[get("/{name}/logins")]
async fn get_logins(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    update: ForceUpdate,
) -> actix_web::Result<impl Responder> {
    let host = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    match host {
        Err(error) => Ok(RenderErrorTemplate { error }.to_response()),
        Ok(None) => Ok(RenderErrorTemplate {
            error: "Host not found".to_owned(),
        }
        .to_response()),
        Ok(Some(host)) => {
            let logins = caching_ssh_client
                .get_logins(host, should_update(update))
                .await;
            Ok(LoginsTemplate { logins }.to_response())
        }
    }
}

#[derive(Template)]
#[template(path = "hosts/show_host.html")]
struct ShowHostTemplate {
    host: Host,
    jumphost: Option<String>,
}

#[get("/{name}")]
async fn show_host(
    conn: Data<ConnectionPool>,
    host: Path<String>,
) -> actix_web::Result<impl Responder> {
    let host = match Host::get_from_name(conn.get().unwrap(), host.to_string()).await {
        Ok(Some(host)) => host,
        Ok(None) => {
            return Ok(ErrorTemplate {
                error: String::from("Host not found"),
            }
            .to_response());
        }
        Err(error) => {
            return Ok(ErrorTemplate { error }.to_response());
        }
    };

    if let Some(jumphost) = host.jump_via {
        return Ok(
            match Host::get_from_id(conn.get().unwrap(), jumphost).await {
                Ok(Some(jumphost)) => ShowHostTemplate {
                    host,
                    jumphost: Some(jumphost.name),
                }
                .to_response(),
                Ok(None) => ErrorTemplate {
                    error: String::from("Jumphost not found"),
                }
                .to_response(),
                Err(error) => ErrorTemplate { error }.to_response(),
            },
        );
    }

    Ok(ShowHostTemplate {
        host,
        jumphost: None,
    }
    .to_response())
}

#[derive(Deserialize)]
struct AddHostkeyForm {
    key_fingerprint: Option<String>,
}

#[post("/{id}/add_hostkey")]
async fn add_host_key(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    host_id: Path<i32>,
    new_hostkey: web::Form<AddHostkeyForm>,
) -> actix_web::Result<impl Responder> {
    let host = match Host::get_from_id(conn.get().unwrap(), *host_id).await {
        Ok(Some(h)) => h,
        Ok(None) => return Ok(FormResponseBuilder::not_found("Host not found.".to_owned())),
        Err(e) => return Ok(FormResponseBuilder::error(e)),
    };
    let port = host
        .port
        .try_into()
        .expect("Somehow a non u16 port made its way into the database");

    let handler = SshFirstConnectionHandler::new(
        Arc::clone(&conn),
        host.name.clone(),
        host.username.clone(),
        host.address.clone(),
        port,
        host.jump_via,
    )
    .await;

    let handler = match handler {
        Ok(handler) => handler,
        Err(e) => {
            return Ok(FormResponseBuilder::error(e.to_string()));
        }
    };

    let Some(ref key_fingerprint) = new_hostkey.key_fingerprint else {
        let res = handler.get_hostkey(ssh_client.into_inner()).await;

        let recv_result = match res {
            Ok(receiver) => receiver.await,
            Err(e) => {
                return Ok(FormResponseBuilder::error(e.to_string()));
            }
        };

        let key_fingerprint = match recv_result {
            Ok(key_fingerprint) => key_fingerprint,
            Err(e) => {
                error!("Error receiving key: {e}");
                return Ok(FormResponseBuilder::error(e.to_string()));
            }
        };

        return Ok(FormResponseBuilder::dialog(
            "Please check the hostkey",
            format!("/host/{}/add_hostkey", host.id),
            HostkeyDialog {
                host_name: host.name,
                login: host.username,
                address: host.address,
                port,
                jumphost: host.jump_via,
                key_fingerprint,
            },
        ));
    };

    let handler = handler.set_hostkey(key_fingerprint.to_owned());

    let res = handler.try_authenticate(&ssh_client).await;
    if let Err(e) = res {
        return Ok(FormResponseBuilder::error(e.to_string()));
    }

    Ok(
        match host.update_fingerprint(&mut conn.get().unwrap(), key_fingerprint.to_owned()) {
            Ok(()) => FormResponseBuilder::success("Set hostkey".to_owned()),
            Err(e) => FormResponseBuilder::error(e),
        },
    )
}

#[derive(Template)]
#[template(path = "hosts/add_dialog.htm")]
struct AddHostDialog {
    hosts: Vec<Host>,
}

#[get("/add")]
async fn add_host_dialog(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    Ok(
        match web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await? {
            Ok(hosts) => {
                FormResponseBuilder::dialog("Add a new Host", "/host/add", AddHostDialog { hosts })
            }
            Err(error) => FormResponseBuilder::error(error),
        },
    )
}

// NOTE: im not sure if it is a good idea to use the same struct as template and form
#[derive(Template, Deserialize)]
#[template(path = "hosts/authorize_user_dialog.htm")]
struct AuthorizeUserDialog {
    host_id: u32,
    host_name: String,
}

#[get("/authorize")]
async fn authorize_user_dialog(form: web::Query<AuthorizeUserDialog>) -> impl Responder {
    FormResponseBuilder::dialog(
        "Authorize a user on this host",
        "/host/user/authorize",
        form.0,
    )
}

#[derive(Template)]
#[template(path = "hosts/hostkey_dialog.htm")]
struct HostkeyDialog {
    host_name: String,
    login: String,
    address: String,
    port: u16,
    key_fingerprint: String,
    jumphost: Option<i32>,
}

#[derive(Deserialize)]
struct HostAddForm {
    host_name: String,
    login: String,
    address: String,
    port: u16,
    jumphost: Option<i32>,
    key_fingerprint: Option<String>,
}

#[post("/add")]
async fn add_host(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    form: web::Form<HostAddForm>,
) -> actix_web::Result<impl Responder> {
    let form = form.0;

    let jumphost = form
        .jumphost
        .and_then(|host| if host < 0 { None } else { Some(host) });

    let handler = SshFirstConnectionHandler::new(
        Arc::clone(&conn),
        form.host_name.clone(),
        form.login.clone(),
        form.address.clone(),
        form.port,
        jumphost,
    )
    .await;

    let handler = match handler {
        Ok(handler) => handler,
        Err(e) => {
            return Ok(FormResponseBuilder::error(e.to_string()));
        }
    };

    let Some(key_fingerprint) = form.key_fingerprint else {
        let res = handler.get_hostkey(ssh_client.into_inner()).await;

        let recv_result = match res {
            Ok(receiver) => receiver.await,
            Err(e) => {
                return Ok(FormResponseBuilder::error(e.to_string()));
            }
        };

        let key_fingerprint = match recv_result {
            Ok(key_fingerprint) => key_fingerprint,
            Err(e) => {
                error!("Error receiving key: {e}");
                return Ok(FormResponseBuilder::error(e.to_string()));
            }
        };

        return Ok(FormResponseBuilder::dialog(
            "Please check the hostkey",
            "/host/add",
            HostkeyDialog {
                host_name: form.host_name,
                login: form.login,
                address: form.address,
                port: form.port,
                jumphost: form.jumphost,
                key_fingerprint,
            },
        ));
    };

    // We already have a hostkey, check it
    let handler = handler.set_hostkey(key_fingerprint.clone());
    let res = handler.try_authenticate(&ssh_client).await;
    match res {
        Ok(()) => {}
        Err(e) => {
            return Ok(FormResponseBuilder::error(e.to_string()));
        }
    };

    let new_host = NewHost {
        name: form.host_name.clone(),
        address: form.address,
        port: form.port.into(),
        username: form.login,
        key_fingerprint,
        jump_via: jumphost.map(|id| id),
    };
    let res = web::block(move || Host::add_host(&mut conn.get().unwrap(), &new_host)).await?;

    Ok(match res {
        Ok(id) => match ssh_client.install_script_on_host(id).await {
            Ok(()) => FormResponseBuilder::created(String::from("Added host"))
                .close_modal()
                .add_trigger(String::from("reload-hosts")),
            Err(error) => FormResponseBuilder::error(format!("Failed to install script: {error}")),
        },
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(Template)]
#[template(path = "hosts/list.htm")]
struct RenderHostsTemplate {
    hosts: Vec<Host>,
}

#[get("/list.htm")]
async fn render_hosts(conn: Data<ConnectionPool>) -> actix_web::Result<impl Responder> {
    let all_hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;

    Ok(match all_hosts {
        Ok(hosts) => RenderHostsTemplate { hosts }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Deserialize)]
struct AuthorizeUserForm {
    host_id: i32,
    user_id: i32,
    login: String,
    options: Option<String>,
}

#[post("/user/authorize")]
async fn authorize_user(
    conn: Data<ConnectionPool>,

    form: web::Form<AuthorizeUserForm>,
) -> actix_web::Result<impl Responder> {
    let res = web::block(move || {
        Host::authorize_user(
            &mut conn.get().unwrap(),
            form.host_id,
            form.user_id,
            form.login.clone(),
            form.options.clone(),
        )
    })
    .await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::success("Authorized user")
            .close_modal()
            .add_trigger("reloadDiff")
            .add_trigger("reload-authorizations"),
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(Deserialize)]
struct GenAuthorizedKeysForm {
    host_name: String,
    login: String,
}

#[derive(Template)]
#[template(path = "hosts/authorized_keyfile_dialog.htm")]
struct AuthorizedKeyfileDialog {
    login: String,
    authorized_keys: String,
    diff: Vec<KeyDiffItem>,
}

#[post("/gen_authorized_keys")]
async fn gen_authorized_keys(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    form: web::Form<GenAuthorizedKeysForm>,
) -> actix_web::Result<impl Responder> {
    let host_name = &form.host_name;
    let login = &form.login;

    let authorized_keys = match Host::get_from_name(conn.get().unwrap(), host_name.to_owned()).await
    {
        Err(error) => {
            return Ok(FormResponseBuilder::error(error));
        }
        Ok(None) => {
            return Ok(FormResponseBuilder::error("No such host.".to_owned()));
        }
        Ok(Some(host)) => {
            host.get_authorized_keys_file_for(&ssh_client, &mut conn.get().unwrap(), login.as_ref())
        }
    };

    let authorized_keys = match authorized_keys {
        Ok(keys) => keys,
        Err(error) => {
            return Ok(FormResponseBuilder::error(error));
        }
    };

    let Ok(key_diff) = ssh_client
        .key_diff(authorized_keys.as_ref(), host_name.clone(), login.clone())
        .await
    else {
        return Ok(FormResponseBuilder::error(
            "Couldn't calculate key diff".to_owned(),
        ));
    };

    Ok(FormResponseBuilder::dialog(
        format!("These changes will be applied for '{login}' on '{host_name}':"),
        format!("/host/{host_name}/set_authorized_keys"),
        AuthorizedKeyfileDialog {
            login: login.to_owned(),
            diff: key_diff,
            authorized_keys,
        },
    ))
}

#[derive(Deserialize)]
struct SetAuthorizedKeysForm {
    login: String,
    authorized_keys: String,
}

#[post("/{name}/set_authorized_keys")]
async fn set_authorized_keys(
    form: web::Form<SetAuthorizedKeysForm>,
    host: Path<String>,
    ssh_client: Data<SshClient>,
) -> actix_web::Result<impl Responder> {
    let res = ssh_client
        .set_authorized_keys(
            host.to_string(),
            form.login.clone(),
            form.authorized_keys.clone(),
        )
        .await;

    Ok(match res {
        Ok(()) => FormResponseBuilder::success(String::from("Applied authorized_keys"))
            .add_trigger("reloadDiff".to_owned()),
        Err(error) => FormResponseBuilder::error(error.to_string()),
    })
}

#[derive(Template)]
#[template(path = "hosts/delete_dialog.htm")]
struct DeleteHostTemplate {
    authorizations: Vec<UserAndOptions>,
    affected_hosts: Vec<String>,
}

#[derive(Deserialize)]
struct HostDeleteForm {
    #[serde(default)]
    confirm: bool,
}

#[post("/{name}/delete")]
async fn delete(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    form: web::Form<HostDeleteForm>,
    host_name: Path<String>,
) -> impl Responder {
    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_owned()).await {
        Ok(None) => {
            return FormResponseBuilder::error("Host not found".to_owned());
        }
        Err(error) => {
            return FormResponseBuilder::error(format!("Database error: {error}"));
        }
        Ok(Some(host)) => host,
    };

    if form.confirm {
        return match host.delete(&mut conn.get().unwrap()) {
            Ok(amt) => {
                caching_ssh_client.remove(host_name.as_str()).await;
                return FormResponseBuilder::success(format!("Deleted {amt} record(s)"))
                    .with_redirect("/host");
            }
            Err(e) => FormResponseBuilder::error(format!("Failed to delete host: {e}")),
        };
    }

    let mut connection = conn.get().unwrap();

    let res = host
        .get_authorized_users(&mut connection)
        .and_then(|authorizations| {
            host.get_dependant_hosts(&mut connection)
                .map(|hosts| (authorizations, hosts))
        });

    // TODO: resolve authorizations of dependant hosts
    match res {
        Ok((authorizations, affected_hosts)) => FormResponseBuilder::dialog(
            format!("In addition to {host_name}, these entries will be affected"),
            format!("/host/{host_name}/delete"),
            DeleteHostTemplate {
                authorizations,
                affected_hosts,
            },
        ),
        Err(error) => FormResponseBuilder::error(format!("Failed to get authorizations: {error}")),
    }
}

#[derive(askama_actix::Template)]
#[template(path = "hosts/list_authorizations.htm")]
struct ListHostAuthorizations {
    authorizations: Vec<UserAndOptions>,
}

#[get("/{name}/authorizations.htm")]
async fn list_host_authorizations(
    host_name: actix_web::web::Path<String>,
    conn: Data<ConnectionPool>,
) -> actix_web::Result<impl Responder> {
    let host = Host::get_from_name(conn.get().unwrap(), host_name.to_string())
        .await
        .unwrap()
        .unwrap();
    let res = web::block(move || host.get_authorized_users(&mut conn.get().unwrap())).await?;

    Ok(match res {
        Ok(authorizations) => ListHostAuthorizations { authorizations }.to_response(),
        Err(error) => RenderErrorTemplate { error }.to_response(),
    })
}

#[derive(Deserialize)]
struct DeleteAuthorizationForm {
    authorization_id: i32,
}

#[post("/delete_authorization")]
async fn delete_authorization(
    form: web::Form<DeleteAuthorizationForm>,
    conn: Data<ConnectionPool>,
) -> actix_web::Result<impl Responder> {
    let res = web::block(move || {
        let mut connection = conn.get().unwrap();

        Host::delete_authorization(&mut connection, form.authorization_id)
    })
    .await?;

    Ok(match res {
        Ok(()) => FormResponseBuilder::success("Deleted authorization.".to_owned())
            .add_trigger("reload-authorizations".to_owned()),
        Err(e) => FormResponseBuilder::error(e),
    })
}

#[derive(askama_actix::Template)]
#[template(path = "hosts/edit_host.html")]
struct EditHostTemplate {
    host: Host,
}

#[get("/{name}/edit")]
async fn edit_host_form(
    conn: actix_web::web::Data<crate::ConnectionPool>,
    host_name: actix_web::web::Path<String>,
) -> actix_web::Result<impl actix_web::Responder> {
    let host_result = Host::get_from_name(conn.get().unwrap(), host_name.to_string())
        .await
        .map_err(FormResponseBuilder::error)?;

    Ok(match host_result {
        Some(host) => FormResponseBuilder::dialog(
            "Edit host",
            format!("/host/{host_name}/edit"),
            EditHostTemplate { host },
        ),
        None => FormResponseBuilder::error("No such host"),
    })
}

// Custom deserialization to treat empty strings as None
fn empty_string_as_none<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    if s.trim().is_empty() {
        Ok(None)
    } else {
        Ok(Some(s))
    }
}

fn empty_string_as_none_int<'de, D>(deserializer: D) -> Result<Option<i32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    if s.trim().is_empty() {
        Ok(None)
    } else {
        s.parse::<i32>().map(Some).map_err(serde::de::Error::custom)
    }
}

#[derive(serde::Deserialize)]
struct EditHostForm {
    name: String,
    address: String,
    username: String,
    port: i32,
    #[serde(deserialize_with = "empty_string_as_none")]
    key_fingerprint: Option<String>,
    #[serde(deserialize_with = "empty_string_as_none_int")]
    jump_via: Option<i32>,
}

#[post("/{name}/edit")]
async fn edit_host(
    conn: actix_web::web::Data<crate::ConnectionPool>,
    host_name: actix_web::web::Path<String>,
    form: actix_web::web::Form<EditHostForm>,
) -> actix_web::Result<impl actix_web::Responder> {
    let mut db_conn = conn.get().unwrap();
    Ok(
        match Host::update_host(
            &mut db_conn,
            host_name.to_string(),
            form.name.clone(),
            form.address.clone(),
            form.username.clone(),
            form.port,
            form.key_fingerprint.clone(),
            form.jump_via,
        ) {
            Ok(()) => FormResponseBuilder::success("Updated host.")
                .with_redirect(format!("/host/{}", form.name)),
            Err(e) => FormResponseBuilder::error(e),
        },
    )
}
