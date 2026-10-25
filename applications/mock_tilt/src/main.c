/*
 * Copyright (c) 2018 Henrik Brix Andersen <henrik@brixandersen.dk>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stddef.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/random/random.h>
#include <zephyr/sys/__assert.h>
#include <zephyr/sys/util.h>

LOG_MODULE_REGISTER(app, CONFIG_APP_LOG_LEVEL);

#define IBEACON_DATA_LENGTH 25

struct ibeacon_data {
	uint8_t manufacturer_id[4];
	uint8_t uuid[16];
	uint8_t major[2];
	uint8_t minor[2];
	int8_t rssi;
} __packed;

BUILD_ASSERT(sizeof(struct ibeacon_data) >= IBEACON_DATA_LENGTH);

static struct ibeacon_data ib_data = {
	.manufacturer_id =
		{
			/* Apple */
			0x4c,
			0x00,
			/* iBeacon */
			0x02,
			0x15,
		},
	.uuid =
		{
			/* Tilt Black UUID */
			0xA4,
			0x95,
			0xBB,
			0x30,
			0xC5,
			0xB1,
			0x4B,
			0x44,
			0xB5,
			0x12,
			0x13,
			0x70,
			0xF0,
			0x2D,
			0x74,
			0xDE,

		},
	.major = {0, 0},
	.minor = {0, 0},
	/* Supposed to be calibrated RSSI @ 1m.
	 * This value was just copied as is from the Zephyr ibeacon sample.
	 */
	.rssi = 0xc8,
};

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, BT_LE_AD_NO_BREDR),
	BT_DATA(BT_DATA_MANUFACTURER_DATA, &ib_data, IBEACON_DATA_LENGTH),
};

static const struct gpio_dt_spec buttons[4] = {
	GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios),
	GPIO_DT_SPEC_GET(DT_ALIAS(sw1), gpios),
	GPIO_DT_SPEC_GET(DT_ALIAS(sw2), gpios),
	GPIO_DT_SPEC_GET(DT_ALIAS(sw3), gpios),
};
static struct gpio_callback button_cb[4];

static uint16_t latest_temp_fahrenheit = CONFIG_INITIAL_TEMP_FAHRENHEIT;
static int16_t latest_sg_millis = CONFIG_INITIAL_SG_MILLIS;

static void bt_ready(int err)
{
	if (err) {
		LOG_ERR("Error %d: bluetooth init failed", err);
		return;
	}

	LOG_INF("Bluetooth initialized");

	err = bt_le_adv_start(BT_LE_ADV_NCONN, ad, ARRAY_SIZE(ad), NULL, 0);
	if (err) {
		LOG_ERR("Error %d: advertising failed to start", err);
		return;
	}

	LOG_INF("Started advertising");
}

static void set_big_endian(const uint8_t *in, uint8_t *out, size_t len)
{
	if (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__) {
		for (size_t i = 0; i < len; i++) {
			out[i] = in[len - i - 1];
		}
	} else {
		memcpy(out, in, len);
	}
}

static uint16_t saturating_inc(uint16_t current)
{
	return current < UINT16_MAX ? current + 1 : UINT16_MAX;
}

static uint16_t saturating_dec(uint16_t current)
{
	return current > 0 ? current - 1 : 0;
}

static void handle_button_press(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
	/* Mapped according to the typical Nordic DK button layout:
	 *
	 *   (+)   [ 0 ]  [ 1 ]   (+)
	 *  Temp                  SG
	 *   (-)   [ 2 ]  [ 3 ]   (-)
	 */

	if (dev == buttons[0].port && (pins & BIT(buttons[0].pin))) {
		latest_temp_fahrenheit = saturating_inc(latest_temp_fahrenheit);
		LOG_INF("[+] Temperature => %d F", latest_temp_fahrenheit);
	}
	if (dev == buttons[2].port && (pins & BIT(buttons[2].pin))) {
		latest_temp_fahrenheit = saturating_dec(latest_temp_fahrenheit);
		LOG_INF("[-] Temperature => %d F", latest_temp_fahrenheit);
	}
	if (dev == buttons[1].port && (pins & BIT(buttons[1].pin))) {
		latest_sg_millis = saturating_inc(latest_sg_millis);
		LOG_INF("[+] SG => %d / 1000", latest_sg_millis);
	}
	if (dev == buttons[3].port && (pins & BIT(buttons[3].pin))) {
		latest_sg_millis = saturating_dec(latest_sg_millis);
		LOG_INF("[-] SG => %d / 1000", latest_sg_millis);
	}
}

static void update_ad_measurement(uint16_t new_temp_fahrenheit, int16_t new_sg_millis)
{
	set_big_endian((uint8_t *)&new_temp_fahrenheit, ib_data.major, sizeof(uint16_t));
	set_big_endian((uint8_t *)&new_sg_millis, ib_data.minor, sizeof(int16_t));

	LOG_INF("Temperature: %d F, SG: %d / 1000", new_temp_fahrenheit, new_sg_millis);
}

int main(void)
{
	int err;

	LOG_INF("Starting Mock Tilt sensor");

	update_ad_measurement(latest_temp_fahrenheit, latest_sg_millis);

	for (size_t i = 0; i < ARRAY_SIZE(buttons); i++) {
		__ASSERT_NO_MSG(gpio_is_ready_dt(&buttons[i]));

		err = gpio_pin_configure_dt(&buttons[i], GPIO_INPUT);
		if (err != 0) {
			LOG_ERR("Error %d: failed to configure %s.%d", err, buttons[i].port->name,
				buttons[i].pin);
			continue;
		}

		err = gpio_pin_interrupt_configure_dt(&buttons[i], GPIO_INT_EDGE_TO_ACTIVE);
		if (err != 0) {
			LOG_ERR("Error %d: failed to configure interrupt on %s.%d", err,
				buttons[i].port->name, buttons[i].pin);
			continue;
		}

		gpio_init_callback(&button_cb[i], handle_button_press, BIT(buttons[i].pin));
		gpio_add_callback(buttons[i].port, &button_cb[i]);
	}

	err = bt_enable(bt_ready);
	if (err) {
		LOG_ERR("Error %d: bluetooth init failed", err);
	}

	for (;;) {
		k_msleep(1000);

		/* Add a bit of noise in the measurements */
		update_ad_measurement(latest_temp_fahrenheit ^ (sys_rand16_get() & 0x1),
				      latest_sg_millis ^ (sys_rand16_get() & 0x3));

		err = bt_le_adv_update_data(ad, ARRAY_SIZE(ad), NULL, 0);
		if (err) {
			LOG_ERR("Error %d: Failed to update advertising data\n", err);
		}
	}

	return 0;
}
