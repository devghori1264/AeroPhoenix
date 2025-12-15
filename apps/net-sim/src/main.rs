use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::convert::Infallible;
use std::env;
use std::sync::Arc;
use tokio::sync::RwLock;
use warp::Filter;

#[derive(Deserialize, Serialize)]
struct ChaosReq {
    region: String,
    latency_ms: Option<u64>,
}

#[derive(Deserialize, Serialize, Clone)]
struct ChaosInjectReq {
    id: String,
    kind: String,
    target: Option<String>,
    severity: f64,
    payload: serde_json::Value,
}

#[derive(Deserialize, Serialize)]
struct ChaosHealReq {
    id: String,
}

#[derive(Serialize)]
struct GenericResp {
    status: String,
}

#[derive(Clone)]
struct ChaosState {
    active_incidents: Arc<RwLock<HashMap<String, ChaosInjectReq>>>,
}

#[tokio::main]
async fn main() {
    env_logger::init();

    let base = env::var("FLYD_SIM_BASE").unwrap_or_else(|_| "http://flyd-sim:8080".into());
    let client = Client::new();

    let chaos_state = ChaosState {
        active_incidents: Arc::new(RwLock::new(HashMap::new())),
    };

    let client_filter = warp::any().map(move || client.clone());
    let base_filter = warp::any().map(move || base.clone());
    let chaos_state_filter = warp::any().map(move || chaos_state.clone());

    let partition = warp::post()
        .and(warp::path!("v1" / "partition"))
        .and(warp::body::json())
        .and(client_filter.clone())
        .and(base_filter.clone())
        .and_then(handle_partition);

    let heal = warp::post()
        .and(warp::path!("v1" / "heal"))
        .and(warp::body::json())
        .and(client_filter.clone())
        .and(base_filter.clone())
        .and_then(handle_heal);

    let latency = warp::post()
        .and(warp::path!("v1" / "latency"))
        .and(warp::body::json())
        .and(client_filter)
        .and(base_filter)
        .and_then(handle_latency);

    let chaos_inject = warp::post()
        .and(warp::path!("chaos" / "inject"))
        .and(warp::body::json())
        .and(chaos_state_filter.clone())
        .and_then(handle_chaos_inject);

    let chaos_heal_route = warp::post()
        .and(warp::path!("chaos" / "heal"))
        .and(warp::body::json())
        .and(chaos_state_filter.clone())
        .and_then(handle_chaos_heal);

    let health = warp::get().and(warp::path("health")).map(|| {
        warp::reply::json(&GenericResp {
            status: "ok".into(),
        })
    });

    let chaos_status = warp::get()
        .and(warp::path!("chaos" / "status"))
        .and(chaos_state_filter)
        .and_then(handle_chaos_status);

    let routes = partition
        .or(heal)
        .or(latency)
        .or(chaos_inject)
        .or(chaos_heal_route)
        .or(health)
        .or(chaos_status);

    println!("net-sim running at http://0.0.0.0:7070");
    warp::serve(routes).run(([0, 0, 0, 0], 7070)).await;
}

async fn handle_partition(
    body: ChaosReq,
    client: Client,
    base: String,
) -> Result<impl warp::Reply, Infallible> {
    let url = format!("{}/chaos/partition", base);
    let reply = match client.post(&url).json(&body).send().await {
        Ok(_) => warp::reply::json(&GenericResp {
            status: "ok".into(),
        }),
        Err(e) => warp::reply::json(&GenericResp {
            status: format!("error: {}", e),
        }),
    };
    Ok(reply)
}

async fn handle_heal(
    body: ChaosReq,
    client: Client,
    base: String,
) -> Result<impl warp::Reply, Infallible> {
    let url = format!("{}/chaos/heal", base);
    let reply = match client.post(&url).json(&body).send().await {
        Ok(_) => warp::reply::json(&GenericResp {
            status: "ok".into(),
        }),
        Err(e) => warp::reply::json(&GenericResp {
            status: format!("error: {}", e),
        }),
    };
    Ok(reply)
}

async fn handle_latency(
    body: ChaosReq,
    client: Client,
    base: String,
) -> Result<impl warp::Reply, Infallible> {
    let url = format!("{}/chaos/latency", base);
    let reply = match client.post(&url).json(&body).send().await {
        Ok(_) => warp::reply::json(&GenericResp {
            status: "ok".into(),
        }),
        Err(e) => warp::reply::json(&GenericResp {
            status: format!("error: {}", e),
        }),
    };
    Ok(reply)
}

