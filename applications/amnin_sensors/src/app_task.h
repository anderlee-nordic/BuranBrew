/*
 * Copyright (c) 2021 Nordic Semiconductor ASA
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#pragma once

#include <platform/CHIPDeviceLayer.h>

struct k_timer;

class AppTask {
public:
	/* singleton */
	static AppTask &Instance()
	{
		static AppTask sAppTask;
		return sAppTask;
	};

	CHIP_ERROR StartApp();

private:
	CHIP_ERROR Init();

	/* Zephyr timer context */
	static void ReportTimerHandler(k_timer *timer);
	/* periodic sensor reporting from the Matter attributes*/
	static void ReportWork(intptr_t arg);
};
