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

    let mut sched = JobScheduler::new()
        .await
        .expect("Failed to create job scheduler");

    info!("Initializing scheduler");
    if let Err(e) = sched.init().await {
        panic!("Couldn't initialize job scheduler: {e}")
    };

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

        sched
            .add(job.build().expect("Failed to build check job"))
            .await
            .expect("Failed to create check job");
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

        sched
            .add(job.build().expect("Failed to build update job"))
            .await
            .expect("Failed to create update job");
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
