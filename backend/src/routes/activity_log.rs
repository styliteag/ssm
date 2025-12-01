use actix_web::{get, web, HttpResponse, Responder};
use diesel::prelude::*;
use serde::{Deserialize, Serialize};
use utoipa::{ToSchema, IntoParams};

use crate::models::ActivityLog;
use crate::ConnectionPool;
use crate::api_types::ApiResponse;

#[derive(Serialize, ToSchema)]
pub struct ActivityResponse {
    id: i32,
    #[serde(rename = "type")]
    activity_type: String,
    action: String,
    target: String,

    user: String,
    timestamp: String,
    metadata: Option<serde_json::Value>,
}

impl From<ActivityLog> for ActivityResponse {
    fn from(log: ActivityLog) -> Self {
        // Convert Unix timestamp to relative time string
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i32;
        
        let diff = now - log.timestamp;
        let timestamp = if diff < 60 {
            format!("{} secs ago", diff)
        } else if diff < 3600 {
            format!("{} mins ago", diff / 60)
        } else if diff < 86400 {
            format!("{} hours ago", diff / 3600)
        } else {
            format!("{} days ago", diff / 86400)
        };

        Self {
            id: log.id,
            activity_type: log.activity_type,
            action: log.action,
            target: log.target,
            user: log.actor_username,

            timestamp,
            metadata: log.metadata.and_then(|m| serde_json::from_str(&m).ok()),
        }
    }
}

#[derive(Deserialize, IntoParams)]
pub struct ActivityQueryParams {
    /// Maximum number of activities to return (default: 10, max: 100)
    #[serde(default = "default_limit")]
    limit: i32,
    /// Filter by activity type (key, host, user, auth)
    activity_type: Option<String>,
}

fn default_limit() -> i32 {
    10
}

/// Get recent system activities
#[utoipa::path(
    get,
    path = "/api/activities",
    tag = "activities",
    params(
        ActivityQueryParams
    ),
    responses(
        (status = 200, description = "List of recent activities", body = Vec<ActivityResponse>),
        (status = 500, description = "Internal server error")
    )
)]
#[get("/activities")]
pub async fn get_activities(
    pool: web::Data<ConnectionPool>,
    query: web::Query<ActivityQueryParams>,
) -> impl Responder {
    use crate::schema::activity_log::dsl::*;

    let mut conn = match pool.get() {
        Ok(conn) => conn,
        Err(e) => {
            log::error!("Failed to get DB connection: {}", e);
            return HttpResponse::InternalServerError().json(serde_json::json!({
                "error": "Database connection failed"
            }));
        }
    };

    // Ensure limit is within bounds
    let query_limit = query.limit.min(100).max(1);

    let mut query_builder = activity_log.into_boxed();

    // Apply type filter if provided
    if let Some(ref filter_type) = query.activity_type {
        query_builder = query_builder.filter(activity_type.eq(filter_type));
    }

    let results = query_builder
        .order(timestamp.desc())
        .limit(query_limit as i64)
        .load::<ActivityLog>(&mut conn);

    match results {
        Ok(logs) => {
            let activities: Vec<ActivityResponse> = logs.into_iter().map(|log| log.into()).collect();
            HttpResponse::Ok().json(ApiResponse::success(activities))
        }
        Err(e) => {
            log::error!("Failed to query activities: {}", e);
            HttpResponse::InternalServerError().json(serde_json::json!({
                "error": "Failed to retrieve activities"
            }))
        }
    }
}

/// Helper function to log an activity
pub fn log_activity(
    conn: &mut crate::DbConnection,
    activity_type_str: &str,
    action_str: &str,
    target_str: &str,

    actor: &str,
    metadata: Option<String>,
) -> Result<(), diesel::result::Error> {
    use crate::models::NewActivityLog;
    use crate::schema::activity_log;

    let mut new_log = NewActivityLog::new(
        activity_type_str.to_string(),
        action_str.to_string(),
        target_str.to_string(),
        actor.to_string(),
    );

    if let Some(m) = metadata {
        new_log = new_log.with_metadata(m);
    }

    diesel::insert_into(activity_log::table)
        .values(&new_log)
        .execute(conn)?;

    Ok(())
}

pub fn configure(cfg: &mut web::ServiceConfig) {
    cfg.service(get_activities);
}
