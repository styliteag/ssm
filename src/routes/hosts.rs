use actix_web::{
    get, post,
    web::{self, Data, Path},
    Responder,
};
use askama_actix::{Template, TemplateToResponse};
use log::{debug, info};
use serde::Deserialize;

use crate::{
    db::UserAndOptions,
    forms::{FormResponseBuilder, Modal},
    routes::{should_update, ErrorTemplate, ForceUpdate, RenderErrorTemplate},
    ssh::{CachingSshClient, ConnectionDetails, KeyDiffItem, SshClient, SshClientError},
    ConnectionPool, DbConnection,
};

use crate::models::{Host, NewHost, User};

pub fn hosts_config(cfg: &mut web::ServiceConfig) {
    cfg.service(hosts_page)
        .service(render_hosts)
        .service(show_host)
        .service(get_logins)
        .service(add_host)
        .service(authorize_user)
        .service(gen_authorized_keys)
        .service(set_authorized_keys)
        .service(add_host_key)
        .service(delete)
        .service(delete_authorization)
        .service(edit_host_form)
        .service(edit_host);
}

#[derive(Template)]
#[template(path = "hosts/index.html")]
struct HostsTemplate {}

#[get("")]
async fn hosts_page() -> impl Responder {
    HostsTemplate {}
}

type HostData = (Host, Option<String>, Vec<UserAndOptions>, Vec<User>);

enum HostDataError {
    HostNotFound,
    DatabaseError(String),
}

fn get_all_host_data(conn: &mut DbConnection, host: String) -> Result<HostData, HostDataError> {
    let maybe_host = Host::get_from_name_sync(conn, host).map_err(HostDataError::DatabaseError)?;

    let Some(host) = maybe_host else {
        return Err(HostDataError::HostNotFound);
    };

    let jumphost = if let Some(id) = host.jump_via {
        Host::get_from_id_sync(conn, id)
            .map_err(HostDataError::DatabaseError)?
            .map(|h| h.name)
    } else {
        None
    };

    let authorized_users = host
        .get_authorized_users(conn)
        .map_err(HostDataError::DatabaseError)?;

    // Skip getting users if we can't connect
    if host.key_fingerprint.is_none() {
        return Ok((host, jumphost, authorized_users, vec![]));
    }

    let user_list = User::get_all_users(conn).map_err(HostDataError::DatabaseError)?;

    Ok((host, jumphost, authorized_users, user_list))
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
    authorized_users: Vec<UserAndOptions>,
    user_list: Vec<User>,
}

