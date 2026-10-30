use bevy::app::{App, Plugin, PreUpdate, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::message::{Message, MessageReader, MessageWriter};
use bevy::ecs::query::{With, Without};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::schedule::SystemCondition as _;
use bevy::ecs::system::{Commands, Local, Populated, Res, ResMut, Single};
use bevy::math::IRect;
use bevy::time::Time;
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use tracing::{Level, instrument};

use crate::commands::{Command, Direction, Operation};
use crate::config::Config;
use crate::config::swipe::{SwipeGestureDirection, focus_direction};
use crate::ecs::frame_step::{FrameStep, MAX_FRAME_STEP_SECS};
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::params::{ActiveDisplay, Windows};
use crate::ecs::{
    ActiveWorkspaceMarker, ManualStripOffset, MissionControlActive, Position, PreUpdateSet,
    Scrolling, SendMessageTrigger, StripMotion, UpdateSet,
};
use crate::errors::Result;
use bevy::ecs::schedule::common_conditions::on_message;

use crate::events::{Event, InputEvent};
use crate::manager::{Window, WindowManager};
use crate::platform::Modifiers;
use crate::util::round_px;

pub struct ScrollEventsPlugin;

const PAGE_GESTURE_TIMEOUT: Duration = Duration::from_millis(150);

/// One gesture-earned focus step, routed to [`crate::commands::command_move_focus`].
#[derive(Message, Debug, Clone)]
pub(crate) struct PageFocusRequest {
    pub(crate) direction: Direction,
    pub(crate) generation: u64,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum PageInFlight {
    Dispatched,
    AwaitingFocus {
        target: Entity,
        deadline: Option<Duration>,
    },
}

#[derive(Default, Resource)]
pub(crate) struct PageGestureState {
    accumulated_cm: f64,
    pending: VecDeque<(Direction, u64)>,
    pub(crate) in_flight: Option<PageInFlight>,
    last_event: Option<Duration>,
    active: bool,
    config: Option<(bool, Option<usize>, SwipeGestureDirection, f64, bool)>,
    pub(crate) generation: u64,
}

impl PageGestureState {
    pub(crate) fn reset(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.accumulated_cm = 0.0;
        self.pending.clear();
        self.in_flight = None;
        self.last_event = None;
        self.active = false;
    }

    fn has_work(&self) -> bool {
        self.active || !self.pending.is_empty() || self.in_flight.is_some()
    }

    pub(crate) fn await_focus(&mut self, target: Entity) {
        self.in_flight = Some(PageInFlight::AwaitingFocus {
            target,
            deadline: None,
        });
    }

    fn earn_steps(&mut self, threshold_cm: f64, gesture_direction: SwipeGestureDirection) {
        let travel = self.accumulated_cm.abs();
        if travel < threshold_cm {
            return;
        }
        let direction = focus_direction(gesture_direction, self.accumulated_cm);
        // Saturating float-to-integer conversion bounds an implausibly large
        // gesture while preserving the earned count for normal device input.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let steps = (travel / threshold_cm).floor() as u64;
        let remainder = travel % threshold_cm;
        self.accumulated_cm = self.accumulated_cm.signum() * remainder;
        if let Some((last_direction, count)) = self.pending.back_mut()
            && *last_direction == direction
            && let Some(merged) = count.checked_add(steps)
        {
            *count = merged;
            return;
        }
        self.pending.push_back((direction, steps));
    }

    fn next_step(&mut self) -> Option<Direction> {
        let (direction, count) = self.pending.front_mut()?;
        let direction = direction.clone();
        *count -= 1;
        if *count == 0 {
            self.pending.pop_front();
        }
        Some(direction)
    }
}

fn paging_enabled(config: Res<Config>, state: Res<PageGestureState>) -> bool {
    config.swipe_gesture_paging() || state.has_work() || state.config.as_ref().is_some_and(|c| c.0)
}

fn paging_active(config: Res<Config>, state: Res<PageGestureState>) -> bool {
    state.has_work()
        || (!config.swipe_gesture_paging() && state.config.as_ref().is_some_and(|c| c.0))
}

#[cfg(test)]
mod strip_motion_tests {
    use super::{Scrolling, StripMotion, coast, coast_distance, follow};
    use std::time::Duration;

    fn flick(speed: f64) -> Scrolling {
        let mut scroll = Scrolling::at(0.0, Duration::ZERO);
        scroll.velocity = speed;
        scroll.motion = StripMotion::Coast;
        scroll
    }

    /// Coasts to a stop at `fps`, returning where it stopped and every position on the way.
    fn coast_out(speed: f64, fps: f64) -> (f64, Vec<f64>) {
        let mut scroll = flick(speed);
        let mut path = vec![];
        while scroll.motion == StripMotion::Coast {
            coast(&mut scroll, 1.0 / fps, 4.0);
            path.push(scroll.position);
        }
        (scroll.position, path)
    }

    #[test]
    fn a_flick_stops_where_its_speed_says_whatever_the_frame_rate() {
        for speed in [-3000.0, 400.0, 1500.0, 3000.0] {
            let expected = coast_distance(speed, 4.0);
            for fps in [30.0, 60.0, 120.0] {
                let (stopped, _) = coast_out(speed, fps);
                assert!(
                    (stopped - expected).abs() < 1e-6,
                    "{speed} at {fps} fps: {stopped} vs {expected}"
                );
            }
        }
        // About where the old cut-off at 5 points a frame stopped it.
        assert!((coast_distance(3000.0, 4.0) - 448.0).abs() < 1.0);
    }

    #[test]
    fn a_coasting_strip_only_slows_down() {
        let (_, path) = coast_out(2000.0, 120.0);
        let steps: Vec<f64> = path.windows(2).map(|pair| pair[1] - pair[0]).collect();
        assert!(steps.iter().all(|step| *step >= 0.0));
        assert!(steps.windows(2).all(|pair| pair[1] <= pair[0] + 1e-9));
        assert!(
            path.len() < 60,
            "stops within half a second, took {} frames",
            path.len()
        );
    }

    #[test]
    fn the_strip_keeps_up_with_the_fingers_without_overshooting() {
        let mut scroll = Scrolling::at(0.0, Duration::ZERO);
        scroll.is_user_swiping = true;
        scroll.target = 100.0;
        let mut frames = 0;
        while !scroll.is_at_rest() {
            follow(&mut scroll, 1.0 / 120.0);
            assert!(scroll.position <= 100.0);
            frames += 1;
        }
        assert!(frames <= 8, "took {frames} frames to catch up");
    }
}

#[cfg(test)]
mod release_velocity_tests {
    use super::*;

    const MS: fn(u64) -> Duration = Duration::from_millis;

    #[test]
    fn measures_finger_speed_whatever_the_frame_timing() {
        // 0.01 of the viewport every 8 ms is 1.25 viewports a second, whether
        // the frames that carry the samples are 8 ms apart or the samples land
        // a fraction of a millisecond after a burst of empty frames.
        let mut samples = SwipeSamples::default();
        for i in 0..10 {
            samples.push(MS(8 * i), 0.01);
        }
        assert!((samples.velocity(MS(72)) - 1.25).abs() < 1e-9);
    }

    #[test]
    fn pausing_before_lifting_leaves_nothing_to_coast_on() {
        let mut samples = SwipeSamples::default();
        for i in 0..10 {
            samples.push(MS(8 * i), 0.01);
        }
        assert_eq!(
            samples.velocity(MS(72) + RELEASE_VELOCITY_WINDOW + MS(1)),
            0.0
        );
    }

    #[test]
    fn only_the_last_stretch_counts() {
        // Fast, then slow for the whole window before release.
        let mut samples = SwipeSamples::default();
        for i in 0..10 {
            samples.push(MS(8 * i), 0.05);
        }
        for i in 10..30 {
            samples.push(MS(8 * i), 0.005);
        }
        assert!((samples.velocity(MS(8 * 29)) - 0.625).abs() < 1e-9);
    }
}

#[cfg(test)]
mod paging_tests {
    use super::*;

    #[test]
    fn large_swipe_preserves_every_earned_step_without_expanding_the_queue() {
        let mut state = PageGestureState {
            accumulated_cm: 80.5,
            ..Default::default()
        };
        state.earn_steps(2.0, SwipeGestureDirection::Natural);
        assert_eq!(state.pending.len(), 1);
        assert!((state.accumulated_cm - 0.5).abs() < f64::EPSILON);

        let expected = focus_direction(SwipeGestureDirection::Natural, 1.0);
        for _ in 0..40 {
            assert_eq!(state.next_step(), Some(expected.clone()));
        }
        assert_eq!(state.next_step(), None);
    }

    #[test]
    fn in_flight_focus_keeps_paging_system_active_after_finger_lift() {
        let state = PageGestureState {
            in_flight: Some(PageInFlight::Dispatched),
            ..Default::default()
        };
        assert!(state.has_work());
    }
}

/// How tightly the strip follows the fingers: a critically damped spring this
/// stiff trails them by about 10 ms, which is all it takes to even out
/// trackpad samples landing unevenly between display frames (sometimes two in
/// one frame, then none in the next) without the strip feeling any looser.
/// Softer (20 ms) halves the strip's own judder but felt juddery in use, and
/// made no difference to how regularly windows moved on screen.
const FOLLOW_STIFFNESS: f64 = 40_000.0;

/// How the strip eases into a column it snaps to (`auto_center`), and catches
/// up with fingers that rested before lifting.
const SETTLE_STIFFNESS: f64 = 300.0;

/// Friction a coasting strip feels besides the configured deceleration, in
/// points per second squared. Deceleration alone slows the strip in
/// proportion to its speed, so it would creep on for over a second; this
/// brings it to a gentle stop about where the old cut-off at 5 points a frame
/// used to stop it dead.
const STOPPING_FRICTION: f64 = 3000.0;

/// Largest integration step: a spring as stiff as [`FOLLOW_STIFFNESS`] goes
/// unstable with bigger ones, so a frame is stepped in several.
const MAX_SPRING_SUBSTEP_SECS: f64 = 1.0 / 1000.0;

/// Close enough to the target to stop there. Windows move in whole points, so
/// the last point of an ease-out would otherwise creep in over several
/// frames, which looks like a stutter.
const SETTLED_DISTANCE: f64 = 1.0;
const SETTLED_SPEED: f64 = 20.0;

/// How far back a release looks to measure how fast the fingers were moving.
///
/// Measured over a window rather than per frame, because frame timing says
/// nothing about finger speed: frames come as fast as events wake the loop,
/// sometimes well under a millisecond apart, and one trackpad sample divided
/// by such a frame reads as a burst of speed. The window spans about six
/// samples, and is short enough that pausing before lifting leaves nothing to
/// coast on. Fingers are still speeding up as they flick, so a longer window
/// reads them slower than the strip is moving: at 80 ms the strip stepped down
/// to about 86% of its speed as it started to coast, at 50 ms it carries on.
const RELEASE_VELOCITY_WINDOW: Duration = Duration::from_millis(50);

/// Finger travel per frame over the last [`RELEASE_VELOCITY_WINDOW`], for the
/// speed a swipe is released at.
#[derive(Default)]
pub(super) struct SwipeSamples(VecDeque<(Duration, f64)>);

impl SwipeSamples {
    fn clear(&mut self) {
        self.0.clear();
    }

    fn push(&mut self, at: Duration, delta: f64) {
        self.0.push_back((at, delta));
        self.trim(at);
    }

    fn trim(&mut self, now: Duration) {
        while self
            .0
            .front()
            .is_some_and(|(at, _)| now.saturating_sub(*at) > RELEASE_VELOCITY_WINDOW)
        {
            self.0.pop_front();
        }
    }

    /// Viewport fractions per second over the window ending at `now`. The
    /// first sample only marks where the window starts: its travel happened
    /// before it.
    fn velocity(&mut self, now: Duration) -> f64 {
        self.trim(now);
        let (Some((first, _)), Some((last, _))) = (self.0.front(), self.0.back()) else {
            return 0.0;
        };
        let span = last.saturating_sub(*first).as_secs_f64();
        if span <= 0.0 {
            return 0.0;
        }
        self.0.iter().skip(1).map(|(_, delta)| delta).sum::<f64>() / span
    }
}

/// The on-screen strip, its origin, and the scroll state being applied to it.
type ScrollingStrip<'w, 's> = Single<
    'w,
    's,
    (
        &'static LayoutStrip,
        &'static mut Position,
        &'static mut Scrolling,
    ),
    (With<ActiveWorkspaceMarker>, Without<Window>),
>;

impl Plugin for ScrollEventsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<PageGestureState>();
        app.add_message::<PageFocusRequest>();
        let mission_control_inactive = |mission_control: Option<Res<MissionControlActive>>| {
            mission_control.is_none_or(|active| !active.0)
        };

        app.add_systems(
            PreUpdate,
            paging_gesture
                .in_set(PreUpdateSet::Demux)
                .after(super::systems::demux_input_events)
                .run_if(mission_control_inactive)
                .run_if(paging_enabled)
                .run_if(on_message::<InputEvent>.or_else(paging_active)),
        );

        // Only the two gesture systems are gated on an input event. The rest of
        // the chain (snap, spring) must keep running after the fingers stop
        // sending events, since that's when the strip coasts.
        app.add_systems(
            Update,
            (
                vertical_swipe_gesture
                    .run_if(mission_control_inactive)
                    .run_if(on_message::<InputEvent>),
                (
                    swipe_gesture
                        .run_if(mission_control_inactive)
                        .run_if(on_message::<InputEvent>),
                    snap_released_swipe,
                    step_strip,
                    apply_scrolling_constraints,
                    swiping_timeout,
                )
                    .chain(),
            )
                .in_set(UpdateSet::Input),
        );
    }
}

