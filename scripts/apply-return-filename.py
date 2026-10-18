#!/usr/bin/env python3
"""Apply a narrow overlay to the exact reviewed upstream source, never a live image."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

REVISION = "96c2e90c497d999bf5189a134a9b3b293731f42e"
PREFIX = "packages/agent-server-rust/src/"
EXPECTED = {
    PREFIX + "router/messages.rs": "7ab7c8460d7cb17e15b6c4d7a32d5ae8e3f430e778d4d7a26b164c35ce9297e0",
    PREFIX + "router/mod.rs": "ea0b715744827b7ad9ab82694787c3d15e57bfa344005f6245379cd58a06d768",
    PREFIX + "plans/send_message.rs": "711c7a470b47ad9eba4861ec6f9cc11d249f6272becff8a368b4972cd5c8f775",
    PREFIX + "execution/mod.rs": "47d46f059e380f77459cf8b04fe4b82ee7d3ff1e7b03ae4f3b5fa8f6749a0c9a",
    "docker/tools/paste-file": "64938f4656f8507e3487afb622db9e14b1b3e439950cd46e6c2a9b5047630a89",
}

FILE_BLOCK = '''    // Decode before publishing; never rename a valid user basename.
    let mut prepared_file: Option<super::return_file::PreparedFile> = None;
    if let Some(ref f) = input.file {
        if !super::return_file::valid_filename(&f.filename) {
            return Json(SendResult { success: false, error: Some("Invalid file name".into()) });
        }
        if f.data.len() > super::MAX_UPLOAD_BASE64_BYTES {
            return Json(SendResult { success: false, error: Some("File exceeds the 128 MiB upload limit".into()) });
        }
        let bytes = match base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &f.data) {
            Ok(bytes) if bytes.len() <= super::MAX_UPLOAD_BYTES => bytes,
            Ok(_) => return Json(SendResult { success: false, error: Some("File exceeds the 128 MiB upload limit".into()) }),
            Err(_) => return Json(SendResult { success: false, error: Some("Invalid base64 file data".into()) }),
        };
        match super::return_file::PreparedFile::create(std::path::Path::new("/tmp"), &f.filename, &bytes) {
            Ok(file) => prepared_file = Some(file),
            Err(_) => return Json(SendResult { success: false, error: Some("Failed to prepare file".into()) }),
        }
    }
    let file_path = prepared_file.as_ref().map(|f| f.path().to_string_lossy().into_owned());

'''

def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()

def replace_one(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError("upstream shape changed")
    return text.replace(old, new, 1)

def transform(inputs: dict[str, bytes], overlay: Path) -> dict[str, bytes]:
    normalized = {name: raw.replace(b"\r\n", b"\n") for name, raw in inputs.items()}
    if set(normalized) != set(EXPECTED) or any(digest(normalized[n]) != h for n, h in EXPECTED.items()):
        raise ValueError("upstream source identity mismatch")
    route = normalized[PREFIX + "router/messages.rs"].decode()
    start, end = route.index("    // Decode base64 file to temp file"), route.index("    let mut context =", route.index("pub async fn send_message"))
    route = route[:start] + route[end:]
    # Reject/prepare the file before the unchanged image block can create a
    # temporary image. Any later image validation return drops PreparedFile.
    route = replace_one(route, "    // Decode base64 image to temp file", FILE_BLOCK + "    // Decode base64 image to temp file")
    route = replace_one(route, "    let plan = SendMessagePlan;", "    let execute = async move {\n    let plan = SendMessagePlan;")
    route = replace_one(route, '''    let (result, _plan_state) =
        run_execution_loop(&plan, &params, &mut context, &noop_emit, cancel).await;''', '''    let (result, _plan_state) = if params.file_path.is_some() {
        crate::execution::run_file_execution_loop(&plan, &params, &mut context, &noop_emit, cancel).await
    } else {
        run_execution_loop(&plan, &params, &mut context, &noop_emit, cancel).await
    };''')
    route = replace_one(route, '''    if let Some(p) = &file_path {
        let _ = std::fs::remove_file(p);
    }

    Json(SendResult {
        success: result.success,
        error: result.error,
    })
}''', '''    SendResult { success: result.success, error: result.error }
    };
    // Only accepted file sends detach on HTTP disconnect. The existing plan's
    // timeout remains inside the owned task; there are no new retries.
    let result = if let Some(file) = prepared_file {
        match super::return_file::retain_for_send(file, execute).await {
            Ok(result) => result,
            Err(_) => {
                tracing::error!("file send task failed");
                SendResult { success: false, error: Some("File send task failed".into()) }
            }
        }
    } else { execute.await };
    Json(result)
}''')
    plan = replace_one(normalized[PREFIX + "plans/send_message.rs"].decode(),
        '                        exec_command("paste-file", &[fp], &ExecOptions::default()).await;',
        '''                        let pasted = exec_command("paste-file", &[fp], &ExecOptions::default()).await;
                        if pasted.exit_code != 0 {
                            return None; // Do not press Return or report success after a failed paste.
                        }''')
    mod = replace_one(normalized[PREFIX + "router/mod.rs"].decode(), "mod messages;", "mod messages;\nmod return_file;")
    execution = normalized[PREFIX + "execution/mod.rs"].decode()
    start = execution.index("pub async fn run_execution_loop<")
    body = execution.index("    let _gui_guard = acquire_gui_guard().await;", start)
    signature = execution[start:body]
    wrappers = signature + '''    let guard = acquire_gui_guard().await;
    run_execution_loop_owned(plan, params, context, emit, cancel, guard).await
}

''' + signature.replace("run_execution_loop<", "run_file_execution_loop<") + '''    let guard = match acquire_file_gui_guard(std::time::Duration::from_secs(30)).await {
        Ok(guard) => guard,
        Err(_) => return (ExecutionResult { success: false, error: Some("File send queue timeout".into()) }, plan.initial_plan_state()),
    };
    run_execution_loop_owned(plan, params, context, emit, cancel, guard).await
}

async fn acquire_file_gui_guard(limit: std::time::Duration) -> Result<GuiGuard, tokio::time::error::Elapsed> {
    tokio::time::timeout(limit, acquire_gui_guard()).await
}

'''
    inner = signature.replace("pub async fn run_execution_loop<", "async fn run_execution_loop_owned<")
    inner = replace_one(inner, "    cancel: CancellationToken,", "    cancel: CancellationToken,\n    _gui_guard: GuiGuard,")
    execution = execution[:start] + wrappers + inner + execution[body:].replace("    let _gui_guard = acquire_gui_guard().await;\n", "", 1)
    execution += (overlay / "queue_contract.rs").read_text(encoding="utf-8")
    return {PREFIX + "router/messages.rs": route.encode(), PREFIX + "router/mod.rs": mod.encode(),
            PREFIX + "plans/send_message.rs": plan.encode(),
            PREFIX + "execution/mod.rs": execution.encode(),
            PREFIX + "router/return_file.rs": (overlay / "return_file.rs").read_bytes(),
            "docker/tools/paste-file": (overlay / "paste-file").read_bytes()}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    def git(*argv: str) -> str:
        return subprocess.check_output(["git", "-C", str(source), *argv], text=True).strip()
    if git("rev-parse", "HEAD") != REVISION or git("status", "--porcelain"):
        raise SystemExit("refuse non-exact or modified upstream checkout")
    overlay = Path(__file__).resolve().parents[1] / "upstream" / "return-filename"
    result = transform({name: (source / name).read_bytes() for name in EXPECTED}, overlay)
    target = source / PREFIX / "router/return_file.rs"
    if target.exists():
        raise SystemExit("refuse existing overlay file")
    if not args.check_only:
        for name, raw in result.items():
            (source / name).write_bytes(raw)
    print(json.dumps({"schema": "cf-return-filename-overlay/v1", "upstream_revision": REVISION,
                      "applied": not args.check_only, "sha256": {n: digest(raw) for n, raw in result.items()}}, sort_keys=True))

if __name__ == "__main__":
    main()
