use std::path::Path;

#[test]
fn hover_subsystem_is_absent_from_desktop_crate() {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let src = manifest.join("src");
    let ui = manifest.parent().unwrap().join("ui");
    let banned: [&str; 4] = [
        "set_window_hovered",
        "schedule_hover_close",
        "TrayIconEvent::Enter",
        "pointer_over_window",
    ];
    let mut violations = Vec::new();
    for dir in [src, ui] {
        if !dir.is_dir() {
            continue;
        }
        for entry in walkdir::WalkDir::new(&dir)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|e| {
                e.path()
                    .extension()
                    .is_some_and(|ext| ext == "rs" || ext == "js")
            })
        {
            let Ok(content) = std::fs::read_to_string(entry.path()) else {
                continue;
            };
            for word in &banned {
                if content.contains(word) {
                    violations.push(format!(
                        "{} contains banned hover string: {}",
                        entry.path().display(),
                        word
                    ));
                }
            }
        }
    }
    assert!(
        violations.is_empty(),
        "Hover subsystem residue found:\n{}",
        violations.join("\n")
    );
}
