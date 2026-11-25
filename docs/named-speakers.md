# Named speakers

Muesli labels remote voices "Speaker 1", "Speaker 2" and so on. Name a speaker once and Muesli
recognizes the same voice in later meetings.

## Using it

1. Open a meeting. The header strip shows "N speakers" next to People.
2. Type a name for a speaker, or pick an existing person, and Save. The transcript lines change to
   "Alex:".
3. Record another meeting with the same person. If the voice matches, the transcript says "Alex".

Speakers, Manage People lists everyone with the number of voiceprints and meetings, with Forget
Voiceprints (keeps the person, drops their voice data) and Delete.

## How matching works

After a meeting is diarized, each remote speaker gets a voice summary (a 256-number vector from
FluidAudio's embedding, averaged over the segments weighted by duration). A speaker needs at least
10 seconds of speech to get one.

A voice matches a person only when:

- cosine similarity to their stored voiceprints is at least 0.65 (the mean of their two best),
- and it beats the next-best person by at least 0.10,
- and no other speaker in the same meeting claims that person with a better score.

Anything else stays "Speaker N". The microphone side is never matched: neither "You" nor the
"Local speaker N" labels that "Identify in-room speakers" gives in-person voices. These thresholds are
starting values and have not been tuned on real meetings, so check the first few matches.

## What is stored

Voiceprint vectors, per-meeting speaker centroids, and speaker profile/voiceprint records live in
your local muesli database only. They are not included in iCloud sync, the CLI, exports, or logs,
and voiceprint vectors are never sent to a model. Deleting a meeting removes its `meeting_speakers`
rows; voiceprints already saved from a meeting stay with the person until you forget them or delete
the person.

In a normal (non-private) meeting, naming or recognizing a speaker writes that name into the
meeting's `raw_transcript`. Once written into `raw_transcript`, those speaker names are part of the
transcript and follow the transcript's normal paths—including iCloud sync, exports, CLI output, Ask
Meetings, and title/summary model requests.

In a private meeting, a recognized or manually assigned speaker name is stored in the local speaker
rows but is not written into `raw_transcript`, and private-meeting rules keep the transcript and
names from leaving for untrusted models, sync, exports, or CLI output.

## Limits

Meetings that are retranscribed or imported have no voice data, so their speakers stay "Speaker N",
and retranscribing clears the speaker rows for that meeting.
