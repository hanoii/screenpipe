// screenpipe — AI that knows everything you've seen, said, or heard
// https://screenpipe.com

//! Personal `custom` branch switch: run screenpipe as a local-only tool.
//!
//! When enabled, the app never asks for a screenpipe account, never gates
//! recording or the local server behind a plan, and never restricts history
//! access to the free-tier 24-hour window. Every hook in the codebase reads
//! this single constant so a rebase onto upstream only has to keep a handful
//! of one-line call sites alive.

pub(crate) const LOCAL_ONLY: bool = true;
