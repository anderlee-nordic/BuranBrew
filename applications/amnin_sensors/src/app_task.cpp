/*
 * Copyright (c) 2021 Nordic Semiconductor ASA
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include "app_task.h"

#include "app/matter_init.h"
#include "app/task_executor.h"
#include "board/board.h"
#include "lib/core/CHIPError.h"
#include "lib/support/CodeUtils.h"

#include <app-common/zap-generated/attributes/Accessors.h>
#include <app/server/Server.h>
#include <setup_payload/OnboardingCodesUtil.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <cstdlib>

extern "C" {
#include "ble_observer/observer.h"
#include "sensors/ambient.h"
}

LOG_MODULE_DECLARE(app, CONFIG_CHIP_APP_LOG_LEVEL);

using namespace ::chip;
using namespace ::chip::app;
using namespace ::chip::app::Clusters;
using namespace ::chip::DeviceLayer;

/* EP3 reuses the standard RelativeHumidityMeasurement cluster to carry the
 * Tilt's specific gravity, which holds SG x1000 (e.g. 1012 -> SG 1.012). */
namespace {
constexpr EndpointId kAmbientEndpoint  = 1; /* ambient BME680 temperature */
constexpr EndpointId kInternalEndpoint = 2; /* Tilt brew (internal) temperature */
constexpr EndpointId kGravityEndpoint  = 3; /* Tilt specific gravity (SG x1000) */
constexpr uint32_t   kReportPeriodMs   = 60 * 1000; /* 60 seconds */

k_timer sReportTimer;

bool IsCommissioned()
{
	return Server::GetInstance().GetFabricTable().FabricCount() > 0;
}

/* Matter thread. Writes null if no new sample received */
void ReportTiltWork(intptr_t)
{
	int16_t  tilt_temp_raw = 0;
	uint16_t gravity_raw = 0;
	if (observer_get_tilt(&tilt_temp_raw, &gravity_raw)) {
		TemperatureMeasurement::Attributes::MeasuredValue::Set(kInternalEndpoint, tilt_temp_raw);
		RelativeHumidityMeasurement::Attributes::MeasuredValue::Set(kGravityEndpoint, gravity_raw);
		LOG_DBG("internal = %d.%02d C (EP2)  SG=%u.%03u (EP3)",
			tilt_temp_raw / 100, abs(tilt_temp_raw % 100), gravity_raw / 1000, gravity_raw % 1000);
	} else {
		TemperatureMeasurement::Attributes::MeasuredValue::SetNull(kInternalEndpoint);
		RelativeHumidityMeasurement::Attributes::MeasuredValue::SetNull(kGravityEndpoint);
		LOG_DBG("no fresh Tilt sample (EP2 & EP3 -> null)");
	}
}

/* Callback function for the BLE observer to invoke from the Zephyr system workqueue
 * after a scan burst captures a sample.*/
void TiltSampleReady(void)
{
	PlatformMgr().ScheduleWork(ReportTiltWork, 0);
}

/* BLE arbitration between Tilt scan bursts and CHIPoBLE advertising.
 *
 * Starting CHIPoBLE advertising rotates the BLE random address, which the
 * controller rejects while a scan is active.
 * Policy:
 *   Matter advertising active -> Tilt scanning disabled
 *   Not commissioned -> Tilt scanning disabled
 *   Commissioned and not advertising -> Tilt scanning enabled */
void AppBleObserverPolicy(const ChipDeviceEvent *event, intptr_t)
{
	switch (event->Type) {
	case DeviceEventType::kCommissioningComplete:
		observer_enable(true);
		break;
	case DeviceEventType::kCHIPoBLEAdvertisingChange:
		if (event->CHIPoBLEAdvertisingChange.Result == kActivity_Started) {
			observer_enable(false);
		} else {
			observer_enable(IsCommissioned());
		}
		break;
	default:
		break;
	}
}

/* Matter thread, scheduled once right after StartServer(). The fabric table
 * is not valid until the server is up. */
void ApplyInitialObserverGate(intptr_t)
{
	bool commissioned = IsCommissioned();
	observer_enable(commissioned);
	if (!commissioned) {
		LOG_INF("Not commissioned: Tilt bursts deferred until commissioning completes");
	}
}
} /* namespace */

/* Performs the periodic reporting operation in Matter context.
 * Write null if no new sample received */
void AppTask::ReportWork(intptr_t)
{
	int16_t ambient_temp_raw = 0;
	if (ambient_read_centi_c(&ambient_temp_raw) == 0) {
		TemperatureMeasurement::Attributes::MeasuredValue::Set(kAmbientEndpoint, ambient_temp_raw);
		LOG_DBG("ambient  = %d.%02d C (EP1)", ambient_temp_raw / 100, abs(ambient_temp_raw % 100));
	} else {
		TemperatureMeasurement::Attributes::MeasuredValue::SetNull(kAmbientEndpoint);
		LOG_WRN("ambient read failed (EP1 -> null)");
	}

	/* Refresh existing Tilt state */
	ReportTiltWork(0);
	/* The observer starts BLE scan.
	 * A fresh sample normally arrives within ~2 seconds. */
	observer_trigger();
}

/* Timer ISR context */
void AppTask::ReportTimerHandler(k_timer *)
{
	PlatformMgr().ScheduleWork(ReportWork, 0);
}

CHIP_ERROR AppTask::Init()
{
	/* Initialize Matter stack (server, Thread, BLE, factory data, ...). */
	ReturnErrorOnFailure(Nrf::Matter::PrepareServer());

	/* LED and buttons */
	if (!Nrf::GetBoard().Init()) {
		LOG_ERR("User interface initialization failed.");
		return CHIP_ERROR_INCORRECT_STATE;
	}

	ReturnErrorOnFailure(Nrf::Matter::RegisterEventHandler(Nrf::Board::DefaultMatterEventHandler, 0));
	ReturnErrorOnFailure(Nrf::Matter::RegisterEventHandler(AppBleObserverPolicy, 0));

	/* The ambient sensor and BLE observer are initialized before the Matter server starts. */
	ambient_init();
	observer_init(TiltSampleReady);

	ReturnErrorOnFailure(Nrf::Matter::StartServer());

	/* Server is up: fabric table is valid, attribute storage is live. */
	PlatformMgr().ScheduleWork(ApplyInitialObserverGate, 0);

	/* Periodic reporting: first tick after 2 s, then every kReportPeriodMs. */
	k_timer_init(&sReportTimer, &AppTask::ReportTimerHandler, nullptr);
	k_timer_start(&sReportTimer, K_SECONDS(2), K_MSEC(kReportPeriodMs));

	return CHIP_NO_ERROR;
}

CHIP_ERROR AppTask::StartApp()
{
	ReturnErrorOnFailure(Init());

	while (true) {
		Nrf::DispatchNextTask();
	}

	return CHIP_NO_ERROR;
}
