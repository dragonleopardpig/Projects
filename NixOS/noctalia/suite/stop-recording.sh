if pkill -INT -x wf-recorder; then
  sleep 1
  recording=$(cat /tmp/last_recording_path 2>/dev/null || true)
  notify-send -a "Screen Recorder" -i video-x-generic "Recording stopped" "Saved to: $recording"
else
  notify-send -a "Screen Recorder" -i video-x-generic "No recording is running"
fi
