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
  return *(volatile uint32_t *)(uintptr_t)(ednBase + offset);
}

static void edn_write(uint32_t offset, uint32_t value) {
  *(volatile uint32_t *)(uintptr_t)(ednBase + offset) = value;
}

/* Mode functions-------------------------------------------------------------*/
static void boot_mode_test(void){

  edn_write(edn_boot_ins_cmd, 0x00000901); 
  edn_write(edn_boot_gen_cmd, 0x00FFF003);
  edn_write(edn_ctrl, 0x00009966); //boot mode on

};

static void auto_req_mode(
  // edn_write(edn_ctrl, 0x00009999);
  // while ((edn_read(edn_main_sm_state) & 0x1FF) != 0x0C1){
  // }

  edn_write(edn_ctrl, 0x00006999); //CMD FIFO reset
  edn_write(edn_ctrl, 0x00009999); //CMD FIFO reset off

  edn_write (edn_reseed_cmd, 0x00000902 ) //reseed fifo fill
  edn_write(edn_generate_cmd, 0x00001903) //generate fifo fill
  edn_write(edn_max_num_reqs_between_reseeds,2)//value = 2

  edn_write(edn_ctrl, 0x00009696) //Auto request mode on

  while ((edn_read(edn_sw_cmd_sts) & 0x3) != 0x3) { //wait until CMD_REG_RDY =1 & CMD_RDY =1
  }
  sg_dbg_printf("auto request mode cmd_sts wait finished");

  edn_write(edn_sw_cmd_req, 0x00000901) //instantiate write
  while ((edn_read (edn_sw_cmd_sts) & 0x4) == 0){   //wait until Instantiate ACK
  }
  sg_dbg_printf("Uninstantiate ACk");
                             
  if ((edn_read (edn_sw_cmd_sts) & 0x38) != 0){     //CMD_STS must be SUCCESS
    sg_dbg_printf("[AUTO] Instantiate FAILED");
    sg_sim_fail();
    return;
  }
    sg_dbg_printf("[AUTO] Instantiate SUCCESS");
    sg_dbg_printf("[AUTO] Current state=0x%x, HW_CMD_STS=0x%x",
                  edn_read(edn_main_sm_state),
                  edn_read(edn_hw_cmd_sts));

  );

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
  sg_dbg_printf("[TEST] EDN test started");
  sg_dbg_printf("[TEST] Initial CTRL=0x%x, state = 0x%x", edn_read(edn_ctrl), edn_read(edn_main_sm_state));
  //boot_mode_test();		// 1. boot-time mode test
  sg_dbg_printf("[BOOT] Wait for BootDone");
  while ((edn_read(edn_main_sm_state) & 0x1FF) != 0x0F0){
  }                         //wait until SwPort state
  sg_dbg_printf("[BOOT] BootDone");

  edn_write(edn_ctrl, 0x00009996); //write boot mode off
  while((edn_read(edn_main_sm_state) & 0x1FF) != 0x095){   //Uninstantiate wait
  }
  sg_dbg_printf("[BOOT] SWPortMode");

  sg_dbg_printf("[AUTO] Start Auto Request Mode test")
  auto_req_mode();		// 2. auto-request mode test
    /* auto_req_mode()에서 실패 후 return한 경우 진행 방지 */
    if ((edn_read(edn_sw_cmd_sts) & 0x38) != 0) {
        return;
    }

    /*
     * Auto 실행 시간을 주는 예시 구간.
     * 이 반복 횟수는 Generate/Reseed 횟수가 아님.
     */
    sg_dbg_printf("[AUTO] Running");

    for (uint32_t i = 0; i < 10000; ++i) {
        (void)edn_read(edn_hw_cmd_sts);
    }

    sg_dbg_printf("[AUTO] Stopping, HW_CMD_STS=0x%x",
                  edn_read(edn_hw_cmd_sts));

    edn_write(edn_ctrl, 0x00009996); /* Auto off */

    sg_dbg_printf("[AUTO] Waiting for SWPortMode");

    while ((edn_read(edn_main_sm_state) & 0x1FF) != 0x095) {
    }

    sg_dbg_printf("[AUTO] SWPortMode reached");

    /* Auto 종료 후 Software Uninstantiate */
    sg_dbg_printf("[AUTO] Waiting for command ready");

    while ((edn_read(edn_sw_cmd_sts) & 0x3) != 0x3) {
    }

    edn_write(edn_sw_cmd_req, 0x00000005);

    sg_dbg_printf("[AUTO] Uninstantiate written, waiting for ACK");

    while ((edn_read(edn_sw_cmd_sts) & 0x4) == 0) {
    }

    if ((edn_read(edn_sw_cmd_sts) & 0x38) != 0) {
        sg_dbg_printf("[AUTO] Uninstantiate FAILED, status=0x%x",
                      edn_read(edn_sw_cmd_sts));
        sg_sim_fail();
        return;
    }

    sg_dbg_printf("[AUTO] Uninstantiate SUCCESS");

  //fw_driven_mode();		// 3. fw-driven mode test 
  //intr_test();			// 4. interrupt test
  //alert_test();			// 5. alert test

  // irq_timer_ctrl(true);
  // irq_global_ctrl(true);
  // timer_write(kRvTimerCtrl, 1);
  // while (irq_count == 0) {
  //   __asm__ volatile("wfi");
  // }
  // irq_global_ctrl(false);
  // irq_timer_ctrl(false);

  // if (irq_failed != 0 || irq_count != 1 ||
  //     (timer_read(kRvTimerIntrState0) & 1u) != 0 ||
  //     timer_read(kRvTimerValueLower0) == 0) {
  //   sg_sim_fail();
  // }

  // sg_dbg_printf("RV timer interrupt PASS");
  // sg_sim_success();
}
