//! How far animations step each tick.
//!
//! While anything animates, the platform's display link (see
//! `platform::frame_clock`) wakes the loop once per display refresh. Animations
//! then step only on those ticks, by the time between the frames the display
//! shows, so every window moves once per frame and evenly: the loop's own
//! wake-ups (input, apps reporting moves, timers) land at arbitrary points
//! between frames, and stepping on them moved windows unevenly, sometimes twice
//! in one frame and then not at all in the next. Without a display link (in
//! tests, or before macOS 14), animations step by the loop's own time, as they
//! always have.

use std::pin::Pin;
use std::time::Duration;

use bevy::ecs::message::MessageReader;
use bevy::ecs::query::With;
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{NonSendMut, Query, Res, ResMut};
use bevy::time::Time;
use objc2_core_graphics::CGDirectDisplayID;

use super::ActiveDisplayMarker;
use super::params::FrameActivity;
use crate::events::Event;
use crate::manager::Display;
use crate::platform::PlatformCallbacks;

/// Largest step a display frame can take: a frame held up by a slow app
/// mustn't make an animation jump.
pub(crate) const MAX_FRAME_STEP_SECS: f64 = 1.0 / 30.0;
/// One frame at 120 Hz: the first step of an animation, taken as soon as it
/// starts rather than after waiting for the display.
const FIRST_STEP_SECS: f64 = 1.0 / 120.0;
/// How long to wait for the display's next frame before keeping time
/// ourselves, e.g. while the display sleeps.
const FRAME_TIMEOUT: Duration = Duration::from_millis(40);

#[derive(Resource, Default)]
pub struct FrameStep {
    /// This tick's step in seconds, or `None` to leave animations where they
    /// are until the display's next frame.
    dt: Option<f64>,
    /// When the display showed the last frame, on its own clock.
    shown_at: Option<f64>,
    /// When that frame reached the loop, on the loop's clock.
    arrived: Option<Duration>,
    /// The display frames were asked for, if any, and whether they're coming.
    requested: Option<CGDirectDisplayID>,
    running: bool,
    /// The platform can time frames (it can't in tests).
    available: bool,
    /// Something animated last tick.
    animating: bool,
}

impl FrameStep {
    /// How far to step animations this tick, in seconds; `None` to hold them
    /// for the display's next frame.
    pub fn dt(&self) -> Option<f64> {
        self.dt
    }

    /// Frames are coming from the display, so the loop needn't wake itself
    /// to animate.
    pub fn display_timed(&self) -> bool {
        self.running
    }
}

/// Works out this tick's step from the display frames pumped this tick.
pub(super) fn advance_frame_step(
    mut messages: MessageReader<Event>,
    time: Res<Time>,
    mut step: ResMut<FrameStep>,
) {
    let shown = messages
        .read()
        .filter_map(|event| match event {
            Event::DisplayFrame { at } => Some(*at),
            _ => None,
        })
        .last();
    let now = time.elapsed();
    step.dt = if let Some(at) = shown {
        let dt = step.shown_at.map_or(FIRST_STEP_SECS, |previous| {
            (at - previous).clamp(0.0, MAX_FRAME_STEP_SECS)
        });
        step.shown_at = Some(at);
        step.arrived = Some(now);
        Some(dt)
    } else if step.running
        && step
            .arrived
            .is_some_and(|arrived| now.saturating_sub(arrived) < FRAME_TIMEOUT)
    {
        None
    } else if step.available && !step.animating {
        // Just started, between frames: step one frame now rather than by the
        // time spent idle.
        Some(FIRST_STEP_SECS)
    } else {
        Some(time.delta_secs_f64())
    };
}

/// Runs the display link while anything animates, and stops it after.
pub(super) fn run_frame_clock(
    activity: FrameActivity,
    displays: Query<&Display, With<ActiveDisplayMarker>>,
    platform: Option<NonSendMut<Pin<Box<PlatformCallbacks>>>>,
    time: Res<Time>,
    mut step: ResMut<FrameStep>,
) {
    step.animating = activity.mid_frame();
    let Some(mut platform) = platform else {
        return;
    };
    step.available = true;
    let wanted = if step.animating {
        displays.iter().next().map(Display::id)
    } else {
        None
    };
    if wanted == step.requested {
        return;
    }
    step.requested = wanted;
    step.running = platform.run_frame_clock(wanted);
    // Frames from before a pause say nothing about how long the next one takes.
    step.shown_at = None;
    // Counts as a frame, so a display link that never ticks still times out.
    step.arrived = step.running.then(|| time.elapsed());
}
