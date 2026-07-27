package wtf.openstrap.openstrap_edge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the app process alive while backgrounded so the live
 * flutter_blue_plus connection keeps draining the strap. Silent, low-priority, ongoing
 * notification titled "Edge Tracking".
 *
 * STICKY: the service asks the OS to recreate it after a memory-pressure kill
 * (START_STICKY). Recreating the service restarts the process, which re-runs
 * EdgeApplication.onCreate → pre-warms the FlutterEngine → Dart main() detects the
 * headless launch and auto-connects to the paired band (see headless_boot.dart) —
 * so one OS kill no longer means "no sync until the app is reopened". A periodic
 * WorkManager watchdog (KeepAliveWorker) backs this up for the cases START_STICKY
 * doesn't cover (user-swiped task on some OEMs, delayed restarts).
 */
class EdgeTrackingService : Service() {
    companion object {
        private const val CHANNEL_ID = "edge_tracking"
        private const val NOTIF_ID = 4201
        private const val TAG = "EdgeTrackingService"

        /**
         * Intent extra: include FOREGROUND_SERVICE_TYPE_LOCATION in the
         * startForeground() call. Set while a GPS route workout is live so
         * Android keeps delivering location fixes with the screen off; the
         * manifest already declares connectedDevice|location. A STICKY restart
         * re-delivers a null intent → plain connectedDevice mode, which is
         * correct (no route session survives a process kill).
         */
        const val EXTRA_LOCATION = "location"

        /**
         * Sticky "a GPS route session is live in this process" flag.
         *
         * WHY THIS EXISTS: several native callers restart the service WITHOUT
         * going through Dart — CompanionBridge.onDeviceAppeared (fires whenever
         * the band re-enters BLE range, which happens routinely mid-run from
         * arm-swing/body-block dropouts), KeepAliveWorker and BootReceiver.
         * They use [start] below, whose Intent carries no EXTRA_LOCATION, so
         * onStartCommand used to read `false` and re-call startForeground()
         * with CONNECTED_DEVICE only — silently STRIPPING the location type off
         * a live workout. On Android 14+ that ends location delivery the next
         * time the app is backgrounded and the route just stops mid-ride, with
         * no crash and no log.
         *
         * So the extra is now tri-state: present ⇒ authoritative (and latched
         * here), absent ⇒ inherit whatever the live session last asked for.
         * A process kill resets this to false, which is correct — Dart re-arms
         * it via EdgeTracking.start(location: true) when it rehydrates the
         * orphaned workout.
         */
        @Volatile
        @JvmStatic
        var locationSessionActive: Boolean = false
            private set

        /**
         * True while the service is alive IN THIS PROCESS. The KeepAliveWorker runs
         * in the same process, so this is an exact "is my service running" check —
         * after an OS kill the new process starts with false, which is precisely
         * the state the watchdog needs to detect.
         */
        @Volatile
        @JvmStatic
        var running: Boolean = false
            private set

        /** Start the foreground service (idempotent). */
        @JvmStatic
        fun start(context: Context) {
            val intent = Intent(context, EdgeTrackingService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannel()
    }

    override fun onDestroy() {
        running = false
        // The latch is per-process and per-service-lifetime; a fresh service
        // must not inherit a stale "route session live" claim.
        locationSessionActive = false
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notif = buildNotification()
        // Tri-state (see [locationSessionActive]): only an intent that actually
        // carries the extra may change the mode. A bare start() from CDM /
        // KeepAliveWorker / boot inherits the live session's type instead of
        // downgrading it.
        val withLocation = if (intent?.hasExtra(EXTRA_LOCATION) == true) {
            intent.getBooleanExtra(EXTRA_LOCATION, false).also {
                locationSessionActive = it
            }
        } else {
            locationSessionActive
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (withLocation) {
                    // Route workout live: also claim the location FGS type so GPS
                    // fixes keep flowing while the screen is off. The manifest
                    // declares connectedDevice|location and the run starts in the
                    // foreground with while-in-use permission granted.
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                }
                try {
                    startForeground(NOTIF_ID, notif, type)
                } catch (e: Exception) {
                    if (withLocation) {
                        // Location type can be refused (permission revoked mid-run,
                        // FGS-while-in-use restrictions) — fall back to the plain
                        // connectedDevice keep-alive rather than losing the BLE link.
                        Log.w(TAG, "startForeground with location failed, retrying without: $e")
                        startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                    } else {
                        throw e
                    }
                }
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (e: Exception) {
            // Defensive: a background start without an FGS exemption can throw on
            // API 31+. The watchdog/CDM/boot paths all carry exemptions, but never
            // crash the process over a keep-alive notification.
            Log.w(TAG, "startForeground failed: $e")
        }
        // STICKY: recreate after an OS kill so the headless engine reconnects the
        // band without waiting for the user to reopen the app.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Edge Tracking",
                NotificationManager.IMPORTANCE_LOW,
            )
            ch.description = "Keeps your strap syncing in the background"
            ch.setShowBadge(false)
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Edge Tracking")
            .setContentText("Keeping your strap in sync")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