async fn handle_chaos_inject(
    body: ChaosInjectReq,
    state: ChaosState,
) -> Result<impl warp::Reply, Infallible> {
    let id = body.id.clone();
    let kind = body.kind.clone();
    let severity = body.severity;

    let mut incidents = state.active_incidents.write().await;
    incidents.insert(id.clone(), body.clone());
    drop(incidents);

    let active_count = state.active_incidents.read().await.len();
    log::info!(
        "CHAOS INJECTED: id={}, kind={}, severity={:.1}%, active_count={}",
        id,
        kind,
        severity * 100.0,
        active_count
    );

    let state_clone = state.clone();
    let id_clone = id.clone();

    match kind.as_str() {
        "latency" => {
            let delay_ms = (severity * 1000.0) as u64;
            log::info!("Network latency: +{} ms delay injected", delay_ms);

            tokio::spawn(async move {
                let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
                loop {
                    interval.tick().await;
                    if state_clone
                        .active_incidents
                        .read()
                        .await
                        .contains_key(&id_clone)
                    {
                        log::info!(
                            "Latency chaos {} still active: +{} ms delay",
                            id_clone,
                            delay_ms
                        );
                    } else {
                        break;
                    }
                }
            });
        }
        "packet_loss" => {
            let loss_pct = (severity * 100.0) as u64;
            log::info!("Packet loss: {}% packets being dropped", loss_pct);

            tokio::spawn(async move {
                let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
                let mut dropped = 0;
                loop {
                    interval.tick().await;
                    if state_clone
                        .active_incidents
                        .read()
                        .await
                        .contains_key(&id_clone)
                    {
                        dropped += (loss_pct as f64 * 0.5) as u64;
                        log::info!(
                            "Packet loss {} active: ~{} packets dropped",
                            id_clone,
                            dropped
                        );
                    } else {
                        break;
                    }
                }
            });
        }
        "cpu_spike" => {
            let cpu_pct = (severity * 100.0) as u64;
            log::info!("CPU spike: {}% load simulation started", cpu_pct);
            let num_threads = (severity * 4.0).max(1.0) as usize;
            for i in 0..num_threads {
                let state_clone = state.clone();
                let id_clone = id.clone();
                tokio::spawn(async move {
                    let mut counter = 0u64;
                    loop {
                        if counter % 100_000_000 == 0 {
                            if !state_clone
                                .active_incidents
                                .read()
                                .await
                                .contains_key(&id_clone)
                            {
                                log::info!("CPU spike thread {} shutting down", i);
                                break;
                            }
                            log::info!(
                                "CPU spike {} thread {} burning cycles ({})",
                                id_clone,
                                i,
                                counter
                            );
                        }
                        counter = counter.wrapping_add(1);
                    }
                });
            }
        }
        "memory_leak" => {
            let leak_mb = (severity * 100.0) as usize;
            log::info!("Memory leak: {} MB allocation started", leak_mb);
            tokio::spawn(async move {
                let mut leaked_memory: Vec<Vec<u8>> = Vec::new();
                let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(2));
                loop {
                    interval.tick().await;
                    if state_clone
                        .active_incidents
                        .read()
                        .await
                        .contains_key(&id_clone)
                    {
                        let chunk = vec![0u8; 10 * 1024 * 1024];
                        leaked_memory.push(chunk);
                        log::info!(
                            "Memory leak {} active: {} MB leaked",
                            id_clone,
                            leaked_memory.len() * 10
                        );
                    } else {
                        log::info!(
                            "Memory leak {} stopped, releasing {} MB",
                            id_clone,
                            leaked_memory.len() * 10
                        );
                        break;
                    }
                }
            });
        }
        "disk_failure" => {
            let failure_pct = (severity * 100.0) as u64;
            log::info!("Disk failure: {}% I/O error simulation", failure_pct);

            tokio::spawn(async move {
                let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
                let mut io_errors = 0;
                loop {
                    interval.tick().await;
                    if state_clone
                        .active_incidents
                        .read()
                        .await
                        .contains_key(&id_clone)
                    {
                        io_errors += failure_pct;
                        log::info!(
                            "Disk failure {} active: {} I/O errors simulated",
                            id_clone,
                            io_errors
                        );
                    } else {
                        break;
                    }
                }
            });
        }
        "network_partition" => {
            let partition_pct = (severity * 100.0) as u64;
            log::info!("Network partition: {}% connectivity loss", partition_pct);
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
                let mut blocked_requests = 0;
                loop {
                    interval.tick().await;
                    if state_clone
                        .active_incidents
                        .read()
                        .await
                        .contains_key(&id_clone)
                    {
                        blocked_requests += partition_pct;
                        log::info!(
                            "Network partition {} active: {} requests blocked",
                            id_clone,
                            blocked_requests
                        );
                    } else {
                        break;
                    }
                }
            });
        }
        _ => {
            log::warn!("Unknown chaos kind: {}", kind);
        }
    }

    Ok(warp::reply::json(&GenericResp {
        status: "injected".into(),
    }))
}

async fn handle_chaos_heal(
    body: ChaosHealReq,
    state: ChaosState,
) -> Result<impl warp::Reply, Infallible> {
    let id = body.id.clone();
    let mut incidents = state.active_incidents.write().await;
    let removed = incidents.remove(&id);
    let remaining = incidents.len();
    drop(incidents);

    if let Some(incident) = removed {
        log::info!(
            "CHAOS HEALED: id={}, kind={}, remaining_count={}",
            id,
            incident.kind,
            remaining
        );
        match incident.kind.as_str() {
            "latency" => log::info!("Network latency restored to normal"),
            "packet_loss" => log::info!("Packet loss stopped, connectivity restored"),
            "cpu_spike" => log::info!("CPU spike ended, load normalizing"),
            "memory_leak" => log::info!("Memory leak plugged, memory being released"),
            "disk_failure" => log::info!("Disk failure resolved, I/O operations normal"),
            "network_partition" => {
                log::info!("Network partition healed, full connectivity restored")
            }
            _ => {}
        }

        Ok(warp::reply::json(&GenericResp {
            status: "healed".into(),
        }))
    } else {
        log::warn!("Attempted to heal non-existent chaos incident: {}", id);
        Ok(warp::reply::json(&GenericResp {
            status: "not_found".into(),
        }))
    }
}

/// Returns the current status of all active chaos incidents
async fn handle_chaos_status(state: ChaosState) -> Result<impl warp::Reply, Infallible> {
    let incidents = state.active_incidents.read().await;
    let active: Vec<_> = incidents.values().cloned().collect();

    #[derive(Serialize)]
    struct StatusResp {
        status: String,
        active_count: usize,
        incidents: Vec<ChaosInjectReq>,
    }

    Ok(warp::reply::json(&StatusResp {
        status: "ok".into(),
        active_count: active.len(),
        incidents: active,
    }))
}
