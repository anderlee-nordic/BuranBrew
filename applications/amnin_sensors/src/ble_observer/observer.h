/* Tilt hydrometer BLE observer burst-scan.
 *
 * The Tilt beacons every ~1.3 s. the app triggers a short 100%-duty burst once per
 * report cycle and the scan stops at the first decoded advert
 * (expected < 2 s, capped at 5 s).
 *
 * The contention with CHIPoBLE is also handled.
 * Starting Matter advertising rotates the BLE random address, which the controller
 * rejects while a scan is active (HCI 0x2005 / status 0x0c). The enable gate keeps
 * bursts off for the whole commissioning window. */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

/* The callback is invoked after a burst captures a fresh sample.
 * Do not call Matter APIs directly from it as it schedules onto the
 * Matter thread via PlatformMgr().ScheduleWork. */
typedef void (*observer_sample_cb_t)(void);

/* One-time init (enables BT if not already up). cb may be NULL. */
void observer_init(observer_sample_cb_t cb);

/* Gate for bursts. Disabling also aborts any active burst.
 * Keep disabled if uncommissioned or CHIPoBLE is advertising */
void observer_enable(bool enable);

/* Start one scan burst. No-op if disabled or a burst is already running. */
void observer_trigger(void);

/* Returns the latest sample only when it exists and is not stale.
 * Otherwise returns false. */
bool observer_get_tilt(int16_t *temp_centi_c, uint16_t *gravity_x1000);

#ifdef __cplusplus
}
#endif
