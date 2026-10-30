//! Window moves, applied on a queue per app.
//!
//! Each Accessibility call blocks until the target app answers, and some apps
//! (Chromium and Electron ones) take several milliseconds. Moving every window
//! from the loop let the slowest app hold up the whole frame, and with frames
//! timed to the display (see `ecs::frame_step`), a frame that runs long misses
//! the next refresh and waits for the one after. Instead the loop posts each
//! window's newest position to its app's queue and carries on: the queue
//! applies it when the app is ready, so a slow app skips frames while
//! everything else stays smooth.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use dispatch2::{
    DispatchQoS, DispatchQueue, DispatchQueueAttr, DispatchRetained, DispatchSemaphore,
    DispatchTime,
};

use crate::platform::{Pid, WinID};

/// How long after one of Paneru's moves lands an app's report of the window
/// moving is taken to be that move, echoed back, rather than read again.
const OWN_MOVE_GRACE: Duration = Duration::from_millis(100);
/// Longest [`flush`] waits for an app that's slow to take its moves.
const FLUSH_TIMEOUT: Duration = Duration::from_secs(1);

/// Paneru's moves of one window: how many were posted and how many have
/// landed, and when the last one did.
#[derive(Debug, Default)]
pub(super) struct MoveCount {
    posted: AtomicU64,
    landed: AtomicU64,
    landed_at: Mutex<Option<Instant>>,
}

impl MoveCount {
    /// A move posted hasn't landed yet.
    pub(super) fn in_flight(&self) -> bool {
        self.landed.load(Ordering::Acquire) < self.posted.load(Ordering::Acquire)
    }

    /// A move is in flight, or one landed moments ago: an app reporting the
    /// window moved is most likely reporting that.
    pub(super) fn recently_moved(&self) -> bool {
        self.in_flight() || lock(&self.landed_at).is_some_and(|at| at.elapsed() < OWN_MOVE_GRACE)
    }
}

type Move = Box<dyn FnOnce() + Send>;

/// One app's queue, and the moves waiting for it.
struct AppQueue {
    queue: DispatchRetained<DispatchQueue>,
    pending: Mutex<Pending>,
}

#[derive(Default)]
struct Pending {
    /// The newest move of each window: posting another replaces one not yet
    /// applied, so a slow app skips straight to where the window is now.
    moves: HashMap<WinID, Move>,
    /// A drain is queued or running: new moves just join it.
    scheduled: bool,
}

impl AppQueue {
    /// Applies everything waiting, until nothing is left.
    fn drain(&self) {
        loop {
            let moves: Vec<Move> = {
                let mut pending = lock(&self.pending);
                if pending.moves.is_empty() {
                    pending.scheduled = false;
                    return;
                }
                pending.moves.drain().map(|(_, apply)| apply).collect()
            };
            for apply in moves {
                apply();
            }
        }
    }
}

static QUEUES: LazyLock<Mutex<HashMap<Pid, Arc<AppQueue>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn queue(pid: Pid) -> Arc<AppQueue> {
    lock(&QUEUES)
        .entry(pid)
        .or_insert_with(|| {
            let attribute = DispatchQueueAttr::with_qos_class(
                DispatchQueueAttr::SERIAL,
                DispatchQoS::UserInteractive,
                0,
            );
            Arc::new(AppQueue {
                queue: DispatchQueue::new(&format!("paneru.moves.{pid}"), Some(&attribute)),
                pending: Mutex::default(),
            })
        })
        .clone()
}

/// Moves `window`, of the app `pid`, by running `apply` on the app's queue,
/// replacing any move of it that hasn't been applied yet.
pub(super) fn post(
    pid: Pid,
    window: WinID,
    count: &Arc<MoveCount>,
    apply: impl FnOnce() + Send + 'static,
) {
    let number = count.posted.fetch_add(1, Ordering::AcqRel) + 1;
    let count = count.clone();
    let job: Move = Box::new(move || {
        apply();
        *lock(&count.landed_at) = Some(Instant::now());
        // A replaced move never runs, so this counts it as landed too.
        count.landed.fetch_max(number, Ordering::AcqRel);
    });
    let app = queue(pid);
    let start = {
        let mut pending = lock(&app.pending);
        pending.moves.insert(window, job);
        !std::mem::replace(&mut pending.scheduled, true)
    };
    if start {
        let drain = app.clone();
        app.queue.exec_async(move || drain.drain());
    }
}

/// Waits, up to a second, for every move of the app `pid` posted so far to
/// land, so that something done to its windows right after can't be overtaken
/// by an older move.
pub(super) fn flush(pid: Pid) {
    let Some(app) = lock(&QUEUES).get(&pid).cloned() else {
        return;
    };
    let done = DispatchSemaphore::new(0);
    let signal = done.clone();
    app.queue.exec_async(move || {
        signal.signal();
    });
    done.wait(DispatchTime::try_from(FLUSH_TIMEOUT).unwrap_or(DispatchTime::FOREVER));
}

/// Drops the queue of an app that has quit.
pub(crate) fn forget(pid: Pid) {
    lock(&QUEUES).remove(&pid);
}
