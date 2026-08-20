# Call Recorder

Call Recorder captures one user-controlled local recording and may associate it with calendar context. Calendar context helps users orient later but never identifies who spoke.

## Language

**Recording interval**:
The actual period from successful audio capture start through capture end. It is distinct from a calendar event's scheduled interval.
_Avoid_: Meeting time, call time

**Meeting association**:
A contextual link between one recording and one calendar event snapshot. It carries the event title, scheduled interval, and attendee names without mapping attendees to transcript speakers.
_Avoid_: Speaker match, participant identification

**Portable recording metadata**:
The descriptive subset kept with a recording outside private app history: its title, recording interval, and meeting association snapshot. It deliberately excludes attendee names and operational recovery state.
_Avoid_: App history, recovery state

**Private app history**:
App-owned workflow and recovery data that is not portable recording metadata. Meeting attendee names remain here.
_Avoid_: Recording metadata

**Automatic association**:
A meeting association chosen when exactly one calendar event is plausible at recording start or one event clearly fits an initially ambiguous recording interval.
_Avoid_: Confirmed meeting

**Manual association**:
A meeting association explicitly selected by the user. It replaces any automatic association without changing transcript speaker labels.
_Avoid_: Corrected speaker match

**Unresolved association**:
A recording for which multiple calendar events remain plausible and the app has deliberately chosen none.
_Avoid_: Failed match, unknown meeting

**Candidate event**:
A calendar event close enough to the recording interval to be offered for automatic or manual association.
_Avoid_: Attendee match
