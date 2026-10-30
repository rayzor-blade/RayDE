use rayde_sandbox::{conformance, fake::Fake, Capabilities, Error, Network, SandboxProvider};

fn full() -> Capabilities {
    Capabilities { persistent_volumes: true, snapshots: true, fork: false, gpu: true, network_allowlist: true, warm_pool: false, max_sandboxes: 0 }
}

#[tokio::test]
async fn the_fake_with_every_feature_conforms() {
    conformance::run_all(&Fake::new(full()), "full").await.unwrap();
}

#[tokio::test]
async fn the_fake_with_no_optional_features_conforms() {
    let bare = Capabilities::default();
    conformance::run_all(&Fake::new(bare), "bare").await.unwrap();
}

#[tokio::test]
async fn a_backend_at_its_limit_is_unavailable_not_a_conflict() {
    let limited = Fake::new(Capabilities { max_sandboxes: 1, ..full() });
    let spec = |name: &str| rayde_sandbox::SandboxSpec {
        name: name.into(),
        template: rayde_sandbox::Template::Image("alpine:3.23".into()),
        cpus: 1,
        memory_mib: 128,
        security: rayde_sandbox::Security::Restricted,
        network: Network::None,
        gpu: None,
        labels: Default::default(),
        mounts: vec![],
        max_duration: None,
    };
    limited.create(spec("one")).await.unwrap();
    assert_eq!(limited.create(spec("two")).await.unwrap_err(), Error::Unavailable);
}
