// SPDX-FileCopyrightText: Sudo Apt Holdings LLC
// SPDX-License-Identifier: Apache-2.0
//
// Slice 100. `trinity --keychain <op> [name]`: the shell binary run as a command, so the BEAM can
// reach the OS keychain at any moment, including at boot before any window exists (NOTES D1).
// The `keyring` crate does the OS work: the macOS Keychain, the Windows Credential Manager, the
// Secret Service on Linux.
//
// The protocol, which `Trinity.Secrets.Keychain` speaks:
//
//   probe            exit 0 when the keychain answers
//   get <name>       stdout: the value, hex, one line
//   set <name>       stdin:  the value, hex, one line
//   delete <name>
//
// Exit 0 done, 2 usage, 3 no such entry, 4 the keychain could not be reached. A value never
// appears on the command line, and nothing printed to stderr carries one: errors are reported by
// kind only (keyring's `BadEncoding` holds the stored bytes, so its Debug form is never printed).

use std::io::{BufRead, Write};

// Every entry Trinity keeps lives under this one service. The name is the entry's account.
const SERVICE: &str = "Trinity";
const PROBE: &str = "TRINITY_KEYCHAIN_PROBE";

const OK: i32 = 0;
const USAGE: i32 = 2;
const NOT_FOUND: i32 = 3;
const UNREACHABLE: i32 = 4;

pub fn run(args: &[String]) -> i32 {
    let op = args.first().map(String::as_str);
    let name = args.get(1).map(String::as_str);

    match (op, name) {
        (Some("probe"), None) => probe(),
        (Some("get"), Some(name)) if valid_name(name) => get(name),
        (Some("set"), Some(name)) if valid_name(name) => set(name),
        (Some("delete"), Some(name)) if valid_name(name) => delete(name),
        _ => {
            eprintln!("usage: trinity --keychain probe | get <NAME> | set <NAME> | delete <NAME>");
            USAGE
        }
    }
}

// The same rule `Trinity.Secrets` applies: an environment-variable name, at most 64 bytes.
fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_uppercase()
        && bytes
            .iter()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || *b == b'_')
}

fn entry(name: &str) -> Result<keyring::Entry, i32> {
    keyring::Entry::new(SERVICE, name).map_err(|error| report(&error))
}

fn probe() -> i32 {
    match entry(PROBE).map(|e| e.get_password()) {
        Ok(Ok(_)) | Ok(Err(keyring::Error::NoEntry)) => OK,
        Ok(Err(error)) => report(&error),
        Err(code) => code,
    }
}

fn get(name: &str) -> i32 {
    let entry = match entry(name) {
        Ok(entry) => entry,
        Err(code) => return code,
    };

    match entry.get_password() {
        Ok(value) => {
            let mut out = std::io::stdout().lock();
            if writeln!(out, "{}", to_hex(value.as_bytes())).is_err() {
                return UNREACHABLE;
            }
            OK
        }
        Err(keyring::Error::NoEntry) => NOT_FOUND,
        Err(error) => report(&error),
    }
}

fn set(name: &str) -> i32 {
    let mut line = String::new();
    if std::io::stdin().lock().read_line(&mut line).is_err() {
        return USAGE;
    }

    let value = match from_hex(line.trim()).and_then(|bytes| String::from_utf8(bytes).ok()) {
        Some(value) if !value.is_empty() => value,
        _ => {
            eprintln!("keychain: the value on stdin is not one line of hex-encoded UTF-8");
            return USAGE;
        }
    };

    let entry = match entry(name) {
        Ok(entry) => entry,
        Err(code) => return code,
    };

    match entry.set_password(&value) {
        Ok(()) => OK,
        Err(error) => report(&error),
    }
}

fn delete(name: &str) -> i32 {
    let entry = match entry(name) {
        Ok(entry) => entry,
        Err(code) => return code,
    };

    match entry.delete_credential() {
        Ok(()) => OK,
        Err(keyring::Error::NoEntry) => NOT_FOUND,
        Err(error) => report(&error),
    }
}

// The kind of failure, never its payload.
fn report(error: &keyring::Error) -> i32 {
    let kind = match error {
        keyring::Error::PlatformFailure(_) => "the platform's keychain failed",
        keyring::Error::NoStorageAccess(_) => "the keychain is locked or access was refused",
        keyring::Error::NoEntry => "no such entry",
        keyring::Error::BadEncoding(_) => "the stored entry is not UTF-8",
        keyring::Error::TooLong(_, _) => "an attribute is too long for this keychain",
        keyring::Error::Invalid(_, _) => "an attribute is invalid for this keychain",
        keyring::Error::Ambiguous(_) => "more than one entry matches",
        _ => "an unknown keychain error",
    };
    eprintln!("keychain: {kind}");
    UNREACHABLE
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}
