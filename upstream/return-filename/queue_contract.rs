
#[cfg(test)]
mod filename_queue_tests {
    use super::*;
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};

    #[tokio::test]
    async fn queue_timeout_does_not_invoke_sender() {
        let held = PLAN_LOCK.lock().await;
        let invoked = AtomicBool::new(false);
        if let Ok(_guard) = acquire_file_gui_guard(std::time::Duration::from_millis(1)).await {
            invoked.store(true, Ordering::SeqCst);
        }
        assert!(!invoked.load(Ordering::SeqCst));
        drop(held);
    }

    #[tokio::test]
    async fn cancelled_queue_does_not_invoke_sender_or_keep_lock() {
        let held = PLAN_LOCK.lock().await;
        let invoked = Arc::new(AtomicBool::new(false)); let observed = invoked.clone();
        let waiting = tokio::spawn(async move {
            if let Ok(_guard) = acquire_file_gui_guard(std::time::Duration::from_secs(30)).await {
                observed.store(true, Ordering::SeqCst);
            }
        });
        tokio::task::yield_now().await;
        waiting.abort(); assert!(waiting.await.unwrap_err().is_cancelled());
        assert!(!invoked.load(Ordering::SeqCst)); drop(held);
        assert!(acquire_file_gui_guard(std::time::Duration::from_secs(1)).await.is_ok());
    }
}
