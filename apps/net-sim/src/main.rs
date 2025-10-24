use std::convert::Infallible;
use warp::Filter;
use serde::{Deserialize, Serialize};
use reqwest::Client;
use std::env;

#[derive(Deserialize, Serialize)]
struct ChaosReq {
    region: String,
    latency_ms: Option<u64>,
}

#[derive(Serialize)]
struct GenericResp {
    status: String,
}

#[tokio::main]
async fn main() {
    env_logger::init();

    let base = env::var("FLYD_SIM_BASE").unwrap_or_else(|_| "http://flyd-sim:8080".into());
    let client = Client::new();

    let client_filter = warp::any().map(move || client.clone());
    let base_filter = warp::any().map(move || base.clone());

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

    let routes = partition.or(heal).or(latency);
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
        Ok(_) => warp::reply::json(&GenericResp { status: "ok".into() }),
        Err(e) => warp::reply::json(&GenericResp { status: format!("error: {}", e) }),
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
        Ok(_) => warp::reply::json(&GenericResp { status: "ok".into() }),
        Err(e) => warp::reply::json(&GenericResp { status: format!("error: {}", e) }),
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
        Ok(_) => warp::reply::json(&GenericResp { status: "ok".into() }),
        Err(e) => warp::reply::json(&GenericResp { status: format!("error: {}", e) }),
    };
    Ok(reply)
}