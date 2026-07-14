use aiusagebar_core::ProviderId;

#[test]
fn codex_initial_is_c_and_claude_initial_is_cc_never_a() {
    assert_eq!(ProviderId::Codex.initial(), "C");
    assert_eq!(ProviderId::Claude.initial(), "CC");
}

#[test]
fn provider_display_names_are_stable() {
    assert_eq!(ProviderId::Codex.display_name(), "Codex");
    assert_eq!(ProviderId::Claude.display_name(), "Claude Code");
}
