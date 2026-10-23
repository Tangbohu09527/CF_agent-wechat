#!/usr/bin/env python3
"""Compose PR14 observation/WAL and narrow active-account read routing on fixed 96c."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "packages/agent-server-rust/src/"
REVISION = "96c2e90c497d999bf5189a134a9b3b293731f42e"
EXPECTED = {
    PREFIX + "tools/mod.rs": "cdf075ddf75f32b17e4f7339b9f263bf34b93a464abcacc78cd59e66255f8540",
    PREFIX + "router/contacts.rs": "111e053afa86ada79338d06db89e190993c4b6c3fb32db2e2068c7fc99c0da2d",
    PREFIX + "router/chats.rs": "9da769a03eb9d815e9ca6a2470dae32075a65647eb55ed011570eb03f022e08b",
    PREFIX + "router/messages.rs": "7ab7c8460d7cb17e15b6c4d7a32d5ae8e3f430e778d4d7a26b164c35ce9297e0",
}

def prior():
    spec = importlib.util.spec_from_file_location("live_overlay", ROOT / "scripts/apply-live-login-observation.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("reviewed upstream shape changed")
    return text.replace(old, new, 1)

def replace_function(text, name, replacement):
    start = text.index("pub async fn " + name + "(")
    end = text.index("\n}", start) + 2
    return text[:start] + replacement.strip() + text[end:]

def read_function(name, signature, result_type, kind, expression):
    return f'''pub async fn {name}({signature}) -> Result<Json<{result_type}>, ActiveReadError> {{
    let session = get_session("default").ok_or_else(|| active_error("active_session_unavailable"))?;
    let (active, keys) = active_read_keys(&session, ReadKind::{kind}).await?;
    let result = {expression};
    ensure_active_account(&session, &active).map_err(active_error)?;
    Ok(Json(result))
}}'''

def transform(inputs, *, base_outputs):
    originals = {name: data.replace(b"\r\n", b"\n") for name, data in inputs.items()}
    if set(originals) != set(EXPECTED) or any(hashlib.sha256(originals[name]).hexdigest() != digest
                                            for name, digest in EXPECTED.items()):
        raise ValueError("upstream source identity mismatch")
    outputs = dict(base_outputs)
    outputs[PREFIX + "tools/mod.rs"] = originals[PREFIX + "tools/mod.rs"] + b"pub mod active_account;\n"
    outputs[PREFIX + "tools/active_account.rs"] = (ROOT / "upstream/active-account-reader/active_account.rs").read_bytes().replace(b"\r\n", b"\n")
    route = outputs[PREFIX + "router/status.rs"].decode()
    start, end = route.index("pub async fn auth_status()"), route.index("/// Log out")
    auth = route[start:end]
    # Saved identity is diagnostic metadata, never evidence for current authenticated identity.
    auth = auth.replace('"loggedInUser": session.logged_in_user,', '"loggedInUser": serde_json::Value::Null,')
    auth = replace_once(auth, '''    let status = if context.state.main_window.is_logged_in {
        "logged_in"
    } else {
        "logged_out"
    };''', '''    let active = if context.state.main_window.is_logged_in {
        match crate::tools::active_account::resolve_active_account(&session) {
            Ok(account) => Some(account),
            Err(code) => return Json(serde_json::json!({
                "status": "unknown", "reason": code, "identityVerified": false,
                "loggedInUser": serde_json::Value::Null,
                "observedAt": chrono::Utc::now().to_rfc3339(),
            })),
        }
    } else { None };
    let status = if active.is_some() { "logged_in" } else { "logged_out" };
    let current_account = active.as_ref().map(|account| account.account_dir.as_str());''')
    auth = replace_once(auth, '''        "status": status,
        "loggedInUser": serde_json::Value::Null,''', '''        "status": status,
        "loggedInUser": current_account,
        "identityVerified": active.is_some(),
        "identitySource": "active_process_fd",
        "readIdentityContract": "active-account-reader-v1",
        "storedIdentityMatches": current_account.is_some() && current_account == session.logged_in_user.as_deref(),
        "observedAt": chrono::Utc::now().to_rfc3339(),''')
    outputs[PREFIX + "router/status.rs"] = (route[:start] + auth + route[end:]).encode()
    imports = '''use crate::tools::active_account::{active_error, active_read_keys, ensure_active_account, ActiveReadError, ReadKind};
'''
    specifications = {
        "router/contacts.rs": [
            ("list_contacts", "Query(params): Query<ListParams>", "Vec<Contact>", "Contacts", "wechat_contacts::list_contacts(&active.account_dir, &keys, params.limit, params.offset)"),
            ("find_contacts", "Query(params): Query<FindParams>", "Vec<Contact>", "Contacts", "wechat_contacts::find_contacts(&active.account_dir, &keys, &params.name)"),
        ],
        "router/chats.rs": [
            ("list_chats", "Query(params): Query<ListParams>", "Vec<Chat>", "Chats", "wechat_chats::list_chats(&active.account_dir, &keys, params.limit, params.offset)"),
            ("get_chat", "Path(id): Path<String>", "Option<Chat>", "Chats", "wechat_chats::get_chat_by_username(&active.account_dir, &keys, &id)"),
            ("find_chats", "Query(params): Query<FindParams>", "Vec<Chat>", "Chats", "wechat_chats::find_chats_by_name(&active.account_dir, &keys, &params.name)"),
        ],
        "router/messages.rs": [
            ("list_messages", "Path(chat_id): Path<String>, Query(params): Query<ListParams>", "Vec<Message>", "Messages", "wechat_messages::list_messages(&active.account_dir, &keys, &chat_id, params.limit, params.offset)"),
        ],
    }
    for name, functions in specifications.items():
        text = originals[PREFIX + name].decode()
        for function in functions:
            text = replace_function(text, function[0], read_function(*function))
        outputs[PREFIX + name] = (imports + text).encode()
    return outputs

def prepare(source):
    base = prior().prepare(source)
    return transform({name: (source / name).read_bytes() for name in EXPECTED}, base_outputs=base)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    outputs = prepare(args.source)
    for name, data in outputs.items():
        target = args.source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(json.dumps({"schema": "cf-active-account-overlay/v1", "upstream_revision": REVISION,
                      "active_account_reader": True, "session_identity_written": False,
                      "regression_only": False, "expected_account_included": False,
                      "filename_included": False,
                      "files_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in outputs.items()}}, sort_keys=True))

if __name__ == "__main__":
    main()
