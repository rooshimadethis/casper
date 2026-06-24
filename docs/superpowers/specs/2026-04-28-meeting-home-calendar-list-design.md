# Meeting Window: Today's Calendar List + currentMeeting() Hardening

## Problem

Two related issues:

1. The "new tab" landing view in the meeting window only offers "New Quick Note" and "Import from Granola." When Google Calendar is connected, the user has to manually create a meeting and rely on `populateFromCalendar()` matching the right event by time. There's no quick way to see today's calendar from inside the app and pick a meeting to record.
2. `GoogleCalendarService.currentMeeting()` returns the first event in the ±5 min window without checking that "now" is inside the event, without filtering all-day events, and without filtering declined events. This silently mis-names meetings (e.g., picks an all-day "PTO Mon" when the user is actually in standup).

## Goal

Add a "Today" list to the new-tab landing view that shows the day's calendar events with a Start button on each, and harden `currentMeeting()` so it picks the right event.

## Approach

### 1. Extend `GoogleCalendarService`

Add `eventsForToday() async -> [CalendarEvent]`:
- Time window: `[startOfDay, endOfDay]` in the local timezone.
- Reuse the existing parser; extract a shared helper that parses a JSON event item into `CalendarEvent`.
- Return events ordered by startTime (Google already does this server-side via `orderBy=startTime`).
- Skip events the user declined (`attendees[selfEmail].responseStatus == "declined"`).
- Include all-day events but mark them so the UI can render them separately (no Start button).

Extend `CalendarEvent`:
```swift
struct CalendarEvent {
    let title: String
    let startTime: String        // existing — ISO string for compat
    let startDate: Date?         // new — parsed
    let endDate: Date?           // new
    let isAllDay: Bool           // new
    let attendees: [String]
    let attendeeCount: Int       // new — total before email-prefix fallback
    let organizer: String?
    let meetLink: String?
}
```

### 2. Harden `currentMeeting()`

Apply the following filters in order:
1. Skip all-day events (`isAllDay == true`).
2. Skip events where `responseStatus == "declined"`.
3. Require `startDate ≤ now ≤ endDate` (with a 2-minute grace at start so people who hit record a hair early still match).
4. Among remaining candidates, prefer the one whose `meetLink` host matches a running meeting app (Zoom → `zoom.us`, Meet → `meet.google.com`, Teams → `teams.microsoft.com`). Tiebreak: most-recently-started.

This logic shares the parser with `eventsForToday`; keep it in one place.

### 3. UI in `newTabView`

Below the existing buttons, render:

```
────────── Today ──────────
[All day: PTO Monday]   (rendered as a header chip, no action)
9:00 AM    Standup                4 people     [▶ Start]
10:30 AM   1:1 with Lara          1 person     [▶ Start]
2:00 PM    Design review          8 people     [▶ Start]
```

- Empty state (no events today): hide the whole section.
- Disconnected calendar: hide the whole section. Do not nag.
- Each event is a row in a VStack inside a ScrollView (capped maxHeight ~280pt with internal scroll).
- Start button calls `state.onStartRecording?(event.title, nil)` — existing `populateFromCalendar` then re-fetches and fills attendees. No new wiring.
- All-day events render as a header pill with title only, no button.
- Declined events not shown.

### 4. Loading

- Load on `newTabView.onAppear` via `Task`.
- Refresh on `NSApplication.didBecomeActiveNotification`.
- Refresh after a recording stops (subscribe to a notification, or re-trigger from the existing stop path).
- 60-second client-side cache so successive renders don't hammer the API.

## Files

| File | Change |
|---|---|
| `Casper/Calendar/GoogleCalendarService.swift` | Add `eventsForToday()`; extract shared item parser; extend `CalendarEvent` with `startDate`, `endDate`, `isAllDay`, `attendeeCount`; harden `currentMeeting()` |
| `Casper/UI/MeetingTranscriptWindow.swift` | Add `todayCalendarSection` to `newTabView`; load today's events; refresh on focus and after stop |

## Out of scope

- Multi-calendar support (primary calendar only for v1).
- Open-existing-recording-on-click (clicking Start always starts a fresh recording — even if a transcript already exists for this event today).
- Future meeting countdowns / "next up" banners.
- Auto-arming detection for upcoming events.

## Risks

- **Conferencing-link host matching is heuristic.** If the user is in a Zoom but their calendar event has a generic `htmlLink` instead of `hangoutLink`, we won't match it. Acceptable for v1 — falls back to most-recently-started.
- **Time zone correctness.** Parsing `dateTime` strings with `ISO8601DateFormatter` and comparing against `Date()` should be timezone-safe; need to verify with an event in a non-local timezone.
- **API quota.** With the 60-second cache, normal use stays well within Google's free quota.