fn paging_gesture(
    mut messages: MessageReader<InputEvent>,
    active_workspace: Single<Entity, With<ActiveWorkspaceMarker>>,
    config: Res<Config>,
    time: Res<Time>,
    mut state: ResMut<PageGestureState>,
    mut events: MessageWriter<PageFocusRequest>,
    mut commands: Commands,
) {
    let current_config = config.swipe_paging_config();
    if state.config.as_ref() != Some(&current_config) {
        state.reset();
        state.config = Some(current_config.clone());
    }
    if !current_config.0 {
        return;
    }

    if state
        .last_event
        .is_some_and(|last| time.elapsed().abs_diff(last) > PAGE_GESTURE_TIMEOUT)
    {
        state.accumulated_cm = 0.0;
        state.last_event = None;
        state.active = false;
    }

    for InputEvent(event) in messages.read() {
        match event {
            Event::TouchpadDown => {
                state.reset();
                state.active = true;
            }
            Event::TouchpadUp => {
                state.accumulated_cm = 0.0;
                state.last_event = None;
                state.active = false;
            }
            Event::Swipe {
                distance_cm,
                fingers,
                ..
            } if Some(*fingers) == current_config.1 => {
                state.last_event = Some(time.elapsed());
                state.active = true;
                if !distance_cm.is_finite() {
                    continue;
                }
                state.accumulated_cm += *distance_cm;
                if !state.accumulated_cm.is_finite() {
                    state.accumulated_cm = 0.0;
                    continue;
                }
                commands.entity(*active_workspace).try_remove::<Scrolling>();
                state.earn_steps(current_config.3, current_config.2.clone());
            }
            Event::Swipe { .. } => state.reset(),
            _ => {}
        }
    }

    if state.in_flight.is_none()
        && let Some(direction) = state.next_step()
    {
        state.in_flight = Some(PageInFlight::Dispatched);
        events.write(PageFocusRequest {
            direction,
            generation: state.generation,
        });
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    mut active_workspace: Single<
        (Entity, &Position, Option<&mut Scrolling>),
        With<ActiveWorkspaceMarker>,
    >,
    time: Res<Time>,
    config: Res<Config>,
    mut samples: Local<SwipeSamples>,
    mut commands: Commands,
) {
    let swipe_sensitivity = config.swipe_sensitivity();
    let mut total_delta = 0.0;
    let mut gesture_delta = 0.0;
    let mut touchpad_down = false;
    let mut touchpad_up = false;
    let mut has_scroll_event = false;
    let mut has_gesture_event = false;

    // Normalization: Touchpad deltas are typically small fractions.
    // Scroll wheel deltas can be larger. We scale it down slightly
    // to match the "feel" of a finger swipe.
    const SCROLL_SCALE_UPPER: f64 = 0.15;
    const SCROLL_SCALE_LOWER: f64 = 0.005;
    const SCROLL_FULL_RANGE: f64 = 2.0;
    let scroll_scale = SCROLL_SCALE_LOWER
        + ((SCROLL_SCALE_UPPER - SCROLL_SCALE_LOWER) / SCROLL_FULL_RANGE) * swipe_sensitivity;

    for InputEvent(event) in messages.read() {
        match event {
            Event::TouchpadDown => {
                touchpad_down = true;
                total_delta = 0.0;
            }
            Event::TouchpadUp => touchpad_up = true,
            Event::Scroll { delta } => {
                total_delta += *delta * scroll_scale;
                has_scroll_event = true;
            }
            Event::Swipe { delta, fingers, .. }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers)
                    && !config.swipe_gesture_paging() =>
            {
                total_delta += delta;
                gesture_delta += delta;
                has_scroll_event = true;
                has_gesture_event = true;
            }
            _ => (),
        }
    }

    if !touchpad_down && !touchpad_up && !has_scroll_event {
        return;
    }

    let now = time.elapsed();
    if touchpad_down {
        samples.clear();
    }
    if has_gesture_event {
        samples.push(now, gesture_delta);
    }

    let (entity, position, scrolling) = &mut *active_workspace;

    // The user is driving the strip by hand now, so an earlier deliberate
    // placement (center, snap) no longer describes where they want it.
    if let Ok(mut entity_commands) = commands.get_entity(*entity) {
        entity_commands.try_remove::<ManualStripOffset>();
    }

    let viewport_width = f64::from(active_display.bounds().width());
    let direction_modifier = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => -1.0,
        SwipeGestureDirection::Reversed => 1.0,
    };

    // Fingers landing catch the strip where it is.
    if touchpad_down && let Some(scrolling) = scrolling.as_mut() {
        scrolling.velocity = 0.0;
        scrolling.target = scrolling.position;
        scrolling.is_user_swiping = true;
        scrolling.motion = StripMotion::Follow;
        scrolling.snap_pending = false;
        scrolling.last_event = now;
    }

    // While the fingers are down they move the target, and the strip follows
    // it closely (see `step_strip_spring`).
    if has_scroll_event {
        let travel = total_delta * viewport_width * direction_modifier * swipe_sensitivity;
        if let Some(scrolling) = scrolling.as_mut() {
            scrolling.is_user_swiping = true;
            scrolling.motion = StripMotion::Follow;
            scrolling.snap_pending = false;
            scrolling.last_event = now;
            scrolling.target += travel;
        } else if let Ok(mut entity_commands) = commands.get_entity(*entity) {
            let mut scrolling = Scrolling::at(f64::from(position.0.x), now);
            scrolling.is_user_swiping = true;
            scrolling.target += travel;
            entity_commands.try_insert(scrolling);
        }
    }

    // Lifting the fingers lets the strip coast at the speed they were moving.
    // Native modifier-scroll events bring their own macOS momentum, so only a
    // multi-finger swipe leaves samples to coast on.
    if touchpad_up {
        if let Some(scrolling) = scrolling.as_mut() {
            scrolling.velocity =
                samples.velocity(now) * swipe_sensitivity * viewport_width * direction_modifier;
            scrolling.is_user_swiping = false;
            scrolling.motion = StripMotion::Coast;
            scrolling.snap_pending = true;
        }
        samples.clear();
    }
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn swiping_timeout(
    strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    time: Res<Time>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    const FINGER_LIFT_THRESHOLD: Duration = Duration::from_millis(50);

    for (entity, mut scroll) in strips {
        if time.elapsed().abs_diff(scroll.last_event) > FINGER_LIFT_THRESHOLD {
            // Resting fingers, a finished modifier-scroll, or a release that
            // never arrived: nothing to coast on, so the strip settles where
            // the fingers left it. A real release has already cleared
            // `is_user_swiping` and sent the strip where it coasts to.
            if scroll.is_user_swiping {
                scroll.is_user_swiping = false;
            }

            if scroll.is_at_rest()
                && let Ok(mut entity_commands) = commands.get_entity(entity)
            {
                entity_commands.try_remove::<Scrolling>();
            }
            if let Some(point) = window_manager.cursor_position() {
                commands.trigger(SendMessageTrigger(Event::MouseMoved {
                    point,
                    modifiers: Modifiers::empty(),
                }));
            }
        }
    }
}

