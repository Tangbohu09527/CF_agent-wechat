
#[cfg(test)]
mod live_login_observation_tests {
    use super::*;
    use crate::ia::selectors::query_selector;
    use serde_json::json;

    fn account_tree(button: &str, with_switch: bool) -> A11yNode {
        let mut children = vec![json!({"role":"push-button","name":button})];
        if with_switch {
            children.push(json!({"role":"push-button","name":"Switch Account"}));
        }
        serde_json::from_value(json!({
            "role":"desktop", "name":"", "children":[{
                "role":"frame", "name":"Weixin",
                "bounds":{"x":0,"y":0,"width":500,"height":500},
                "children":children
            }]
        })).unwrap()
    }

    fn stale_online() -> AppState {
        let mut previous = AppState::default();
        previous.main_window.view = MainWindowView::ChatOpen;
        previous.main_window.is_logged_in = true;
        previous
    }

    #[test]
    fn live_login_enter_weixin_is_recognized_for_auth_and_health() {
        let tree = account_tree("Enter Weixin", true);
        let identified = identify_states(&tree, "");
        // health_monitor uses this same main_window.is_some() recognition.
        assert!(identified.main_window.is_some(), "saved account is a responsive main state");
        assert_eq!(identified.main_window.as_ref().unwrap().state_id, "login_account");
        let state = reduce_auth_observation(&stale_online(), &tree, &[], &identified).unwrap();
        assert!(!state.main_window.is_logged_in);
        assert_eq!(state.main_window.view, MainWindowView::LoginAccount);
    }

    #[test]
    fn live_login_safe_button_aliases_never_select_switch_account() {
        let selector = match crate::ia::actions::click_login() {
            Action::ClickSelector { selector } => selector,
            _ => panic!("login must remain a selector action"),
        };
        for label in ["Log In", "Open WeChat", "Enter Weixin"] {
            let tree = account_tree(label, true);
            assert!(identify_states(&tree, "").main_window.is_some(), "{label}");
            assert_eq!(query_selector(&tree, &selector).map(|node|node.name.as_str()), Some(label));
        }
        assert!(query_selector(&account_tree("Switch Account", true), &selector).is_none());
    }

    #[test]
    fn live_login_unrecognized_observation_does_not_reuse_online_state() {
        let tree = account_tree("Unrecognized control", false);
        let observed = identify_states(&tree, "");
        assert!(observed.main_window.is_none());
        assert_eq!(reduce_auth_observation(&stale_online(), &tree, &[], &observed).unwrap_err(),
                   "observation_unrecognized");
    }

    #[test]
    fn live_login_unknown_state_id_and_wrong_fsm_fail_closed() {
        let tree = account_tree("Log In", true);
        for (id, fsm) in [("missing-state", "mainWindow"), ("login_account", "popup")] {
            let mut observed = identify_states(&tree, "");
            observed.main_window = Some(IdentifiedState {
                state_id: id.to_string(), fsm: fsm.to_string(), frame: None,
            });
            assert_eq!(reduce_auth_observation(&stale_online(), &tree, &[], &observed).unwrap_err(),
                       "observation_unrecognized");
        }
    }

    #[test]
    fn live_login_real_chat_fixture_still_observes_online() {
        let tree: A11yNode = serde_json::from_str(
            include_str!("../ia/states/test_fixtures/chat_view.json")).unwrap();
        let observed = identify_states(&tree, "");
        let state = reduce_auth_observation(&AppState::default(), &tree, &[], &observed).unwrap();
        assert!(state.main_window.is_logged_in);
    }

    #[test]
    fn live_login_enter_without_saved_account_controls_is_not_account_page() {
        let tree = account_tree("Enter Weixin", false);
        assert!(identify_states(&tree, "").main_window.is_none());
    }
}
