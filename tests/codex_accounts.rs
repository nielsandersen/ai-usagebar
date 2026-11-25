//! Real command dispatch with a fake Codex executable and an isolated home.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

fn run(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ai-usagebar"))
        .env_clear()
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("PATH", home.join("bin"))
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn add_codex_registers_then_logs_in_only_to_its_home() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path();
    let config_path = home.join(".config/ai-usagebar/config.toml");
    std::fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    let original = "# preserve this comment\n[openai]\nenabled = true\n";
    std::fs::write(&config_path, original).unwrap();
    std::fs::create_dir(home.join(".codex")).unwrap();
    std::fs::write(home.join(".codex/auth.json"), "invented default sentinel").unwrap();
    let bin = home.join("bin");
    std::fs::create_dir(&bin).unwrap();
    let fake = bin.join("codex");
    std::fs::write(&fake, r#"#!/bin/sh
[ "$#" = 1 ] && [ "$1" = login ] || exit 9
umask 077
printf '%s' '{"tokens":{"access_token":"test-access","refresh_token":"test-refresh","id_token":"test-id","account_id":"test-client"}}' > "$CODEX_HOME/auth.json"
printf 'login\n' >> "$CODEX_HOME/logins"
"#).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();

    let registered = run(home, &["account", "add", "client", "--codex", "--no-login"]);
    assert!(registered.status.success(), "{:?}", registered);
    let account_home = home.join(".config/ai-usagebar/accounts/codex/client");
    assert!(account_home.is_dir());
    assert!(!account_home.join("auth.json").exists());
    assert_eq!(
        std::fs::metadata(&account_home)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    let configured = std::fs::read_to_string(&config_path).unwrap();
    assert!(configured.starts_with(original));
    assert!(configured.contains("[[openai.accounts]]"));
    assert!(configured.contains("codex_home = \"~/.config/ai-usagebar/accounts/codex/client\""));

    for _ in 0..2 {
        let login = run(home, &["account", "add", "client", "--codex"]);
        assert!(login.status.success(), "{:?}", login);
    }
    assert_eq!(
        std::fs::read_to_string(account_home.join("logins")).unwrap(),
        "login\nlogin\n"
    );
    assert_eq!(std::fs::read_to_string(&config_path).unwrap(), configured);
    assert_eq!(
        std::fs::read_to_string(home.join(".codex/auth.json")).unwrap(),
        "invented default sentinel"
    );
    let auth = ai_usagebar::openai::creds::read_from(&account_home.join("auth.json")).unwrap();
    assert_eq!(auth.tokens.account_id.as_deref(), Some("test-client"));

    let status = run(home, &["account", "status", "--json"]);
    assert!(status.status.success());
    let status: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
    assert!(status.get("cli").is_some());
    assert!(status.get("desktop").is_some());
    assert!(status.get("usage_accounts").is_some());
    assert_eq!(status["codex"]["accounts"][0]["label"], "client");
    assert_eq!(status["codex"]["accounts"][0]["has_credentials"], true);

    std::fs::write(&fake, "#!/bin/sh\nexit 7\n").unwrap();
    assert!(
        !run(home, &["account", "add", "client", "--codex"])
            .status
            .success()
    );
    std::fs::remove_file(&fake).unwrap();
    assert!(
        !run(home, &["account", "add", "client", "--codex"])
            .status
            .success()
    );
    assert!(
        run(home, &["account", "add", "client", "--codex", "--no-login"])
            .status
            .success()
    );
}
