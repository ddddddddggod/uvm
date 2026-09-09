/* Copyright 2026 */
/* SPDX-License-Identifier: Apache-2.0 */

/* Includes ------------------------------------------------------------------*/
#include <stdint.h>

#include "irq.h"
#include "sg_fileio.h"

/* Private constants ---------------------------------------------------------*/
enum {
  ednBase = 0x41170000,
  edn_intr_sts = 0x00,
  edn_intr_ena = 0x04,
  edn_intr_test = 0x08,
  edn_alert_test = 0x0c,
  edn_regwen = 0x10,
  edn_ctrl = 0x14,
  edn_boot_ins_cmd = 0x18,		//1.boot mode
  edn_boot_gen_cmd = 0x1c,		//1.boot mode
  edn_sw_cmd_req = 0x20,		//2.fw mode
  edn_sw_cmd_sts = 0x24,		//2.fw mode
  edn_hw_cmd_sts = 0x28,	
  edn_reseed_cmd = 0x2c,		//3.auto mode
  edn_generate_cmd = 0x30,		//3.auto mode
  edn_max_num_reqs_between_reseeds = 0x34,
  edn_recov_alert_sts = 0x38,
  edn_err_code = 0x3c,
  edn_err_code_test = 0x40,
  edn_main_sm_state = 0x44,
	

  kCsrMcause = 0x342,
  kMachineTimerInterrupt = 0x80000007,
};

/* Private variables ---------------------------------------------------------*/
static volatile uint32_t irq_count;
static volatile uint32_t irq_failed;

/* Private functions ---------------------------------------------------------*/
static uint32_t edn_read(uint32_t offset) {
  return *(volatile uint32_t *)(uintptr_t)(kRvTimerBase + offset);
}

static void edn_write(uint32_t offset, uint32_t value) {
  *(volatile uint32_t *)(uintptr_t)(kRvTimerBase + offset) = value;
}

/* Mode functions-------------------------------------------------------------*/
static void boot_mode_test();

static void auto_req_mode();

static void fw_driven_mode();

/* Interrupt handlers --------------------------------------------------------*/
void ottf_timer_isr(uint32_t *exc_info) {
  uint32_t mcause;
  (void)exc_info;

  __asm__ volatile("csrr %0, %1" : "=r"(mcause) : "i"(kCsrMcause));
  if (mcause != kMachineTimerInterrupt ||
      (timer_read(kRvTimerIntrState0) & 1u) == 0 || irq_count != 0) {
    irq_failed = 1;
  }

  timer_write(kRvTimerCtrl, 0);
  timer_write(kRvTimerIntrState0, 1);
  ++irq_count;
}

/* TEST_MAIN -----------------------------------------------------------------*/
void test_main(void)
{
  boot_mode_test();		// 1. boot-time mode test
  edn_read();			// boot mode off
  edn_write();
  auto_req_mode();		// 2. auto-request mode test
						// auto mode off
  fw_driven_mode();		// 3. fw-driven mode test 
  
  intr_test();			// 4. interrupt test
  alert_test();			// 5. alert test

  irq_timer_ctrl(true);
  irq_global_ctrl(true);
  timer_write(kRvTimerCtrl, 1);
  while (irq_count == 0) {
    __asm__ volatile("wfi");
  }
  irq_global_ctrl(false);
  irq_timer_ctrl(false);

  if (irq_failed != 0 || irq_count != 1 ||
      (timer_read(kRvTimerIntrState0) & 1u) != 0 ||
      timer_read(kRvTimerValueLower0) == 0) {
    sg_sim_fail();
  }

  sg_dbg_printf("RV timer interrupt PASS");
  sg_sim_success();
}
