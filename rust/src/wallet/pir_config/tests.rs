use super::*;

#[test]
fn product_routes_append_one_canonical_prefix_to_the_base() {
    let base = "https://wallet-pir.valargroup.dev".to_owned();
    let endpoints: Vec<_> = PirProduct::ALL
        .iter()
        .map(|product| product.endpoint(&base))
        .collect();
    assert_eq!(
        endpoints,
        vec![
            "https://wallet-pir.valargroup.dev/enhance/v1",
            "https://wallet-pir.valargroup.dev/status/v1",
            "https://wallet-pir.valargroup.dev/transparent/v1",
            "https://wallet-pir.valargroup.dev/receiver/v1",
        ]
    );
}

#[test]
fn selection_lifecycle_bumps_the_generation_only_on_change() {
    let selection = ServerSelection::new();
    assert_eq!(selection.base(), None);

    let selected = selection.select("https://a.example/").unwrap();
    assert_eq!(selected, 1);
    assert_eq!(selection.base().as_deref(), Some("https://a.example"));
    assert_eq!(
        selection.select("HTTPS://A.EXAMPLE").unwrap(),
        selected,
        "re-applying the same base keeps sessions"
    );

    assert!(selection.select("http://b.example").is_err());
    assert_eq!(selection.base().as_deref(), Some("https://a.example"));
    assert_eq!(selection.select("https://b.example").unwrap(), 2);

    assert_eq!(selection.clear(), 3);
    assert_eq!(selection.base(), None);
    assert_eq!(selection.clear(), 3);
}
