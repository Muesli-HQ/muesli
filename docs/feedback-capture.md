# Scrawl (experimental)

Scrawl records the display under your pointer with microphone narration for local playback. Enable **Settings → General → Experimental → Scrawl**. Grant Screen Recording, Microphone, Accessibility and Input Monitoring in macOS System Settings; a blocked pill names the missing permission and opens its setup action.

Press **Option–Shift–S (⌥⇧S)** and release every key to start. The selected display stays fixed for that capture. Speak while demonstrating the issue, then press the shortcut again or click **Finish** to save. Change the shortcut in **Settings → Shortcuts** using a modifier-plus-letter chord. Clicking **✕** asks **Discard?**; click it again to discard. Closing a window or pressing Escape leaves an established capture running.

Scrawl stops after ten minutes, when the recorded display disconnects or changes geometry, or when the Mac sleeps or locks. Starting a meeting finishes the capture and releases its microphone before meeting audio starts. If device teardown takes longer than eight seconds, the meeting reports that it is still pending; retry after teardown finishes. Finish stops screen collection immediately while already captured narration drains. Dictation, Quill and computer-use commands cannot start while Scrawl owns the microphone; an active meeting or other audio activity also prevents a new capture.

Click **Open** on the Ready pill, choose **Open Scrawl Captures…** from the menu bar, or use **Open Scrawl captures…** in General settings. Select a capture to play it, reveal its bundle with **Show in Finder**, or choose **Delete…** and confirm to remove it and all its files. Saved captures remain accessible after disabling Scrawl.

Recording excludes Muesli's application windows, including its indicator, and captures microphone narration without system audio. Files stay on this Mac and appear under **Scrawl captures** in Local storage. Scrawl currently provides recording and playback; transcription and clipboard summaries are not available yet.

After an interrupted recording, relaunch Muesli to recover playable media. Recovered captures retain completed video fragments and available narration; a partial capture may contain only audio or video. The Scrawl window shows its recovery state and any failures. A damaged narration file does not prevent surviving video from appearing. If saving fails, Open still selects that capture using its recovery journal. Temporary microphone files use separate app-identity directories and are cleaned on normal stop or the next launch of that identity.
