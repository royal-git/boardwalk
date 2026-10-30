//! Animation frames in step with the display.
//!
//! While anything animates, a display link sends [`Event::DisplayFrame`] once
//! per refresh of the active display, with the time that frame will be on
//! screen. Animations then move windows once per frame the display really
//! shows, at its own rate (up to 120 Hz with `ProMotion`), and step by the real
//! time between frames, so motion has no beat against the refresh. The link
//! also asks a `ProMotion` display for its full rate, which it otherwise only
//! runs at for content that asks.
//!
//! Display links on `NSScreen` are new in macOS 14; without one the loop keeps
//! time itself, as it always has.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, DefinedClass, MainThreadMarker, define_class, msg_send, sel};
use objc2_app_kit::NSScreen;
use objc2_core_graphics::CGDirectDisplayID;
use objc2_foundation::{NSNumber, NSObject, NSRunLoop, NSRunLoopCommonModes, NSString};
use objc2_quartz_core::{CADisplayLink, CAFrameRateRange};
use tracing::debug;

use crate::events::{Event, EventSender};

pub struct Ivars {
    events: EventSender,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements, and `FrameTicker`
    // does not implement `Drop`.
    #[unsafe(super(NSObject))]
    #[name = "PaneruFrameTicker"]
    #[ivars = Ivars]
    struct FrameTicker;

    impl FrameTicker {
        #[unsafe(method(tick:))]
        fn tick(&self, link: &CADisplayLink) {
            _ = self.ivars().events.send(Event::DisplayFrame {
                at: link.targetTimestamp(),
            });
        }
    }
);

impl FrameTicker {
    fn new(events: EventSender) -> Retained<Self> {
        let this = Self::alloc().set_ivars(Ivars { events });
        unsafe { msg_send![super(this), init] }
    }
}

/// The display link, and the display it follows. Main thread only.
pub(super) struct FrameClock {
    ticker: Retained<FrameTicker>,
    link: Option<(CGDirectDisplayID, Retained<CADisplayLink>)>,
}

impl FrameClock {
    pub(super) fn new(events: EventSender) -> Self {
        Self {
            ticker: FrameTicker::new(events),
            link: None,
        }
    }

    /// Sends frames timed to `display`, or stops sending them. Returns whether
    /// frames are coming: false without a display link (before macOS 14) or
    /// for a display `NSScreen` doesn't know.
    pub(super) fn run(
        &mut self,
        display: Option<CGDirectDisplayID>,
        mtm: MainThreadMarker,
    ) -> bool {
        match (display, &self.link) {
            (None, Some((_, link))) => {
                link.setPaused(true);
                false
            }
            (None, None) => false,
            (Some(id), Some((current, link))) if *current == id => {
                link.setPaused(false);
                true
            }
            (Some(id), _) => {
                if let Some((_, old)) = self.link.take() {
                    old.invalidate();
                }
                self.link = self.make_link(id, mtm).map(|link| (id, link));
                self.link.is_some()
            }
        }
    }

    fn make_link(
        &self,
        display_id: CGDirectDisplayID,
        mtm: MainThreadMarker,
    ) -> Option<Retained<CADisplayLink>> {
        let number_key = NSString::from_str("NSScreenNumber");
        let screen = NSScreen::screens(mtm).into_iter().find(|screen| {
            screen
                .deviceDescription()
                .objectForKey(&number_key)
                .and_then(|value| value.downcast::<NSNumber>().ok())
                .is_some_and(|number| number.unsignedIntValue() == display_id)
        })?;
        let supported: bool = unsafe {
            msg_send![&*screen, respondsToSelector: sel!(displayLinkWithTarget:selector:)]
        };
        if !supported {
            return None;
        }
        let target: &AnyObject = &self.ticker;
        let link = unsafe { screen.displayLinkWithTarget_selector(target, sel!(tick:)) };
        // Ask a ProMotion display for its full rate rather than whatever it idles at.
        #[allow(
            clippy::cast_precision_loss,
            reason = "refresh rates are small integers"
        )]
        let max = screen.maximumFramesPerSecond() as f32;
        link.setPreferredFrameRateRange(CAFrameRateRange {
            minimum: max.min(60.0),
            maximum: max,
            preferred: max,
        });
        unsafe { link.addToRunLoop_forMode(&NSRunLoop::mainRunLoop(), NSRunLoopCommonModes) };
        debug!(display_id, max, "frames follow the display");
        Some(link)
    }
}
