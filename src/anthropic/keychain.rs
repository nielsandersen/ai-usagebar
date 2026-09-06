//! macOS Keychain access for Claude Code OAuth credentials.
//!
//! On Linux the Claude CLI writes its OAuth state to
//! `~/.claude/.credentials.json`. On macOS, recent Claude Code builds instead
//! store the *same* `{ "claudeAiOauth": …, "mcpOAuth": … }` JSON as a generic
//! password item in the login Keychain (service `Claude Code-credentials`), so
//! the file never exists and a naive read fails with an I/O error.
//!
//! Reads and writes use Apple's `security(1)` tool. Writes use its stdin
//! protocol so the item retains Claude Code's apple-tool: partition and
//! credential JSON never appears in process arguments.
//!
//! A `CLAUDE_CONFIG_DIR`-scoped login (`CLAUDE_CONFIG_DIR=<dir> claude`, the
//! mechanism `accounts_dir` documents) also lands in the Keychain rather than
//! `<dir>/.credentials.json` — under a *different* service name, `Claude
//! Code-credentials-<hash>`, where `<hash>` is the first 8 hex chars of the
//! SHA-256 of the config dir's absolute path (verified empirically against a
//! real install). [`read_raw_for`]/[`write_raw_for`] target that per-account
//! item so named accounts can find it without ever reading the *default*
//! item — a hash tied to the account's own directory can't collide with a
//! different account's, which is what issue #15 needed the strict
//! `Explicit`-only rule to avoid in the first place.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::error::{AppError, Result};

/// Generic-password *service* name Claude Code uses for the credentials blob.
const SERVICE: &str = "Claude Code-credentials";

/// The per-account service name for a `CLAUDE_CONFIG_DIR`-scoped login. Shells
/// out to `shasum(1)` rather than pulling in a `sha2` crate — same rationale
/// as the rest of this module.
fn service_name_for(config_dir: &Path) -> Result<String> {
    let mut child = Command::new("/usr/bin/shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| AppError::Other(format!("could not run `shasum`: {e}")))?;
    child
        .stdin
        .take()
        .expect("stdin was piped")
        .write_all(config_dir.display().to_string().as_bytes())
        .map_err(|e| AppError::Other(format!("could not run `shasum`: {e}")))?;
    let out = child
        .wait_with_output()
        .map_err(|e| AppError::Other(format!("could not run `shasum`: {e}")))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let hash = stdout
        .split_whitespace()
        .next()
        .and_then(|h| h.get(..8))
        .ok_or_else(|| AppError::Other("shasum produced unexpected output".into()))?;
    Ok(format!("{SERVICE}-{hash}"))
}

/// The Keychain item's *account* is the macOS short username. We match on it
/// when updating so we touch exactly the item Claude Code created.
///
/// `None` when `$USER` is unset or empty: read and write must then agree to
/// select by service alone. Previously the read omitted `-a` while the write
/// passed `-a ""`, so a refresh could create a *second*, empty-account item
/// that the read would never find again.
fn account() -> Option<String> {
    std::env::var("USER").ok().filter(|u| !u.is_empty())
}

/// `security` exits with the raw OSStatus. 44 is `errSecItemNotFound`.
const ERR_SEC_ITEM_NOT_FOUND: i32 = 44;

/// Read the raw credentials JSON from the login Keychain.
///
/// Returns `Ok(None)` only when the item genuinely does not exist, so callers
/// can fall through to the file path / a "run `claude`" error. Every other
/// `security` failure is an `Err`: a locked Keychain or a denied ACL is not the
/// same as "you are not logged in", and reporting it as such sent users off to
/// re-authenticate when the credentials were there all along.
pub fn read_raw() -> Result<Option<String>> {
    read_raw_service(SERVICE)
}

/// Same as [`read_raw`], but for a named account's `CLAUDE_CONFIG_DIR`-scoped
/// Keychain item instead of the default one.
pub fn read_raw_for(config_dir: &Path) -> Result<Option<String>> {
    read_raw_service(&service_name_for(config_dir)?)
}

fn read_raw_service(service: &str) -> Result<Option<String>> {
    let mut cmd = Command::new("/usr/bin/security");
    cmd.args(["find-generic-password", "-s", service, "-w"]);
    if let Some(acct) = account() {
        cmd.args(["-a", &acct]);
    }

    let out = cmd
        .output()
        .map_err(|e| AppError::Other(format!("could not run `security`: {e}")))?;

    if !out.status.success() {
        if out.status.code() == Some(ERR_SEC_ITEM_NOT_FOUND) {
            return Ok(None);
        }
        let detail = String::from_utf8_lossy(&out.stderr);
        let detail = detail.trim();
        return Err(AppError::Credentials(format!(
            "could not read the Claude credentials from the macOS Keychain \
             (security exited {}): {}. If the login Keychain is locked, unlock \
             it and retry; if access was denied, allow ai-usagebar when prompted.",
            out.status.code().unwrap_or(-1),
            if detail.is_empty() {
                "no detail"
            } else {
                detail
            }
        )));
    }

    decode_read_output(&out.stdout)
}

fn decode_read_output(bytes: &[u8]) -> Result<Option<String>> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| AppError::Credentials("Keychain response was not UTF-8".into()))?
        .trim_end_matches('\n');
    if text.is_empty() {
        return Ok(None);
    }
    // security prints non-ASCII password bytes as hex. Decode only the
    // unambiguous all-hex form; ordinary JSON must remain byte-for-byte intact.
    if text.len().is_multiple_of(2) && text.bytes().all(|b| b.is_ascii_hexdigit()) {
        let decoded: Vec<u8> = text
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                u8::from_str_radix(std::str::from_utf8(pair).expect("ASCII hex"), 16).expect("hex")
            })
            .collect();
        return String::from_utf8(decoded)
            .map(Some)
            .map_err(|_| AppError::Credentials("Keychain credential was not UTF-8".into()));
    }
    Ok(Some(text.to_string()))
}