/// With `auto_center`, a released swipe comes to rest centred on the column
/// nearest to where it would coast to, if one is near enough.
#[instrument(level = Level::TRACE, skip_all)]
fn snap_released_swipe(
    mut strip: Single<(&LayoutStrip, &mut Scrolling)>,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
) {
    const SNAP_DISPLAY_RATIO: f64 = 0.45;

    let (strip, ref mut scroll) = *strip;
    if !scroll.snap_pending {
        return;
    }
    scroll.snap_pending = false;
    if !config.auto_center() {
        return;
    }

    let viewport = active_display.actual_bounds(&config);
    let viewport_center = f64::from(viewport.center().x);
    let snap_threshold = SNAP_DISPLAY_RATIO * f64::from(viewport.width());
    let coasting_to = if scroll.motion == StripMotion::Coast {
        scroll.position + coast_distance(scroll.velocity, config.swipe_deceleration())
    } else {
        scroll.target
    };
    let centred = strip
        .all_columns()
        .into_iter()
        .filter_map(|entity| {
            let position = windows.layout_position(entity)?.0.x;
            let width = windows
                .moving_frame(entity)
                .map_or(0, |frame| frame.width());
            Some(viewport_center - f64::from(position) - f64::from(width) / 2.0)
        })
        .min_by(|a, b| (coasting_to - a).abs().total_cmp(&(coasting_to - b).abs()));
    if let Some(centred) = centred
        && (coasting_to - centred).abs() < snap_threshold
    {
        scroll.target = centred;
        scroll.motion = StripMotion::Snap;
    }
}

