use rayde_session::server::{Options, start};
use std::fs;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{Error, client::IntoClientRequest},
};

#[tokio::test]
async fn nested_site_assets_and_exact_origins_work_on_an_assigned_port() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir_all(root.path().join("docs")).unwrap();
    fs::create_dir_all(root.path().join("assets")).unwrap();
    for (name, body) in [
        ("index.html", "landing"),
        ("docs/index.html", "guide"),
        ("assets/logo.svg", "svg"),
        ("assets/editor.webp", "webp"),
        ("assets/font.woff2", "font"),
    ] {
        fs::write(root.path().join(name), body).unwrap();
    }
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.web = Some(root.path().into());
    options.origins = vec!["http://localhost:49117".into()];
    let running = start(options).await.unwrap();
    for (path, kind, body) in [
        ("/", "text/html", "landing"),
        ("/docs/", "text/html", "guide"),
        ("/assets/logo.svg", "image/svg+xml", "svg"),
        ("/assets/editor.webp", "image/webp", "webp"),
        ("/assets/font.woff2", "font/woff2", "font"),
    ] {
        let mut stream = tokio::net::TcpStream::connect(running.address)
            .await
            .unwrap();
        stream
            .write_all(
                format!(
                    "GET {path} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
                    running.address
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        assert!(response.starts_with("HTTP/1.1 200"), "{path}: {response}");
        assert!(
            response.contains(&format!("content-type: {kind}")),
            "{path}: {response}"
        );
        assert!(response.contains("cross-origin-opener-policy: same-origin"));
        assert!(response.contains("cross-origin-embedder-policy: require-corp"));
        assert!(response.ends_with(body));
    }
    let url = format!("ws://{}/session", running.address);
    for origin in [
        format!("http://{}", running.address),
        "http://localhost:49117".into(),
    ] {
        let mut request = url.clone().into_client_request().unwrap();
        request
            .headers_mut()
            .insert("Origin", origin.parse().unwrap());
        let (mut socket, _) = connect_async(request).await.unwrap();
        socket.close(None).await.unwrap();
    }
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("Origin", "http://localhost:49118".parse().unwrap());
    assert!(
        matches!(connect_async(request).await, Err(Error::Http(response)) if response.status() == 403)
    );
    running.shutdown().await;
}

#[tokio::test]
async fn preview_bootstrap_is_opt_in_loopback_only_and_rejects_cross_origin_or_rebound_hosts() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("index.html"), "page").unwrap();
    let mut public = Options::new(root.path());
    public.address = ([0, 0, 0, 0], 0).into();
    public.preview_project = Some("build.hxml".into());
    public.web = Some(root.path().into());
    public.token = Some("a".repeat(40));
    assert!(start(public).await.is_err());
    async fn get(address: std::net::SocketAddr, host: &str, site: &str) -> String {
        let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
        stream.write_all(format!("GET /.well-known/rayde-preview HTTP/1.1\r\nHost: {host}\r\nSec-Fetch-Site: {site}\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).await.unwrap();
        reply
    }
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.web = Some(root.path().into());
    options.token = Some("a".repeat(40));
    let normal = start(options).await.unwrap();
    assert!(
        get(normal.address, &normal.address.to_string(), "same-origin")
            .await
            .starts_with("HTTP/1.1 204")
    );
    normal.shutdown().await;
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.web = Some(root.path().into());
    options.token = Some("a".repeat(40));
    options.preview_project = Some("build.hxml".into());
    let preview = start(options).await.unwrap();
    let valid = get(preview.address, &preview.address.to_string(), "same-origin").await;
    assert!(valid.starts_with("HTTP/1.1 200"));
    assert!(valid.contains("cache-control: no-store"));
    assert!(valid.contains("build.hxml"));
    for (host, site) in [
        (preview.address.to_string(), "cross-site"),
        (preview.address.to_string(), "same-site"),
        ("rebound.example:8731".into(), "same-origin"),
    ] {
        let refused = get(preview.address, &host, site).await;
        assert!(refused.starts_with("HTTP/1.1 403"));
        assert!(!refused.contains(&"a".repeat(40)));
    }
    preview.shutdown().await;
}
