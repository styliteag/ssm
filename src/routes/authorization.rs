use actix_web::{
    post,
    web::{self, Data},
    Responder,
};
use askama::Template;
use serde::Deserialize;

use crate::{
    forms::{FormResponseBuilder, Modal},
    models::{Host, User},
    ConnectionPool,
};

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(change_options).service(authorize_user_dialog);
}

// #[derive(Deserialize)]
// struct ChangeOptionsForm {
//     authorization_id: i32,
// }
// TODO: do this

#[post("/change_options")]
async fn change_options(// form: web::Form<DeleteAuthorizationForm>,
    // conn: Data<ConnectionPool>,
) -> actix_web::Result<impl Responder> {
    // let res = web::block(move || {
    //     let mut connection = conn.get().unwrap();

    //     Host::delete_authorization(&mut connection, form.authorization_id)
    // })
    // .await?;
    Ok(FormResponseBuilder::error("Not implemented".to_owned()))

    // Ok(match res {
    //     Ok(()) => FormResponseBuilder::success("Deleted authorization.".to_owned())
    //         .add_trigger("reload-authorizations".to_owned()),
    //     Err(e) => FormResponseBuilder::error(e),
    // })
}

#[derive(Template)]
#[template(path = "diff/authorize_user_dialog.htm")]
struct AuthorizeUserDialog {
    host: (String, i32),
    user: (String, i32),
    options: Option<String>,
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
    /// The key options which are already set
    options: Option<String>,
}

#[post("/add_dialog")]
async fn authorize_user_dialog(
    conn: Data<ConnectionPool>,
    form: web::Form<AuthorizeUserForm>,
) -> actix_web::Result<impl Responder> {
    let options = form.options.clone();
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
        // TODO: move this
        request_target: String::from("/host/user/authorize"),
        template: AuthorizeUserDialog {
            host,
            user,
            login,
            options,
        }
        .to_string(),
    })
    .add_trigger("reload-authorizations"))
}
