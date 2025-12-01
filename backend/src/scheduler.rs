use std::sync::Arc;

use croner::Cron;
use futures::{future::BoxFuture, FutureExt};
use log::{error, info};
use tokio_cron_scheduler::{JobBuilder, JobScheduler, JobSchedulerError};

use crate::ssh::CachingSshClient;

fn init_job(schedule: Cron) -> JobBuilder<chrono::Utc> {
    let mut job_builder = JobBuilder::new().with_cron_job_type();
    job_builder.schedule = Some(schedule);
    job_builder
}

pub(super) async fn init_scheduler(
    check_schedule: Option<Cron>,
    update_schedule: Option<Cron>,
    ssh_client: Arc<CachingSshClient>,
) -> Option<BoxFuture<'static, Result<(), JobSchedulerError>>> {
    if check_schedule.is_none() && update_schedule.is_none() {
        info!("Skipping scheduler initialization, no schedule configured");
        return None;
    }

    let mut sched = match JobScheduler::new().await {
        Ok(s) => s,
        Err(e) => {
            error!("Failed to create job scheduler: {}", e);
            return None;
        }
    };

    info!("Initializing scheduler");
    if let Err(e) = sched.init().await {
        error!("Couldn't initialize job scheduler: {}", e);
        return None;
    }

    if let Some(check_schedule) = check_schedule {
        let client = ssh_client.clone();

        let mut job = init_job(check_schedule.clone());
        job = job.with_run_async(Box::new(move |uuid, mut sched| {
            let client = client.clone();
            Box::pin(async move {
                info!("Running check job");
                match client.get_current_state().await {
                    Ok(_data) => {
                        let next = sched.next_tick_for_job(uuid).await;
                        match next {
                            Ok(Some(next_tick)) => {
                                info!("Succeeded check job. Next run: {}", next_tick);
                            }
                            Ok(None) => {
                                info!("Succeeded check job. Won't run again.");
                            }
                            Err(e) => {
                                info!("Succeeded check job. Error finding next time: {e}");
                            }
                        }
                        // TODO: do something with data
                    }
                    Err(e) => {
                        error!("Failed check job: {e}");
                    }
                };
            })
        }));

        let built_job = match job.build() {
            Ok(j) => j,
            Err(e) => {
                error!("Failed to build check job: {}", e);
                return None;
            }
        };
        if let Err(e) = sched.add(built_job).await {
            error!("Failed to create check job: {}", e);
            return None;
        }
        info!("Scheduled check job: '{}'", check_schedule.pattern);
    }

    if let Some(update_schedule) = update_schedule {
        let mut job = init_job(update_schedule.clone());
        job = job.with_run_async(Box::new(move |uuid, mut sched| {
            let client = ssh_client.clone();
            Box::pin(async move {
                info!("Running update job");
                match client.get_current_state().await {
                    Ok(_) => {
                        let next = sched.next_tick_for_job(uuid).await;
                        match next {
                            Ok(Some(next_tick)) => {
                                info!("Succeeded update job. Next run: {}", next_tick);
                            }
                            Ok(None) => {
                                info!("Succeeded update job. Won't run again.");
                            }
                            Err(e) => {
                                info!("Succeeded update job. Error finding next time: {e}");
                            }
                        }
                    }
                    Err(e) => {
                        error!("Failed update job: {e}");
                    }
                };
            })
        }));

        let built_job = match job.build() {
            Ok(j) => j,
            Err(e) => {
                error!("Failed to build update job: {}", e);
                return None;
            }
        };
        if let Err(e) = sched.add(built_job).await {
            error!("Failed to create update job: {}", e);
            return None;
        }
        info!("Scheduled update job: '{}'", update_schedule.pattern);
    }
    Some(
        async move {
            info!("Starting scheduler");
            sched.start().await
        }
        .boxed(),
    )
}