/// Persist updated credentials JSON back to the *same* Keychain item, so the
/// widget and Claude Code keep sharing a single source of truth (mirroring how
/// they share one file on Linux).
///
/// Writes require the same account selector used by the read path.
/// Fail closed if `$USER` is unavailable rather than falling back to the
/// `security(1)` argv form and exposing the OAuth JSON to process inspection.
pub fn write_raw(json: &str) -> Result<()> {
    write_raw_service(SERVICE, json)
}

/// Same as [`write_raw`], but for a named account's `CLAUDE_CONFIG_DIR`-scoped
/// Keychain item instead of the default one.
pub fn write_raw_for(config_dir: &Path, json: &str) -> Result<()> {
    write_raw_service(&service_name_for(config_dir)?, json)
}

/// Remove the default Claude Code credential. Used only while rolling back an
/// account switch that started from an empty default slot.
pub fn delete_raw() -> Result<()> {
    delete_raw_service(SERVICE)
}

/// Remove a named account's config-dir-scoped credential after moving it into
/// the default slot. Keeping both copies would let two Claude processes rotate
/// the same refresh-token lineage independently.
pub fn delete_raw_for(config_dir: &Path) -> Result<()> {
    delete_raw_service(&service_name_for(config_dir)?)
}

fn write_raw_service(service: &str, json: &str) -> Result<()> {
    let acct = account().ok_or_else(|| {
        AppError::Credentials(
            "cannot safely update Claude credentials because USER is unset".into(),
        )
    })?;
    write_service(service, &acct, json, None)
}

/// Use Apple's tool for both creation and update, retaining the apple-tool:
/// partition Claude Code uses. Never pass credentials in argv, broaden the
/// trusted-application list, or fall back to the native SecItemAdd path.
fn write_service(service: &str, acct: &str, json: &str, keychain: Option<&Path>) -> Result<()> {
    let input = write_input(service, acct, json, keychain)?;
    let mut child = Command::new("/usr/bin/security")
        .args(["-i", "-q"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| AppError::Other(format!("could not run security: {e}")))?;
    let written = child
        .stdin
        .take()
        .expect("stdin was piped")
        .write_all(input.as_bytes());
    if written.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(AppError::Credentials(
            "could not send credential update to Keychain".into(),
        ));
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                return Err(AppError::Credentials(format!(
                    "Keychain update failed (security exited {}); credential contents withheld",
                    status.code().unwrap_or(-1)
                )));
            }
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            result => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(AppError::Credentials(if result.is_err() {
                    "could not wait for Keychain update".into()
                } else {
                    "Keychain update timed out; unlock the login Keychain and retry".into()
                }));
            }
        }
    }
}

fn write_input(service: &str, acct: &str, json: &str, keychain: Option<&Path>) -> Result<String> {
    fn quote(value: &str) -> Result<String> {
        if value.contains(['\0', '\n', '\r']) {
            return Err(AppError::Credentials(
                "invalid control character in Keychain argument".into(),
            ));
        }
        Ok(format!(
            "\"{}\"",
            value.replace('\\', "\\\\").replace('"', "\\\"")
        ))
    }
    // Compact pretty-printed blobs and escape JSON newlines before building
    // the tool's line protocol. Its parser is not a shell.
    let doc: serde_json::Value = serde_json::from_str(json)
        .map_err(|_| AppError::Credentials("credential update must be valid JSON".into()))?;
    let compact = serde_json::to_string(&doc).map_err(AppError::Json)?;
    let mut input = format!(
        "add-generic-password -U -s {} -a {} -w {}",
        quote(service)?,
        quote(acct)?,
        quote(&compact)?
    );
    if let Some(path) = keychain {
        let path = path
            .to_str()
            .ok_or_else(|| AppError::Credentials("invalid Keychain path".into()))?;
        input.push(' ');
        input.push_str(&quote(path)?);
    }
    input.push('\n');
    // security -i has a 4096-byte input buffer. Reject before starting the
    // process, otherwise truncation can save broken JSON or execute a tail.
    if input.len() >= 4096 {
        return Err(AppError::Credentials(
            "credential update exceeds Keychain's safe input limit; use Claude Code to sign in"
                .into(),
        ));
    }
    Ok(input)
}

