#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/util.h>
#include <zephyr/logging/log.h>
#include "observer.h"
#include "tilt.h"

LOG_MODULE_REGISTER(observer, LOG_LEVEL_INF);

/* 0x0060 × 0.625 ms = 60 ms */
#define BURST_INTERVAL      BT_GAP_SCAN_FAST_INTERVAL
#define BURST_TIMEOUT       K_SECONDS(5)

/* Freshness = 10 min, stale samples are considered null */
#define SAMPLE_MAX_AGE_MS   (10 * 60 * 1000)

/* -------------------------------------------------------------------------
 * Concurrency model
 *
 * Scan state is owned exclusively by the Zephyr system workqueue
 * and is accessed only by the start, stop, and timeout handlers.
 *
 * Public APIs and the BT RX callback do not modify scan state directly;
 * they only update protected data and submit work. This serializes scan
 * operations and prevents overlapping starts, stale stops, and teardown races.
 *
 * Cross-thread state:
 *   - s_tilt: protected by s_lock
 *   - s_enabled: atomic
 * ------------------------------------------------------------------------- */

static struct {
	int16_t  temp_centi_c;
	uint16_t gravity_x1000;
	int64_t  timestamp_ms;
	bool     valid;
} s_tilt;

static struct k_spinlock s_lock;

static atomic_t s_enabled = ATOMIC_INIT(0);
static observer_sample_cb_t s_sample_cb;

/* Scan state: accessed only by the system workqueue handlers to avoid race condition */
static bool    s_scan_active;
static int64_t s_burst_start_ms;

static void start_work_handler(struct k_work *work);
static void stop_work_handler(struct k_work *work);
static void timeout_work_handler(struct k_work *work);
static void scan_cb(const bt_addr_le_t *addr, int8_t rssi, uint8_t adv_type,
                    struct net_buf_simple *ad);

static K_WORK_DEFINE(s_start_work, start_work_handler);
static K_WORK_DEFINE(s_stop_work, stop_work_handler);
static K_WORK_DELAYABLE_DEFINE(s_timeout_work, timeout_work_handler);

/* Helper function performs scan teardown. */
static void burst_stop(void)
{
	if (!s_scan_active) { /* check if any burst is active */
		return;
	}
	s_scan_active = false;

	/* Cancel the timeout work */
	k_work_cancel_delayable(&s_timeout_work);

	int err = bt_le_scan_stop();
	if (err && err != -EALREADY) {
		LOG_WRN("bt_le_scan_stop failed (%d)", err);
	}

	bool captured;
	k_spinlock_key_t key = k_spin_lock(&s_lock);
	/* Determine whether this burst captured a new sample. */
	captured = s_tilt.valid && (s_tilt.timestamp_ms >= s_burst_start_ms);
	k_spin_unlock(&s_lock, key);

	if (captured && s_sample_cb) {
		/* Call the callback */
		s_sample_cb();
	}
}

static void start_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	/* The trigger was queued (thus enabled -> false) */
	if (!atomic_get(&s_enabled)) {
		return;
	}
	/* Previous burst is still ongoing */
	if (s_scan_active) {
		return;
	}

	struct bt_le_scan_param scan_param = {
		.type     = BT_LE_SCAN_TYPE_PASSIVE,
		.options  = BT_LE_SCAN_OPT_NONE,
		.interval = BURST_INTERVAL,
		.window   = BURST_INTERVAL, /* interval == window -> 100% duty */
	};

	int err = bt_le_scan_start(&scan_param, scan_cb);
	if (err) {
		LOG_WRN("burst start failed (%d)", err);
		return; /* self-heal at the next cycle */
	}

	s_scan_active  = true;
	s_burst_start_ms = k_uptime_get();
	k_work_schedule(&s_timeout_work, BURST_TIMEOUT);
	LOG_DBG("Tilt burst scan started");
}

static void stop_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	burst_stop();
}

static void timeout_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	LOG_DBG("burst timeout");
	burst_stop();
}

/* This function is called for each advertisement data element */
static bool ad_parse_cb(struct bt_data *data, void *user_data)
{
	ARG_UNUSED(user_data);
	if (data->type == BT_DATA_MANUFACTURER_DATA) {
		int16_t  t;
		uint16_t g;
		if (tilt_black_decode(data->data, data->data_len, &t, &g)) {
			k_spinlock_key_t key = k_spin_lock(&s_lock);
			s_tilt.temp_centi_c  = t;
			s_tilt.gravity_x1000 = g;
			s_tilt.timestamp_ms  = k_uptime_get();
			s_tilt.valid         = true;
			k_spin_unlock(&s_lock, key);

			/* if sample captured, end the burst */
			k_work_submit(&s_stop_work);
			return false;
		}
	}
	return true;
}

static void scan_cb(const bt_addr_le_t *addr, int8_t rssi, uint8_t adv_type,
                    struct net_buf_simple *ad)
{
	ARG_UNUSED(addr);
	ARG_UNUSED(rssi);
	ARG_UNUSED(adv_type);
	bt_data_parse(ad, ad_parse_cb, NULL);
}

void observer_init(observer_sample_cb_t cb)
{
	s_sample_cb = cb;

	/* The Matter stack (PrepareServer) initializes BT, therefore EALREADY is expected */
	int err = bt_enable(NULL);
	if (err && err != -EALREADY) {
		LOG_ERR("bt_enable failed (%d)", err);
	} else if (err == 0) {
		LOG_WRN("observer enabled BT before the Matter stack did");
	}
}

void observer_enable(bool enable)
{
	atomic_set(&s_enabled, enable ? 1 : 0);
	if (!enable) {
		/* Safely aborts an active scan through the serialized workqueue. */
		k_work_submit(&s_stop_work);
	}
	LOG_INF("Tilt observer %s", enable ? "enabled" : "disabled");
}

void observer_trigger(void)
{
	if (!atomic_get(&s_enabled)) {
		return;
	}
	k_work_submit(&s_start_work);
}

bool observer_get_tilt(int16_t *temp_centi_c, uint16_t *gravity_x1000)
{
	k_spinlock_key_t key = k_spin_lock(&s_lock);
	bool fresh = s_tilt.valid &&
		     (k_uptime_get() - s_tilt.timestamp_ms) <= SAMPLE_MAX_AGE_MS;
	if (fresh) {
		if (temp_centi_c)  *temp_centi_c = s_tilt.temp_centi_c;
		if (gravity_x1000) *gravity_x1000 = s_tilt.gravity_x1000;
	}
	k_spin_unlock(&s_lock, key);
	return fresh;
}
