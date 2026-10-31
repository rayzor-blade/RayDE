use rayde_sandbox::{
    conformance, fake::Fake, placed::{Placed, Side}, Capabilities, Error, Gpu, GpuApi, Network, SandboxProvider, SandboxSpec, Security, Template,
};

fn caps(gpu: bool, network_allowlist: bool) -> Capabilities {
    Capabilities { persistent_volumes: true, min_volume_mib: 0, snapshots: true, fork: false, gpu, network_allowlist, warm_pool: false, max_sandboxes: 0 }
}

fn spec(name: &str) -> SandboxSpec {
    SandboxSpec {
        name: name.into(),
        template: Template::Image("alpine:3.23".into()),
        cpus: 1,
        memory_mib: 128,
        security: Security::Restricted,
        network: Network::None,
        gpu: None,
        labels: Default::default(),
        mounts: vec![],
        max_duration: None,
    }
}

/// The shape of the deployment: a primary that enforces allowlists and has no GPU, a secondary with a GPU and no allowlist.
fn world() -> Placed<Fake, Fake> {
    Placed::new(Fake::new(caps(false, true)), Fake::new(caps(true, false)))
}

fn gpu() -> Option<Gpu> {
    Some(Gpu { memory_mib: 1024, api: GpuApi::Vulkan })
}

#[tokio::test]
async fn a_plain_sandbox_goes_to_the_primary() {
    assert_eq!(world().place(&spec("plain")).await.unwrap(), Side::Primary);
}

#[tokio::test]
async fn a_gpu_sandbox_goes_to_the_secondary() {
    assert_eq!(world().place(&SandboxSpec { gpu: gpu(), ..spec("g") }).await.unwrap(), Side::Secondary);
}

#[tokio::test]
async fn an_allowlisted_sandbox_stays_on_the_backend_that_enforces_it() {
    let allowed = SandboxSpec { network: Network::Allow(vec!["example.com".into()]), ..spec("a") };
    assert_eq!(world().place(&allowed).await.unwrap(), Side::Primary);
}

#[tokio::test]
async fn a_gpu_sandbox_with_an_allowlist_is_refused_rather_than_left_ungated() {
    let both = SandboxSpec { gpu: gpu(), network: Network::Allow(vec!["example.com".into()]), ..spec("b") };
    assert!(matches!(world().create(both).await, Err(Error::Unsupported(_))));
    assert!(world().list(&Default::default()).await.unwrap().is_empty());
}

#[tokio::test]
async fn calls_by_name_reach_the_backend_that_holds_the_sandbox() {
    let placed = world();
    placed.create(SandboxSpec { gpu: gpu(), ..spec("on-gpu") }).await.unwrap();
    placed.create(spec("on-primary")).await.unwrap();
    assert_eq!(placed.list(&Default::default()).await.unwrap().len(), 2);
    placed.stop("on-gpu").await.unwrap();
    placed.remove("on-gpu").await.unwrap();
    assert!(placed.get("on-gpu").await.unwrap().is_none());
    assert!(placed.get("on-primary").await.unwrap().is_some());
}

#[tokio::test]
async fn a_name_held_by_the_other_backend_conflicts() {
    let placed = world();
    placed.create(SandboxSpec { gpu: gpu(), ..spec("same") }).await.unwrap();
    assert!(matches!(placed.create(spec("same")).await, Err(Error::Conflict(_))));
}

#[tokio::test]
async fn a_snapshot_restores_only_on_the_backend_that_took_it() {
    let placed = world();
    placed.create(SandboxSpec { gpu: gpu(), ..spec("src") }).await.unwrap();
    let snapshot = placed.snapshot("src").await.unwrap();
    placed.verify_snapshot(&snapshot).await.unwrap();
    let restored = SandboxSpec { template: Template::Snapshot(snapshot.clone()), gpu: gpu(), ..spec("copy") };
    placed.create(restored).await.unwrap();
    // Without the GPU requirement the primary would be chosen, and it did not take this snapshot.
    let elsewhere = SandboxSpec { template: Template::Snapshot(snapshot.clone()), ..spec("elsewhere") };
    assert!(matches!(placed.create(elsewhere).await, Err(Error::Conflict(_))));
    placed.remove_snapshot(&snapshot).await.unwrap();
}

#[tokio::test]
async fn a_volume_binds_a_sandbox_to_its_backend() {
    use rayde_sandbox::{Mount, Source, VolumeSpec};
    let placed = world();
    placed.create_volume(VolumeSpec { name: "data".into(), size_mib: 128 }).await.unwrap();
    let mount = Mount { source: Source::Volume("data".into()), destination: "/data".into(), read_only: false };
    let wants_gpu = SandboxSpec { gpu: gpu(), mounts: vec![mount], ..spec("v") };
    assert!(matches!(placed.create(wants_gpu).await, Err(Error::Conflict(_))));
}

#[tokio::test]
async fn the_placed_pair_conforms() {
    conformance::run_all(&Placed::new(Fake::new(caps(true, true)), Fake::new(caps(true, true))), "placed").await.unwrap();
}
