THIRD EYE MONITOR (Windows)
===========================

Watches your Third Eye trades 24x7 and sends alerts to your iPhone, even when the app is closed:
entry zone reached, stop-loss hit or close, each take-profit, the plan's time limit, sharp moves
against you, and a 09:00 / 21:00 summary.

SETUP (once)
1. Make a folder C:\ThirdEye and put thirdeye-monitor.exe in it.
2. Put your Apple key file AuthKey_XXXXXXXXXX.p8 in the same folder (see the guide).
3. Install Tailscale on this PC and on your iPhone, signed in with the same account.
4. Start menu -> type "cmd" -> right-click Command Prompt -> Run as administrator, then:
       cd C:\ThirdEye
       thirdeye-monitor install
   It shows your PC address and a 6-digit pairing code.
5. iPhone: Third Eye -> Settings -> Alerts -> enter the address and code -> Connect -> Send test alert.

If Windows SmartScreen says "Windows protected your PC": click "More info" -> "Run anyway"
(the program is not code-signed; it is built from the public source on GitHub).

OTHER COMMANDS (in C:\ThirdEye)
  thirdeye-monitor status      what it watches, last prices, recent alerts
  thirdeye-monitor pair        a new pairing code
  thirdeye-monitor uninstall   remove the background task

Full step-by-step guide: https://github.com/deven86/thirdeye/blob/main/docs/ALERTS.md
