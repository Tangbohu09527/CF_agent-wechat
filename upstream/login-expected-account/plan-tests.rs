#[cfg(test)]
mod expected_account_plan_tests {
    use super::*;
    #[test]
    fn expected_account_failure_cannot_become_login_success() {
        let mut state=AppState::default();state.main_window.view=MainWindowView::Chat;
        let mut plan=LoginPlan.initial_plan_state();plan.phase=LoginPhase::Done;
        assert!(LoginPlan.is_goal_reached(&state,&plan));
        assert!(reject_login(&mut plan,"observed_account_mismatch").is_none());
        assert!(!LoginPlan.is_goal_reached(&state,&plan));
    }
    #[test]
    fn expected_account_preserve_flow_has_no_switch_action() {
        let mut state=AppState::default();state.main_window.view=MainWindowView::LoginAccount;
        let params=LoginParams{new_account:false,expected_account:"synthetic-a".into()};
        let mut plan=LoginPlan.initial_plan_state();
        let selected=handle_authenticating(&state,&params,&mut plan,&||None).unwrap();
        match selected.action {Action::ClickSelector{selector}=>assert!(!selector.contains("Switch Account")),_=>panic!("Unexpected action")}
    }
}
