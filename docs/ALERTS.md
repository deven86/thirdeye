# Third Eye alerts — setup guide (Windows PC + iPhone)

Your Windows PC watches your trades 24×7 and sends alerts to your iPhone even when Third Eye is closed.
About 20 minutes, once. Do the parts in order.

| Alert | When |
|---|---|
| Entry zone reached | an upcoming trade's price enters its entry zone (again only after it left by ½R) |
| Setup invalidated | price passes the planned stop before you entered |
| **Stop hit** ⛔ | an open trade reaches its stop — *time-sensitive: breaks through Focus* |
| **Close to stop** | within 0.25R of the stop — *time-sensitive* |
| TP1 … TP4 reached | each take-profit, with what to do next (book %, move stop) |
| Time limit / plan expired | the plan's "complete by" date has passed |
| **Sharp move against you** ⚡ | ≥ 1R against you within an hour — *time-sensitive* |
| Opened against you | a gap of ≥ 0.75R after the market was closed |
| Summary | 09:00 and 21:00 (your time): every trade's R or distance to entry |
| Upstox login needed | once a weekday morning if an India trade can't be watched |

Prices are checked every 30 s (scalp/intraday), 5 min (short-term/swing), 30 min (positional) or
1 h (long-term) while that market is open — every minute when a trade is near its stop.

---

## Part A — Apple Developer site (5 min, do this on the PC's browser)

The key file must end up on the PC, so doing this part on the PC is easiest.

1. Open **developer.apple.com/account** → sign in with the Apple ID you use for Third Eye.
2. **Certificates, IDs & Profiles → Identifiers** → click **Third Eye** (`com.jondhale.thirdeye`).
3. In the capabilities list tick **Push Notifications** and **Time Sensitive Notifications**.
   (Ignore "Configure" next to Push Notifications — no certificate is needed.) Click **Save** → **Confirm**.
4. Left menu **Keys** → **+** (blue plus).
   - Key Name: `Third Eye Alerts`
   - Tick **Apple Push Notifications service (APNs)** → **Configure** →
     Environment **Sandbox & Production**, Key Restriction **Team Scoped (All Topics)** → **Save**.
   - **Continue** → **Register** → **Download**.
5. You get a file named like `AuthKey_AB12CD34EF.p8`. **Apple lets you download it only once** —
   keep a backup copy somewhere safe (e.g. a password manager). Never share it.
6. Tell Claude "Apple done". The signing profile is then refreshed and the push-enabled
   TestFlight build (0.9.0) is uploaded.

## Part B — Tailscale (5 min, PC and iPhone)

Tailscale makes a private, encrypted network between your iPhone and your PC. It is free for personal use.

1. **PC:** download from **tailscale.com/download/windows** → install → **Log in** (Google, Microsoft
   or Apple account). The tray icon shows "Connected".
2. **iPhone:** App Store → **Tailscale** → open → log in with the **same** account → allow the VPN
   configuration → switch **Connect** on. Leave it on. (Tailscale → Settings → *VPN On Demand* keeps it
   on automatically.)
3. **Browser:** **login.tailscale.com/admin/dns** →
   - **MagicDNS**: should already say *Enabled* (enable it if not).
   - **HTTPS Certificates**: click **Enable HTTPS**.

## Part C — Install the monitor (5 min, PC)

1. Download **https://github.com/deven86/thirdeye/releases/latest/download/thirdeye-monitor-windows-x64.zip**
2. Create the folder **`C:\ThirdEye`** and unzip into it (you get `thirdeye-monitor.exe` and `README.txt`).
3. Copy your **`AuthKey_….p8`** file from Part A into **`C:\ThirdEye`**.
4. **Start** → type `cmd` → right-click **Command Prompt** → **Run as administrator** → Yes. Then type:
   ```
   cd C:\ThirdEye
   thirdeye-monitor install
   ```
   - If Windows says *"Windows protected your PC"*: **More info → Run anyway** (the program isn't
     code-signed; it is built from this repository's public source by GitHub).
   - If step 3/4 prints a `login.tailscale.com` link: open it, allow HTTPS/Serve for the PC, then run
     `thirdeye-monitor install` again.
   - It finishes with your **PC address** (like `my-pc.tail1234.ts.net`) and a **6-digit pairing code**
     (valid 15 minutes; `thirdeye-monitor pair` makes a new one).
5. **Power:** Settings → System → Power → **Sleep: Never** when plugged in. The monitor also keeps
   Windows awake and restarts itself after reboots and Windows Updates (checked every 5 minutes).
   The screen can still turn off.

## Part D — Connect the app (2 min, iPhone)

Needs Third Eye **0.9.0** from TestFlight (after Part A).

1. Third Eye → **Settings → Alerts (Windows PC)**.
2. Enter the **PC address** and **pairing code** → **Connect** → **Allow** notifications.
3. Tap **Send a test alert** → you should see *"Third Eye · test alert"* within a few seconds.
4. For stop-loss alerts during Focus/Sleep: iPhone **Settings → Notifications → Third Eye →
   Time Sensitive Notifications: On** (and allow Third Eye in your Focus modes if you like).

From now on every trade you track (upcoming or open) is sent to the PC automatically. India trades
need your daily Upstox login in the app; US/forex/gold need the Twelve Data key — both are passed to
the PC automatically.

---

## Checking it

- iPhone: Settings → Alerts shows *online*, what it watches, last prices and recent alerts.
  Home shows a warning if the PC hasn't checked prices for 15 minutes.
- PC (any Command Prompt): `C:\ThirdEye\thirdeye-monitor status`
- Log file: `C:\ProgramData\ThirdEye\monitor.log`

## Troubleshooting

| You see | Do this |
|---|---|
| "Can't reach your PC" | Tailscale **Connect** on, on both the iPhone and the PC; PC awake; run `thirdeye-monitor status` on the PC |
| Push: "no key" | put `AuthKey_….p8` in `C:\ThirdEye` (it is picked up within a minute, then renamed to `.imported`) |
| "This build can't receive push yet" | Part A step 3 wasn't saved, or you're on a build older than 0.9.0 |
| Test alert "not sent: … BadDeviceToken" | delete and reinstall Third Eye from TestFlight, then connect again |
| "Upstox login needed" | open Third Eye → Settings → Market Data → log in to Upstox (daily; tokens end 03:30) |
| Twelve Data "no key" | add the free key in Third Eye → Settings → Market Data |

## Security

- The monitor listens only on the PC itself (127.0.0.1); Tailscale publishes it **only to your own
  devices**, over HTTPS. Nothing is open to the internet.
- The app must pair with a one-time 6-digit code; afterwards it uses a long random token kept in the
  iPhone keychain. "Disconnect this iPhone" revokes it.
- On the PC, the Apple key, Twelve Data key and Upstox token are encrypted with Windows DPAPI.
  After the test alert works you may delete the `AuthKey_….p8.imported` file from `C:\ThirdEye`
  (keep your backup copy).
- It only reads prices. It never places orders.

## Removing it

Administrator Command Prompt: `C:\ThirdEye\thirdeye-monitor uninstall`, then delete `C:\ThirdEye`
and `C:\ProgramData\ThirdEye`.