fn delete_raw_service(service: &str) -> Result<()> {
    let mut cmd = Command::new("/usr/bin/security");
    cmd.args(["delete-generic-password", "-s", service]);
    if let Some(acct) = account() {
        cmd.args(["-a", &acct]);
    }

    let out = cmd
        .output()
        .map_err(|e| AppError::Other(format!("could not run `security`: {e}")))?;
    if out.status.success() || out.status.code() == Some(ERR_SEC_ITEM_NOT_FOUND) {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(&out.stderr);
    Err(AppError::Credentials(format!(
        "failed to remove the Claude credentials from the macOS Keychain \
         (security exited {}): {}",
        out.status.code().unwrap_or(-1),
        detail.trim()
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_input_quotes_json_without_shell_interpretation() {
        let line = write_input(
            "service",
            "account",
            r#"{"value":"a\\b\"c","unicode":"æ","shell":"$(touch /tmp/no)"}"#,
            None,
        )
        .unwrap();
        assert!(line.starts_with("add-generic-password -U -s \"service\" -a \"account\" -w \""));
        assert!(line.ends_with("\"\n"));
        assert_eq!(line.lines().count(), 1);
        assert!(line.contains("$(touch /tmp/no)"));
    }

    #[test]
    fn write_input_rejects_command_injection_and_oversized_payloads() {
        for invalid in ["line\nhelp", "line\rhelp", "zero\0byte"] {
            assert!(write_input(invalid, "account", "{}", None).is_err());
            assert!(write_input("service", invalid, "{}", None).is_err());
        }
        assert!(
            write_input(
                "service",
                "account",
                &serde_json::to_string(&"x".repeat(4096)).unwrap(),
                None
            )
            .is_err()
        );
        assert!(
            write_input(
                "service",
                "account",
                &serde_json::to_string(&"æ".repeat(2048)).unwrap(),
                None
            )
            .is_err()
        );
    }
    /// Uses only a throwaway keychain and fake credentials. Opt-in because it
    /// requires a logged-in macOS security session, unlike the hermetic suite.
    #[test]
    #[ignore = "requires a macOS security session; creates a disposable keychain"]
    fn keychain_round_trip_preserves_access() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("regression.keychain-db");
        let run = |args: &[&str]| {
            let output = Command::new("/usr/bin/security")
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "security command failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            output.stdout
        };
        run(&[
            "create-keychain",
            "-p",
            "disposable-test-only",
            path.to_str().unwrap(),
        ]);
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = Command::new("/usr/bin/security")
                    .arg("delete-keychain")
                    .arg(&self.0)
                    .output();
            }
        }
        let _cleanup = Cleanup(path.clone());
        let service = "ai-usagebar-regression";
        let acct = "test-account";
        write_service(service, acct, r#"{"token":"seed"}"#, Some(&path)).unwrap();
        let initial =
            String::from_utf8(run(&["dump-keychain", "-a", path.to_str().unwrap()])).unwrap();
        let original_access = initial.split_once("access:").unwrap().1;
        for json in [
            r#"{"token":"first"}"#,
            r#"{"token":"second\\escaped\"value","unicode":"æ","literal":"$(echo never)"}"#,
        ] {
            write_service(service, acct, json, Some(&path)).unwrap();
            let found = run(&[
                "find-generic-password",
                "-s",
                service,
                "-a",
                acct,
                "-w",
                path.to_str().unwrap(),
            ]);
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(
                    &decode_read_output(&found).unwrap().unwrap()
                )
                .unwrap(),
                serde_json::from_str::<serde_json::Value>(json).unwrap()
            );
            let acl =
                String::from_utf8(run(&["dump-keychain", "-a", path.to_str().unwrap()])).unwrap();
            assert_eq!(
                acl.split_once("access:").unwrap().1,
                original_access,
                "updates must preserve the original access controls"
            );
            assert!(
                acl.contains("/usr/bin/security"),
                "Apple tool must remain the trusted reader"
            );
            assert_eq!(
                acl.matches("\"svce\"<blob>=\"ai-usagebar-regression\"")
                    .count(),
                1,
                "updating must not create duplicate credentials"
            );
        }
        let oversized = serde_json::to_string(&"x".repeat(4096)).unwrap();
        assert!(write_service(service, acct, &oversized, Some(&path)).is_err());
        let found = run(&[
            "find-generic-password",
            "-s",
            service,
            "-a",
            acct,
            "-w",
            path.to_str().unwrap(),
        ]);
        assert!(
            decode_read_output(&found)
                .unwrap()
                .unwrap()
                .contains("second"),
            "failed update must preserve previous credential"
        );
    }
}