/// How far a strip coasting at `velocity` goes before it stops, slowing by
/// `deceleration` and [`STOPPING_FRICTION`] (`dv/dt = -kv - a`).
fn coast_distance(velocity: f64, deceleration: f64) -> f64 {
    let (speed, k, a) = (velocity.abs(), deceleration, STOPPING_FRICTION);
    velocity.signum() * (speed - a / k * (1.0 + k * speed / a).ln()) / k
}

/// Moves the strip once per display frame (see `frame_step`): after a flick
/// it coasts until friction stops it, and otherwise it follows its target.
#[instrument(level = Level::TRACE, skip_all)]
fn step_strip(
    mut strips: Populated<&mut Scrolling, With<LayoutStrip>>,
    frame_step: Res<FrameStep>,
    config: Res<Config>,
) {
    let Some(dt) = frame_step.dt() else {
        return;
    };
    let dt = dt.min(MAX_FRAME_STEP_SECS);
    for mut scroll in &mut strips {
        if scroll.is_at_rest() {
            continue;
        }
        if scroll.motion == StripMotion::Coast {
            coast(&mut scroll, dt, config.swipe_deceleration());
        } else {
            follow(&mut scroll, dt);
        }
    }
}

/// Coasts the strip for `dt`, solving `dv/dt = -kv - a` exactly over the step,
/// so the motion doesn't depend on how long frames take.
fn coast(scroll: &mut Scrolling, dt: f64, deceleration: f64) {
    let (speed, k) = (scroll.velocity.abs(), deceleration);
    let ratio = STOPPING_FRICTION / k;
    let decay = (-k * dt).exp();
    let new_speed = (speed + ratio) * decay - ratio;
    let travel = if new_speed > 0.0 {
        (speed + ratio) * (1.0 - decay) / k - ratio * dt
    } else {
        coast_distance(speed, k)
    };
    scroll.position += scroll.velocity.signum() * travel;
    scroll.target = scroll.position;
    if new_speed > 0.0 {
        scroll.velocity = scroll.velocity.signum() * new_speed;
    } else {
        scroll.velocity = 0.0;
        scroll.motion = StripMotion::Follow;
    }
}

