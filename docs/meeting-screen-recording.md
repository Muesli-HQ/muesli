# Explicit meeting screen recording

Start a meeting, choose **Record Screen…**, select a window or entire display from the preview grid, and confirm. Preview images are transient. System utility windows and Muesli's own windows are excluded from the window list.

The optional announcement is a bundled AIFF generated locally with macOS Samantha text-to-speech. NSSound plays it on the Mac's selected output; it is not injected into the remote meeting. Announcement failure displays a warning and does not stop capture.

Each uninterrupted interval is a local MP4 with hardware HEVC (hardware H.264 fallback) and AAC from the existing cleaned microphone/system feeds. Initial settings are 2560 pixels maximum width, 15 fps, nominal 2 Mbps video, and 16 kHz mono AAC at 32 kbps. Screen pause/stop are independent controls. Pausing the meeting also pauses video; resuming does not override an explicit screen pause. Sleep and lock pause capture for privacy.

Ending the meeting saves video automatically. A screen-recorded meeting skips the redundant prompt for retaining separate audio; an explicit never-retain-audio preference remains respected. Video playback below Notes/Transcript does not require a separate audio file. AppKit AVPlayerView provides playback controls, avoiding the observed system _AVKit_SwiftUI metadata crash. Clips play individually; transcript-linked seeking is not implemented.

Media and its SQLite catalog live in the lane's Application Support `visual-memory` directory. They are local only. Deleting or explicitly discarding a meeting removes its video; ordinary completion retains it. Capture requires at least 2 GB free disk space.

Validation includes the native DevB build, isolated store/deletion/pause tests, the synthetic AAC regression check in `scripts/test_meeting_video_encoding.py`, and reopening a real recorded clip with audio and video tracks in DevB.
