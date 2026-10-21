#!/usr/bin/env python3
"""Apply a preserve-only login overlay to one clean, pinned offline source tree."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
REVISION="96c2e90c497d999bf5189a134a9b3b293731f42e"
PREFIX="packages/agent-server-rust/src/"
EXPECTED={
    PREFIX+"plans/login.rs":"a50828bec313d1a5ec1558b943678a679152de7cc7780b944ae8f1ec3a4aab6c",
    PREFIX+"router/status.rs":"f0331c1bada5f5d617bdc084891df10045ff44c38293a8e451db8ad420dbeb67",
    PREFIX+"plans/mod.rs":"a4423ea063772c6d501bb73d71fad9e45da0119202164f6525d5f1a375504a2c",
    PREFIX+"execution/mod.rs":"47d46f059e380f77459cf8b04fe4b82ee7d3ff1e7b03ae4f3b5fa8f6749a0c9a",
}
OVERLAY=ROOT/"upstream/login-expected-account"

def replace(text,old,new):
    if text.count(old)!=1:raise ValueError("reviewed upstream shape changed")
    return text.replace(old,new,1)

def safe_logging(text):
    return replace(text,'.map(|s| format!("{:?}", s.action))','.map(|_| "selected".to_string())')

def transform(inputs):
    original={k:v.replace(b"\r\n",b"\n") for k,v in inputs.items()}
    if set(original)!=set(EXPECTED) or any(hashlib.sha256(original[k]).hexdigest()!=v for k,v in EXPECTED.items()):raise ValueError("upstream source identity mismatch")
    login=original[PREFIX+"plans/login.rs"].decode()
    login=login.replace("use crate::tools::wechat_db::{find_account_dir, find_wechat_pid};","use crate::tools::wechat_db::find_wechat_pid;").replace("use rusqlite::params;\n","")
    login=replace(login,"    pub new_account: bool,","    pub new_account: bool,\n    pub expected_account: String,")
    login=replace(login,"    pub detect_retries: u32,","    pub detect_retries: u32,\n    pub failure: Option<String>,")
    login=replace(login,"            detect_retries: 0,","            detect_retries: 0,\n            failure: None,")
    login=replace(login,"            && matches!(plan_state.phase, LoginPhase::Done)","            && plan_state.failure.is_none()\n            && matches!(plan_state.phase, LoginPhase::Done)")
    login=replace(login,"        let frame = || identified.main_window.as_ref().and_then(|m| m.frame.clone());",'''        if plan_state.failure.is_some() { return None; }
        {
            let db=get_db();
            let stored=queries::get_session_logged_in_user(&db,session_id);
            if let Err(code)=super::login_guard::validate_input(Some(&params.expected_account),params.new_account)
                .and_then(|expected| super::login_guard::validate_stored(expected,stored.as_deref())) {
                return reject_login(plan_state,code);
            }
        }
        let frame = || identified.main_window.as_ref().and_then(|m| m.frame.clone());''')
    login=replace(login,"handle_detecting_user(state, plan_state, session_id, frame()).await","handle_detecting_user(state, params, plan_state, session_id, frame()).await")
    login=replace(login,"handle_extracting_keys(plan_state, session_id, frame()).await","handle_extracting_keys(params, plan_state, session_id, frame()).await")
    login=replace(login,'''            let action = if params.new_account {
                actions::click_switch_account()
            } else {
                actions::click_login()
            };''',"            let action = actions::click_login();")
    login=replace(login,"fn handle_authenticating(\n    state: &AppState,\n    params: &LoginParams,","fn handle_authenticating(\n    state: &AppState,\n    _params: &LoginParams,")
    login=login[:login.index("async fn handle_detecting_user(")]+(OVERLAY/"detect.rs").read_text(encoding="utf-8")+(OVERLAY/"plan-tests.rs").read_text(encoding="utf-8")
    route=original[PREFIX+"router/status.rs"].decode()
    route=replace(route,"use axum::{","use axum::{\n    http::StatusCode,")
    route=replace(route,'        "version": "0.1.0"','        "version": "0.1.0",\n        "loginCapabilities": crate::plans::login_guard::capabilities()')
    start=route.index("pub async fn auth_status()");end=route.index("/// Log out",start)
    auth=route[start:end].replace('Json(serde_json::json!({','Json(serde_json::json!({\n                "loginCapabilities": crate::plans::login_guard::capabilities(),')
    auth=replace(auth,'    let status = if context.state.main_window.is_logged_in {','''    if context.state.main_window.is_logged_in {
        let observed=crate::tools::wechat_db::find_wechat_pid()
            .and_then(|pid|crate::plans::login_guard::observe_account(pid).ok().flatten());
        let code=match (session.logged_in_user.as_deref(),observed.as_deref()) {
            (Some(stored),Some(actual)) if stored==actual=>None,
            (Some(_),Some(_))=>Some("observed_account_mismatch"),
            _=>Some("observed_account_unknown"),
        };
        if let Some(code)=code {
            return Json(serde_json::json!({"status":"unknown","error":code,"identityVerified":false,
                "loggedInUser":session.logged_in_user,"loginCapabilities":crate::plans::login_guard::capabilities()}));
        }
    }
    let status = if context.state.main_window.is_logged_in {''')
    route=route[:start]+auth+route[end:]
    route=replace(route,"    new_account: bool,","    new_account: bool,\n    #[serde(rename = \"expectedAccount\", default)]\n    expected_account: Option<String>,")
    route=replace(route,"    ws.on_upgrade(move |socket| handle_login_ws(socket, params))",'''    let expected=match crate::plans::login_guard::validate_input(params.expected_account.as_deref(),params.new_account) {
        Ok(expected)=>expected,
        Err(code)=>return (StatusCode::CONFLICT,Json(serde_json::json!({"success":false,"error":code}))).into_response(),
    };
    let stored=get_session("default").and_then(|session|session.logged_in_user);
    if let Err(code)=crate::plans::login_guard::validate_stored(expected,stored.as_deref()) {
        return (StatusCode::CONFLICT,Json(serde_json::json!({"success":false,"error":code}))).into_response();
    }
    ws.on_upgrade(move |socket| handle_login_ws(socket, params)).into_response()''')
    route=replace(route,"        new_account: params.new_account,","        new_account: params.new_account,\n        expected_account: params.expected_account.clone().unwrap_or_default(),")
    route=replace(route,"        run_execution_loop(&plan, &login_params, &mut context, &emit, cancel_for_exec).await.0",'''        let (mut result,state)=run_execution_loop(&plan,&login_params,&mut context,&emit,cancel_for_exec).await;
        if let Some(code)=state.failure { result.success=false;result.error=Some(code); }
        result''')
    route=replace(route,"Some(result) if result.success => LoginSubscriptionEvent::LoginSuccess { user_id: None }","Some(result) if result.success => LoginSubscriptionEvent::LoginSuccess { user_id: params.expected_account.clone() }")
    route+=(OVERLAY/"route-tests.rs").read_text(encoding="utf-8")
    plans=replace(original[PREFIX+"plans/mod.rs"].decode(),"pub mod login;","pub mod login;\npub(crate) mod login_guard;")
    return {PREFIX+"plans/login.rs":login.encode(),PREFIX+"router/status.rs":route.encode(),PREFIX+"plans/mod.rs":plans.encode(),PREFIX+"plans/login_guard.rs":(OVERLAY/"login_guard.rs").read_bytes(),PREFIX+"execution/mod.rs":safe_logging(original[PREFIX+"execution/mod.rs"].decode()).encode()}

def prepare(source,with_filename=False):
    revision=subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
    status=subprocess.check_output(["git","-C",str(source),"status","--porcelain","--untracked-files=all"],text=True)
    if revision!=REVISION or status.strip():raise ValueError("refuse non-exact or modified upstream checkout")
    outputs=transform({k:(source/k).read_bytes() for k in EXPECTED})
    if with_filename:
        spec=importlib.util.spec_from_file_location("filename_overlay",ROOT/"scripts/apply-return-filename.py");module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        filename=module.transform({k:(source/k).read_bytes() for k in module.EXPECTED},ROOT/"upstream/return-filename")
        outputs={**filename,**outputs,PREFIX+"execution/mod.rs":safe_logging(filename[PREFIX+"execution/mod.rs"].decode()).encode()}
    return outputs

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--source",type=Path,required=True);parser.add_argument("--with-return-filename",action="store_true");args=parser.parse_args()
    source=args.source.resolve();outputs=prepare(source,args.with_return_filename)
    for name,data in outputs.items():
        target=source/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    print(json.dumps({"schema":"cf-expected-account-overlay/v1","upstream_revision":REVISION,"contract":"expected-account-v1","applied":True,"return_filename_included":args.with_return_filename,"files_sha256":{k:hashlib.sha256(v).hexdigest() for k,v in outputs.items()}},sort_keys=True))

if __name__=="__main__":main()
