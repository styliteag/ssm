use askama::Template;

use crate::sshclient::AuthorizedKey;

pub(crate) trait AsHTML {
    fn as_html(&self) -> String;
}

#[derive(Template)]
#[template(path = "components/authorizedkey.htm")]
struct AuthorizedKeyTemplate {
    key: AuthorizedKey,
}

impl AsHTML for AuthorizedKey {
    fn as_html(&self) -> String {
        AuthorizedKeyTemplate { key: self.clone() }.to_string()
    }
}
