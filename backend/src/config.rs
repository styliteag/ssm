use std::{env, net::IpAddr, path::PathBuf, time::Duration};
use config::Config;
use croner::Cron;
use serde::Deserialize;

const fn default_timeout() -> Duration {
    Duration::from_secs(120)
}

fn deserialize_timeout<'de, D>(deserializer: D) -> Result<Duration, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let seconds = u64::deserialize(deserializer)?;
    Ok(Duration::from_secs(seconds))
}

fn deserialize_cron<'de, D>(deserializer: D) -> Result<Option<Cron>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let mut pat = String::deserialize(deserializer)?;

    // Set seconds to 0 if omitted
    // tokio-cron-scheduler only works with seconds.
    let num_parts = pat.split_whitespace().count();
    if num_parts == 5 {
        pat = format!("0 {pat}");
    }

    match Cron::new(pat.as_str()).with_seconds_required().parse() {
        Ok(cron) => Ok(Some(cron)),
        Err(e) => {
            eprintln!("Failed to parse Cron syntax '{pat}': {e}");
            std::process::exit(3);
        }
    }
}

fn no_cron() -> Option<Cron> {
    None
}

#[derive(Debug, Deserialize, Clone)]
pub struct SshConfig {
    /// Cron schedule when to check Hosts (default disabled)
    /// In the future this will trigger some sort of action
    /// e.g. send an Email
    #[serde(default = "no_cron", deserialize_with = "deserialize_cron")]
    pub check_schedule: Option<Cron>,

    /// Cron schedule when update the cache (default disabled)
    #[serde(default = "no_cron", deserialize_with = "deserialize_cron")]
    pub update_schedule: Option<Cron>,

    /// Path to an OpenSSH Private Key
    #[serde(default = "default_private_key_file")]
    pub private_key_file: PathBuf,
    /// Passphrase for the key
    pub private_key_passphrase: Option<String>,
    /// Connection timeout in seconds (default 2m)
    #[serde(default = "default_timeout", deserialize_with = "deserialize_timeout")]
    pub timeout: Duration,
}

fn default_database_url() -> String {
    "sqlite://ssm.db".to_owned()
}

const fn default_listen() -> IpAddr {
    use core::net::Ipv6Addr;
    IpAddr::V6(Ipv6Addr::UNSPECIFIED)
}

const fn default_port() -> u16 {
    8000
}

fn default_loglevel() -> String {
    "info".to_owned()
}

fn default_htpasswd_path() -> PathBuf {
    PathBuf::from(".htpasswd")
}

fn default_private_key_file() -> PathBuf {
    PathBuf::from("keys/id_ssm")
}

fn default_ssh_config() -> SshConfig {
    SshConfig {
        check_schedule: None,
        update_schedule: None,
        private_key_file: default_private_key_file(),
        private_key_passphrase: None,
        timeout: default_timeout(),
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct Configuration {
    #[serde(default = "default_ssh_config")]
    pub ssh: SshConfig,
    #[serde(default = "default_database_url")]
    pub database_url: String,
    #[serde(default = "default_listen")]
    pub listen: IpAddr,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_loglevel")]
    pub loglevel: String,
    pub session_key: Option<String>,
    #[serde(default = "default_htpasswd_path")]
    pub htpasswd_path: PathBuf,
}

pub fn get_configuration() -> Result<(Configuration, String), String> {
    let config_path = env::var("CONFIG").unwrap_or_else(|_| String::from("./config.toml"));
    let config_builder = Config::builder();

    let (config_builder, config_source) = if std::path::Path::new(&config_path).exists() {
        use config::FileFormat::Toml;
        (
            config_builder.add_source(config::File::new(&config_path, Toml).required(false)),
            format!("Loading configuration from '{}'", &config_path),
        )
    } else {
        (
            config_builder,
            format!("No configuration file found at '{}'", &config_path),
        )
    };

    // Environment variables take precedence over config file settings
    let mut config: Configuration = config_builder
        .add_source(config::Environment::default())
        .build()
        .map_err(|e| format!("Error while reading configuration source: {e}"))?
        .try_deserialize()
        .map_err(|e| format!("Error while parsing configuration: {e}"))?;

    // Override with specific environment variables that don't follow config crate naming conventions
    if let Ok(htpasswd_path) = std::env::var("HTPASSWD") {
        config.htpasswd_path = std::path::PathBuf::from(htpasswd_path);
    }
    if let Ok(ssh_key_path) = std::env::var("SSH_KEY") {
        config.ssh.private_key_file = std::path::PathBuf::from(ssh_key_path);
    }
    if let Ok(session_key) = std::env::var("SESSION_KEY") {
        config.session_key = Some(session_key);
    }

    Ok((config, config_source))
}