/// Moves the strip toward its target as a critically damped spring, which
/// never overshoots and keeps the strip's speed continuous when the target
/// moves: stiff behind the fingers, soft easing into a column.
fn follow(scroll: &mut Scrolling, dt: f64) {
    let stiffness = if scroll.motion == StripMotion::Snap {
        SETTLE_STIFFNESS
    } else {
        FOLLOW_STIFFNESS
    };
    let damping = 2.0 * stiffness.sqrt();
    let steps = (dt / MAX_SPRING_SUBSTEP_SECS).ceil().max(1.0);
    let h = dt / steps;
    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "at most a few dozen substeps"
    )]
    for _ in 0..steps as usize {
        let accel = stiffness * (scroll.target - scroll.position) - damping * scroll.velocity;
        scroll.velocity += accel * h;
        scroll.position += scroll.velocity * h;
    }
    if (scroll.target - scroll.position).abs() < SETTLED_DISTANCE
        && scroll.velocity.abs() < SETTLED_SPEED
    {
        scroll.position = scroll.target;
        scroll.velocity = 0.0;
        scroll.motion = StripMotion::Follow;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_scrolling_constraints(
    mut strip: ScrollingStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
) {
    let viewport = active_display.actual_bounds(&config);
    let (strip, ref mut position, ref mut scroll) = *strip;

    let get_window_frame = |entity| windows.moving_frame(entity);
    let clamp = |offset: f64| {
        clamp_viewport_offset(
            round_px(offset),
            strip,
            &windows,
            &get_window_frame,
            &viewport,
            &config,
        )
    };

    // Head somewhere the strip can stop, so it eases into the end of the strip
    // rather than running into it.
    if let Some(target) = clamp(scroll.target)
        && target != round_px(scroll.target)
    {
        scroll.target = f64::from(target);
    }

    let Some(clamped) = clamp(scroll.position) else {
        scroll.velocity = 0.0;
        scroll.target = scroll.position;
        return;
    };
    // Only the clamp touches the spring's own position: rounding it to whole
    // points every frame would stall a slow ease short of each next point.
    if clamped != round_px(scroll.position) {
        scroll.position = f64::from(clamped);
        scroll.velocity = 0.0;
    }
    if position.x != clamped {
        position.x = clamped;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn clamp_viewport_offset<W>(
    current_offset: i32,
    layout_strip: &LayoutStrip,
    windows: &Windows,
    get_window_frame: &W,
    viewport: &IRect,
    config: &Config,
) -> Option<i32>
where
    W: Fn(Entity) -> Option<IRect>,
{
    let total_strip_width = layout_strip
        .last()
        .ok()
        .and_then(|column| column.top())
        .and_then(|entity| {
            windows
                .layout_position(entity)
                .zip(get_window_frame(entity))
        })
        .map(|(position, frame)| position.x + frame.width())?;

    let continuous_swipe = config.continuous_swipe();
    let strip_position = |column: Result<Column>| {
        column
            .ok()
            .and_then(|column| column.top())
            .and_then(|entity| windows.layout_position(entity))
            .map(|position| position.0.x)
    };

    let left_snap = strip_position(layout_strip.last());
    // NOTE: this snaps to the second window on purpose.
    // For a single colum workspace this will return None
    let right_snap = strip_position(layout_strip.get(1));

    Some(
        if continuous_swipe && let Some((left_snap, right_snap)) = left_snap.zip(right_snap) {
            // Allow to scroll away until the last or first window snaps.
            current_offset.clamp(viewport.min.x - left_snap, viewport.max.x - right_snap)
        } else if viewport.width() < total_strip_width {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.max.x - total_strip_width, viewport.min.x)
        } else {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.min.x, viewport.max.x - total_strip_width)
        },
    )
}

#[derive(Default)]
struct VerticalGestureState {
    accumulated: f64,
    last_event: Option<Instant>,
    fired: bool,
}

#[instrument(level = Level::TRACE, skip_all)]
fn vertical_swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
    mut state: Local<VerticalGestureState>,
) {
    const GESTURE_TIMEOUT: Duration = Duration::from_millis(150);

    if active_display.fullscreen().is_some() {
        return;
    }

    // Reset state when the gesture times out (fingers lifted).
    if let Some(last) = state.last_event
        && last.elapsed() > GESTURE_TIMEOUT
    {
        state.accumulated = 0.0;
        state.fired = false;
    }

    for InputEvent(event) in messages.read() {
        match event {
            Event::VerticalScrollTick { delta } => {
                switch_virtual_workspace(*delta, &config, &mut commands);
            }
            Event::VerticalSwipe { delta, fingers }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers) =>
            {
                state.last_event = Some(Instant::now());

                if !state.fired {
                    state.accumulated += delta;
                }
            }
            _ => {}
        }
    }

    // Threshold needs to be high enough that incidental vertical movement
    // during horizontal swipes doesn't trigger a workspace switch.
    let threshold = 0.15 / config.swipe_sensitivity();
    if state.accumulated.abs() >= threshold {
        switch_virtual_workspace(state.accumulated, &config, &mut commands);
        state.accumulated = 0.0;
        state.fired = true;
    }
}

fn switch_virtual_workspace(delta: f64, config: &Config, commands: &mut Commands) {
    let physical_finger_direction = if delta > 0.0 {
        Direction::South
    } else {
        Direction::North
    };
    let direction = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => physical_finger_direction.reverse(),
        SwipeGestureDirection::Reversed => physical_finger_direction,
    };
    commands.trigger(SendMessageTrigger(Event::Command {
        command: Command::Window(Operation::Virtual(direction)),
    }));
}
