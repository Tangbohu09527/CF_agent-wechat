#[cfg(test)]
mod expected_account_route_tests {
    use tokio::io::{AsyncReadExt,AsyncWriteExt};
    async fn request(path:&str,authorized:bool,websocket:bool)->String {
        static AUTH:std::sync::Once=std::sync::Once::new();
        AUTH.call_once(||{std::env::set_var("AGENT_WECHAT_TOKEN","synthetic-preserve-login-test-only");crate::router::auth::init_token();});
        let listener=tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();let address=listener.local_addr().unwrap();
        let server=tokio::spawn(async move{axum::serve(listener,crate::router::build_router()).await.unwrap();});
        let auth=if authorized{"Authorization: Bearer synthetic-preserve-login-test-only\r\n"}else{""};
        let upgrade=if websocket{"Connection: Upgrade, close\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"}else{"Connection: close\r\n"};
        let mut stream=tokio::net::TcpStream::connect(address).await.unwrap();
        stream.write_all(format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n{auth}{upgrade}\r\n").as_bytes()).await.unwrap();
        let mut bytes=Vec::new();let result=tokio::time::timeout(std::time::Duration::from_secs(5),stream.read_to_end(&mut bytes)).await;
        server.abort();result.unwrap().unwrap();String::from_utf8(bytes).unwrap()
    }
    #[tokio::test]
    async fn expected_account_capability_requires_api_authentication() {
        assert!(request("/api/status",false,false).await.starts_with("HTTP/1.1 401"));
        let response=request("/api/status",true,false).await;
        assert!(response.starts_with("HTTP/1.1 200"));
        let body=response.split("\r\n\r\n").nth(1).unwrap();let body:serde_json::Value=serde_json::from_str(body).unwrap();
        assert_eq!(body["loginCapabilities"],crate::plans::login_guard::capabilities());
    }
    #[tokio::test]
    async fn expected_account_ws_missing_identity_and_switch_are_rejected_before_native_tools() {
        let missing=request("/api/ws/login",true,true).await;
        assert!(missing.starts_with("HTTP/1.1 409"),"{missing}");assert!(missing.contains("expected_account_required"));
        let switch=request("/api/ws/login?expectedAccount=synthetic-a&newAccount=true",true,true).await;
        assert!(switch.starts_with("HTTP/1.1 409"),"{switch}");assert!(switch.contains("preserve_account_rejects_new_account"));
        assert!(request("/api/ws/login?expectedAccount=synthetic-a",false,true).await.starts_with("HTTP/1.1 401"));
    }
}
