#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/logging/log.h>
#include "ambient.h"

LOG_MODULE_REGISTER(ambient, LOG_LEVEL_INF);

static const struct device *const s_bme = DEVICE_DT_GET_ONE(bosch_bme680);
static bool s_ready;

void ambient_init(void)
{
	s_ready = device_is_ready(s_bme);
	if (!s_ready) {
		LOG_ERR("BME680 not ready; ambient reads will fail (EP1 -> null)");
	}
}

int ambient_read_centi_c(int16_t *out)
{
	if (!s_ready) {
		return -1;
	}
	struct sensor_value t;
	if (sensor_sample_fetch(s_bme) < 0) {
		return -1;
	}
	if (sensor_channel_get(s_bme, SENSOR_CHAN_AMBIENT_TEMP, &t) < 0) {
		return -1;
	}
	/* val1 -> integer part, val2 -> fractional part */
	*out = (int16_t)(t.val1 * 100 + t.val2 / 10000);
	return 0;
}
