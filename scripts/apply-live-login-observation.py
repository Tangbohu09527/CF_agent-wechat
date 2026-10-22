#!/usr/bin/env python3
"""Minimal observation/WAL overlay for the exact clean official 96c2e90 source.

Default output has no expected-account, file-send or installer changes.
--regression-only attaches native regressions while retaining old behavior.
--with-expected-account explicitly composes the separate preserve-only login guard.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "96c2e90c497d999bf5189a134a9b3b293731f42e"
PREFIX = "packages/agent-server-rust/src/"
EXPECTED = {
    PREFIX + "ia/states/login.rs": "d095406a8a97313d2a66ff5c80e361d1e8a1d52c109d154b54b5b0822be9fb2c",
    PREFIX + "ia/actions.rs": "232eef5825cdc2fb0fae0f7b653851298923925796eb8977e518df60a3b42ed0",
    PREFIX + "router/status.rs": "f0331c1bada5f5d617bdc084891df10045ff44c38293a8e451db8ad420dbeb67",
    PREFIX + "tools/wechat_db.rs": "f29acc1a5a8f4194122843c65ea0f3351870e08bd062f07194482beeef0cea10",
}
OVERLAY = ROOT / "upstream/live-login-observation"
REDUCTION = '''    if let Some(ref mw) = identified.main_window {
        if let Some(state_impl) = find_state_by_id(&mw.state_id) {
            let screenshot_bytes = base64::engine::general_purpose::STANDARD
                .decode(&screenshot)
                .unwrap_or_default();
            context.state = state_impl.reduce(&ReduceArgs {
                prev: &context.state,
                a11y: &a11y,
                screenshot: &screenshot_bytes,
            });
        }
    }'''


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("reviewed upstream shape changed")
    return text.replace(old, new, 1)


def transform(inputs, *, regression_only=False, guarded_outputs=None):
    original = {name: data.replace(b"\r\n", b"\n") for name, data in inputs.items()}
    if set(original) != set(EXPECTED) or any(
        hashlib.sha256(original[name]).hexdigest() != digest
        for name, digest in EXPECTED.items()
    ):
        raise ValueError("upstream source identity mismatch")
    outputs = dict(guarded_outputs or {})
    login = original[PREFIX + "ia/states/login.rs"].decode()
    actions = original[PREFIX + "ia/actions.rs"].decode()
    route = outputs.get(PREFIX + "router/status.rs", original[PREFIX + "router/status.rs"]).decode()
    reader = original[PREFIX + "tools/wechat_db.rs"].decode().split("#[cfg(test)]")[0]
    if not regression_only:
        login = replace_once(
            login,
            '.or_else(|| query_selector(args.a11y, r#"push-button[name="Open WeChat"]"#));',
            '.or_else(|| query_selector(args.a11y, r#"push-button[name="Open WeChat"]"#))\n'
            '            .or_else(|| query_selector(args.a11y, r#"push-button[name="Enter Weixin"]"#));',
        )
        actions = replace_once(actions, "Log In|Open WeChat", "Log In|Open WeChat|Enter Weixin")
        start = reader.index("/// Query a WeChat database")
        end = reader.index("pub fn query_wechat_db(")
        reader = reader[:start] + '''/// Query current committed WeChat rows, including WAL, through a short read-only connection.
/// No transaction, checkpoint or journal-mode change is issued by this reader.
''' + reader[end:]
        reader = replace_once(reader, "?immutable=1", "?mode=ro")
        reader = replace_once(reader, "PRAGMA cipher_compatibility = 4;",
                              "PRAGMA cipher_compatibility = 4; PRAGMA query_only = ON; PRAGMA busy_timeout = 1000;")
    helper = '''fn reduce_auth_observation(
    previous: &AppState,
    a11y: &A11yNode,
    screenshot: &[u8],
    identified: &IdentifiedStates,
) -> Result<AppState, &'static str> {
'''
    if regression_only:
        helper += '''    if let Some(ref main) = identified.main_window {
        if let Some(state) = find_state_by_id(&main.state_id) {
            return Ok(state.reduce(&ReduceArgs { prev: previous, a11y, screenshot }));
        }
    }
    Ok(previous.clone())
}

'''
    else:
        helper += '''    let main = identified.main_window.as_ref()
        .filter(|main| main.fsm == "mainWindow")
        .ok_or("observation_unrecognized")?;
    let state = find_state_by_id(&main.state_id)
        .filter(|state| state.fsm() == "mainWindow")
        .filter(|state| matches!(state.id(),
            "chat" | "chat_open" | "login_qr" | "login_account" |
            "login_phone_confirm" | "login_loading"))
        .ok_or("observation_unrecognized")?;
    Ok(state.reduce(&ReduceArgs { prev: previous, a11y, screenshot }))
}

'''
    route = replace_once(route, "pub async fn auth_status()", helper + "pub async fn auth_status()")
    auth_start = route.index("pub async fn auth_status()")
    auth_end = route.index("/// Log out", auth_start)
    auth = route[auth_start:auth_end]
    capabilities = ('\n                "loginCapabilities": crate::plans::login_guard::capabilities(),'
                    if guarded_outputs else "")
    auth = replace_once(auth, REDUCTION, '''    let screenshot_bytes = base64::engine::general_purpose::STANDARD
        .decode(&screenshot).unwrap_or_default();
    context.state = match reduce_auth_observation(
        &context.state, &a11y, &screenshot_bytes, &identified,
    ) {
        Ok(state) => state,
        Err(_) => {
            return Json(serde_json::json!({
                "status": "unknown",
                "error": "observation_unrecognized",
                "reason": "auth_observation_unrecognized",
                "observedAt": chrono::Utc::now().to_rfc3339(),
                "identityVerified": false,
                "loggedInUser": session.logged_in_user,''' + capabilities + '''
            }));
        }
    };''')
    route = route[:auth_start] + auth + route[auth_end:]
    route += (OVERLAY / "status-tests.rs").read_text(encoding="utf-8")
    # Replace obsolete immutable/DELETE-only tests with encrypted WAL and short-reader regressions.
    reader += (OVERLAY / "db-tests.rs").read_text(encoding="utf-8")
    outputs.update({PREFIX + "ia/states/login.rs": login.encode(),
                    PREFIX + "ia/actions.rs": actions.encode(),
                    PREFIX + "router/status.rs": route.encode(),
                    PREFIX + "tools/wechat_db.rs": reader.encode()})
    return outputs


def prepare(source, with_expected_account=False, regression_only=False):
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    status = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"], text=True)
    if revision != REVISION or status.strip():
        raise ValueError("refuse non-exact or modified upstream checkout")
    guarded = None
    if with_expected_account:
        spec = importlib.util.spec_from_file_location("guard_overlay", ROOT / "scripts/apply-login-expected-account.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        guarded = module.prepare(source)
    return transform({name: (source / name).read_bytes() for name in EXPECTED},
                     regression_only=regression_only, guarded_outputs=guarded)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--regression-only", action="store_true")
    parser.add_argument("--with-expected-account", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    outputs = prepare(source, args.with_expected_account, args.regression_only)
    for name, data in outputs.items():
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(json.dumps({"schema": "cf-live-observation-overlay/v1", "upstream_revision": REVISION,
                      "regression_only": args.regression_only,
                      "expected_account_included": args.with_expected_account,
                      "filename_included": False,
                      "files_sha256": {name: hashlib.sha256(data).hexdigest()
                                       for name, data in outputs.items()}}, sort_keys=True))


if __name__ == "__main__":
    main()
