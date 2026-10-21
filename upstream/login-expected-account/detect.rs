async fn handle_detecting_user(state:&AppState,params:&LoginParams,plan_state:&mut LoginPlanState,session_id:&str,frame:Option<FrameHint>)->Option<SelectedAction> {
    if !matches!(state.main_window.view,MainWindowView::Chat|MainWindowView::ChatOpen) { return Some(SelectedAction{action:actions::wait(500),frame:None}); }
    let pid=find_wechat_pid();
    let account=match pid { Some(pid)=>match super::login_guard::observe_account(pid) {Ok(account)=>account,Err(code)=>return reject_login(plan_state,code)},None=>None};
    if let (Some(pid),Some(account))=(pid,account) {
        let needs_keys={let db=get_db();if let Err(code)=super::login_guard::commit_verified_session(&db,session_id,&params.expected_account,&account,pid){return reject_login(plan_state,code);}needs_key_extraction(&db,session_id,&account)};
        plan_state.account_dir=Some(account.clone());
        if !needs_keys {plan_state.phase=LoginPhase::Done;return Some(login_success_action(account,frame));}
        plan_state.phase=LoginPhase::ExtractingKeys;return Some(SelectedAction{action:actions::wait_short(),frame});
    }
    plan_state.detect_retries+=1;
    if plan_state.detect_retries>=10 {return reject_login(plan_state,"observed_account_unknown");}
    Some(SelectedAction{action:actions::wait(2000),frame:None})
}
fn reject_login(plan_state:&mut LoginPlanState,code:&str)->Option<SelectedAction>{plan_state.failure=Some(code.to_string());None}
fn login_success_action(account:String,frame:Option<FrameHint>)->SelectedAction {
    SelectedAction{action:actions::sequence(vec![Action::Emit{event:SubscriptionEvent{event_type:"login_success".into(),data:[("userId".to_string(),serde_json::Value::String(account))].into_iter().collect()}},actions::wait_short()]),frame}
}
async fn handle_extracting_keys(params:&LoginParams,plan_state:&mut LoginPlanState,session_id:&str,frame:Option<FrameHint>)->Option<SelectedAction> {
    let Some(pid)=find_wechat_pid() else{return reject_login(plan_state,"observed_account_unknown");};
    let account=match super::login_guard::observe_account(pid){Ok(Some(account))=>account,_=>return reject_login(plan_state,"observed_account_unverifiable")};
    {let db=get_db();if let Err(code)=super::login_guard::validate_observed(&db,session_id,&params.expected_account,Some(&account)){return reject_login(plan_state,code);}}
    if plan_state.account_dir.as_deref()!=Some(account.as_str()){return reject_login(plan_state,"observed_account_changed");}
    let keys=extract_keys_async(pid).await;
    if keys.is_empty(){return reject_login(plan_state,"key_extraction_failed");}
    if find_wechat_pid()!=Some(pid)||super::login_guard::observe_account(pid).ok().flatten().as_deref()!=Some(account.as_str()){return reject_login(plan_state,"observed_account_changed");}
    {let db=get_db();if let Err(code)=super::login_guard::validate_observed(&db,session_id,&params.expected_account,Some(&account)){return reject_login(plan_state,code);}store_keys(&db,session_id,&account,&keys);}
    plan_state.phase=LoginPhase::Done;Some(login_success_action(account,frame))
}