#[get("/{name}")]
async fn show_host(
    conn: Data<ConnectionPool>,
    host: Path<String>,
) -> actix_web::Result<impl Responder> {
    let res =
        web::block(move || get_all_host_data(&mut conn.get().unwrap(), host.to_string())).await?;

    let (host, jumphost, authorized_users, user_list) = match res {
        Ok(host_data) => host_data,
        Err(e) => {
            return Ok(match e {
                HostDataError::HostNotFound => ErrorTemplate {
                    error: String::from("Host not found"),
                }
                .to_response(),
                HostDataError::DatabaseError(e) => ErrorTemplate { error: e }.to_response(),
            });
        }
    };

    Ok(ShowHostTemplate {
        host,
        jumphost,
        authorized_users,
        user_list,
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
    let cloned_conn = conn.clone();

    let host = match Host::get_from_id(conn.get().unwrap(), *host_id).await {
        Ok(h) => h,
        Err(e) => return Ok(FormResponseBuilder::error(e)),
    };

    match host {
        Some(host) => {
            if let Some(ref new_hostkey) = new_hostkey.key_fingerprint {
                let res =
                    host.update_fingerprint(&mut cloned_conn.get().unwrap(), new_hostkey.clone());
                return Ok(match res {
                    Ok(()) => FormResponseBuilder::created("Added hostkey".to_owned())
                        .add_trigger("reloadDiff".to_owned()),
                    Err(e) => FormResponseBuilder::error(e),
                });
            }

            let target = host.to_connection().unwrap();
            let maybe_jumphost = host
                .jump_via
                .map(|jump| Host::get_from_id_sync(&mut cloned_conn.get().unwrap(), jump));

            let connection_res = match maybe_jumphost {
                Some(Ok(None)) => {
                    return Ok(FormResponseBuilder::error("Jump host not found".to_owned()));
                }
                Some(Err(e)) => {
                    return Ok(FormResponseBuilder::error(e));
                }
                Some(Ok(Some(jump))) => ssh_client.get_hostkey_via(jump, target).await,
                None => ssh_client.get_hostkey(target).await,
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

            Ok(FormResponseBuilder::dialog(Modal {
                title: "Check the hostkey".to_owned(),
                request_target: format!("/hosts/{}/add_hostkey", host.id),
                template: HostkeyDialog {
                    name: host.name,
                    username: host.username,
                    address: host.address,
                    port: host.port,
                    jumphost: host.jump_via,
                    key_fingerprint,
                }
                .to_string(),
            }))
        }
        None => Ok(FormResponseBuilder::not_found(
            "Couldn't find host".to_owned(),
        )),
    }
}

#[derive(Template)]
#[template(path = "hosts/hostkey_dialog.htm")]
struct HostkeyDialog {
    name: String,
    username: String,
    address: String,
    port: i32,
    key_fingerprint: String,
    jumphost: Option<i32>,
}

#[derive(Deserialize)]
struct HostAddForm {
    name: String,
    username: String,
    address: String,
    port: i32,
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

    // TODO: better error handling for jumphost (serde deserialize opt)
    let cloned_conn = conn.clone();
    let maybe_jumphost: Option<Host> = if let Some(via) = form.jumphost {
        if via < 0 {
            None
        } else {
            match Host::get_from_id(cloned_conn.get().unwrap(), via).await {
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
    let Ok(address) = ConnectionDetails::new_from_signed(form.address.clone(), form.port) else {
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
                address: form.address,
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
        address: form.address,
        port: form.port,
        username: form.username,
        key_fingerprint,
        jump_via: maybe_jumphost.map(|h| h.id),
    };
    let res = web::block(move || Host::add_host(&mut conn.get().unwrap(), &new_host)).await?;

    Ok(match res {
        Ok(id) => match ssh_client.install_script_on_host(id).await {
            Ok(()) => FormResponseBuilder::created(String::from("Added host"))
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
        Ok(all_hosts) => RenderHostsTemplate { hosts: all_hosts }.to_response(),
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
        Ok(()) => FormResponseBuilder::success(String::from("Authorized user"))
            .add_trigger("reloadDiff".to_owned()),
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

    Ok(FormResponseBuilder::dialog(Modal {
        title: format!("These changes will be applied for '{login}' on '{host_name}':"),
        request_target: format!("/hosts/{host_name}/set_authorized_keys"),
        template: AuthorizedKeyfileDialog {
            login: login.to_owned(),
            diff: key_diff,
            authorized_keys,
        }
        .to_string(),
    }))
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
                return FormResponseBuilder::success(format!("Deleted {amt} record(s)"));
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
        Ok((authorizations, affected_hosts)) => FormResponseBuilder::dialog(Modal {
            title: format!("In addition to {host_name}, these entries will be affected"),
            request_target: format!("/hosts/{host_name}/delete"),
            template: DeleteHostTemplate {
                authorizations,
                affected_hosts,
            }
            .to_string(),
        }),
        Err(error) => FormResponseBuilder::error(format!("Failed to get authorizations: {error}")),
    }
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
    host: EditHostView,
}

// A view model for rendering the edit host form with types that implement Display
struct EditHostView {
    name: String,
    address: String,
    username: String,
    port: i32,
    key_fingerprint: String,
    jump_via: String,
}

#[get("/{name}/edit")]
async fn edit_host_form(
    conn: actix_web::web::Data<crate::ConnectionPool>,
    host_name: actix_web::web::Path<String>,
) -> actix_web::Result<impl actix_web::Responder> {
    let host_result = crate::models::Host::get_from_name(conn.get().unwrap(), host_name.to_string())
        .await
        .map_err(actix_web::error::ErrorInternalServerError)?;

    if let Some(host) = host_result {
        debug!("ssm::routes::hosts: Display edit form for host {}", host.name);
        let view = EditHostView {
            name: host.name,
            address: host.address,
            username: host.username,
            port: host.port,
            key_fingerprint: host.key_fingerprint.unwrap_or_default(),
            jump_via: host.jump_via.map(|v| v.to_string()).unwrap_or_default(),
        };
        Ok(EditHostTemplate { host: view }.to_response())
    } else {
        Ok(crate::routes::ErrorTemplate { error: "Host not found".to_string() }.to_response())
    }
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
    match crate::models::Host::update_host(
        &mut db_conn,
        host_name.to_string(),
        form.name.clone(),
        form.address.clone(),
        form.username.clone(),
        form.port,
        form.key_fingerprint.clone(),
        form.jump_via,
    ) {
        Ok(()) => {
            info!("ssm::routes::hosts: Host {} updated successfully", host_name);
            Ok(actix_web::HttpResponse::Found().append_header(("Location", "/hosts")).finish())
        },
        Err(e) => Ok(crate::routes::ErrorTemplate { error: e.to_string() }.to_response()),
    }
}
