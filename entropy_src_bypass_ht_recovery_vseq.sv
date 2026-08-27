// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Bypass mode health-test recovery test (26.08.27)

class entropy_src_bypass_ht_recovery_vseq extends entropy_src_base_vseq;
  `uvm_object_utils(entropy_src_bypass_ht_recovery_vseq)

  `uvm_object_new

  localparam int unsigned BypassWindowBits = 384;
  localparam int unsigned NumRngTrans =
      BypassWindowBits / `RNG_BUS_WIDTH;

  localparam int unsigned SpinwaitTimeoutNs = 200_000;

  localparam bit [15:0] AdaptpLoThreshold =
      (NumRngTrans / 2) - 2;
  localparam bit [15:0] AdaptpHiThreshold =
      (NumRngTrans / 2) + 2;

  push_pull_host_seq#(`RNG_BUS_WIDTH) m_rng_push_seq;

  push_pull_host_seq#(
    entropy_src_pkg::FIPS_CSRNG_BUS_WIDTH
  ) m_csrng_pull_seq;

  // ------------------------------------------------------------
  // Configure bypass/boot-time mode
  // ------------------------------------------------------------
  task configure_bypass_mode(bit [15:0] alert_threshold);
    bit [15:0] alert_threshold_inv;

    disable_dut();

    cfg.m_rng_agent_cfg.clear_h_user_data();

    // Bypass the conditioner and route entropy to the CSRNG HW interface.
    ral.entropy_control.es_type.set(
      prim_mubi_pkg::MuBi4True
    );
    ral.entropy_control.es_route.set(
      prim_mubi_pkg::MuBi4False
    );
    csr_update(.csr(ral.entropy_control));

    // Boot-time bypass mode.
    ral.conf.fips_enable.set(
      prim_mubi_pkg::MuBi4False
    );
    ral.conf.entropy_data_reg_enable.set(
      prim_mubi_pkg::MuBi4False
    );
    ral.conf.rng_bit_enable.set(
      prim_mubi_pkg::MuBi4False
    );
    ral.conf.threshold_scope.set(
      prim_mubi_pkg::MuBi4False
    );
    csr_update(.csr(ral.conf));

    // Allow health-test threshold configuration.
    ral.threshold_oneway.set(
      prim_mubi_pkg::MuBi4False
    );
    csr_update(.csr(ral.threshold_oneway));

    // Firmware override mode is not used.
    ral.fw_ov_control.fw_ov_mode.set(
      prim_mubi_pkg::MuBi4False
    );
    ral.fw_ov_control.fw_ov_entropy_insert.set(
      prim_mubi_pkg::MuBi4False
    );
    csr_update(.csr(ral.fw_ov_control));

    // One bypass window contains 384 raw entropy bits.
    ral.health_test_windows.bypass_window.set(
      BypassWindowBits
    );
    csr_update(.csr(ral.health_test_windows));

    // Prevent health tests other than AdaptP from causing failures.
    csr_wr(
      .ptr(ral.repcnt_threshold),
      .value(16'hffff)
    );
    csr_wr(
      .ptr(ral.repcnts_threshold),
      .value(16'hffff)
    );
    csr_wr(
      .ptr(ral.bucket_threshold),
      .value(16'hffff)
    );
    csr_wr(
      .ptr(ral.markov_hi_threshold),
      .value(16'hffff)
    );
    csr_wr(
      .ptr(ral.markov_lo_threshold),
      .value(16'h0000)
    );

    // An all-zero window fails AdaptP.
    // An alternating all-zero/all-one window passes AdaptP.
    csr_wr(
      .ptr(ral.adaptp_hi_threshold),
      .value(AdaptpHiThreshold)
    );
    csr_wr(
      .ptr(ral.adaptp_lo_threshold),
      .value(AdaptpLoThreshold)
    );

    // ALERT_THRESHOLD_INV is stored in the upper 16 bits.
    alert_threshold_inv = ~alert_threshold;

    csr_wr(
      .ptr(ral.alert_threshold),
      .value({alert_threshold_inv, alert_threshold})
    );

    // Enable only the health-test-failed interrupt.
    csr_wr(
      .ptr(ral.intr_enable),
      .value(1 << HealthTestFailed)
    );

    enable_dut();
  endtask : configure_bypass_mode

  // ------------------------------------------------------------
  // Inject one 384-bit bypass health-test window
  // ------------------------------------------------------------
  task push_rng_window(bit fail_window);
    rng_val_t rng_word;

    m_rng_push_seq =
        push_pull_host_seq#(`RNG_BUS_WIDTH)::type_id::create(
          fail_window ? "fail_rng_seq" : "pass_rng_seq"
        );

    // RNG_BUS_WIDTH=4: 384 / 4 = 96 RNG transactions.
    m_rng_push_seq.num_trans = NumRngTrans;

    cfg.m_rng_agent_cfg.clear_h_user_data();

    for (int i = 0; i < NumRngTrans; i++) begin
      if (fail_window) begin
        // All-zero input fails the AdaptP low threshold.
        rng_word = '0;
      end else begin
        // Balanced input that passes AdaptP.
        rng_word = (i % 2) ? '1 : '0;
      end

      cfg.m_rng_agent_cfg.add_h_user_data(rng_word);
    end

    m_rng_push_seq.start(
      p_sequencer.rng_sequencer_h
    );
  endtask : push_rng_window

  // ------------------------------------------------------------
  // Case 1: fail once and then recover
  // ------------------------------------------------------------
  task test_fail_then_pass();
    int unsigned seed_count_before;
    bit [TL_DW-1:0] main_state;

    `uvm_info(
      `gfn,
      "CASE 1: one failed window followed by one passing window",
      UVM_LOW
    )

    configure_bypass_mode(16'd2);

    seed_count_before = cfg.total_seeds_consumed;

    m_csrng_pull_seq =
        push_pull_host_seq#(
          entropy_src_pkg::FIPS_CSRNG_BUS_WIDTH
        )::type_id::create("case1_csrng_pull_seq");

    m_csrng_pull_seq.num_trans = 1;

    fork
      begin
        // Request one seed through the CSRNG hardware interface.
        m_csrng_pull_seq.start(
          p_sequencer.csrng_sequencer_h
        );
      end

      begin
        `uvm_info(
          `gfn,
          "CASE 1: injecting failed window",
          UVM_LOW
        )

        push_rng_window(1'b1);

        // One health-test failure must be recorded.
        csr_spinwait(
          .ptr(ral.alert_summary_fail_counts.any_fail_count),
          .exp_data(16'd1),
          .backdoor(1),
          .timeout_ns(SpinwaitTimeoutNs)
        );

        csr_rd(
          .ptr(ral.main_sm_state.main_sm_state),
          .value(main_state)
        );

        // A single failure must not reach AlertHang.
        `DV_CHECK(
          main_state != entropy_src_main_sm_pkg::AlertHang
        )

        // The failed window must not produce a seed.
        `DV_CHECK(
          cfg.total_seeds_consumed == seed_count_before
        )

        `uvm_info(
          `gfn,
          "CASE 1: injecting passing window",
          UVM_LOW
        )

        push_rng_window(1'b0);
      end
    join

    // The passing retry must produce exactly one seed.
    `DV_CHECK(
      cfg.total_seeds_consumed == seed_count_before + 1
    )

    // A passing window clears the consecutive failure counter.
    csr_rd_check(
      .ptr(ral.alert_summary_fail_counts.any_fail_count),
      .compare_value(16'd0)
    );

    `uvm_info(
      `gfn,
      "CASE 1 PASSED: failed window discarded and next passing window produced a seed",
      UVM_LOW
    )
  endtask : test_fail_then_pass

  // ------------------------------------------------------------
  // Case 2: two consecutive failures reach AlertHang
  // ------------------------------------------------------------
  task test_consecutive_fail_alert_hang();
    int unsigned seed_count_before;

    `uvm_info(
      `gfn,
      "CASE 2: two consecutive failed windows reach ALERT_THRESHOLD",
      UVM_LOW
    )

    configure_bypass_mode(16'd2);

    seed_count_before = cfg.total_seeds_consumed;

    m_csrng_pull_seq =
        push_pull_host_seq#(
          entropy_src_pkg::FIPS_CSRNG_BUS_WIDTH
        )::type_id::create("case2_csrng_pull_seq");

    m_csrng_pull_seq.num_trans = 1;

    // This CSRNG request must remain pending while both windows fail.
    fork : csrng_waiter
      begin
        m_csrng_pull_seq.start(
          p_sequencer.csrng_sequencer_h
        );
      end
    join_none

    `uvm_info(
      `gfn,
      "CASE 2: injecting first failed window",
      UVM_LOW
    )

    push_rng_window(1'b1);

    // The first failed window increments the consecutive fail count.
    csr_spinwait(
      .ptr(ral.alert_summary_fail_counts.any_fail_count),
      .exp_data(16'd1),
      .backdoor(1),
      .timeout_ns(SpinwaitTimeoutNs)
    );

    // No seed must have been delivered.
    `DV_CHECK(
      cfg.total_seeds_consumed == seed_count_before
    )

    // The CSRNG request must still be pending.
    `DV_CHECK(
      m_csrng_pull_seq.get_sequence_state() != UVM_FINISHED
    )

    `uvm_info(
      `gfn,
      "CASE 2: injecting second failed window",
      UVM_LOW
    )

    // The second consecutive failure reaches ALERT_THRESHOLD.
    push_rng_window(1'b1);

    // Health-test-failed interrupt must be raised.
    csr_spinwait(
      .ptr(ral.intr_state.es_health_test_failed),
      .exp_data(1'b1),
      .timeout_ns(SpinwaitTimeoutNs)
    );

    // The main state machine must enter AlertHang.
    csr_spinwait(
      .ptr(ral.main_sm_state.main_sm_state),
      .exp_data(entropy_src_main_sm_pkg::AlertHang),
      .timeout_ns(SpinwaitTimeoutNs)
    );

    // Two consecutive failures must be recorded.
    csr_rd_check(
      .ptr(ral.alert_summary_fail_counts.any_fail_count),
      .compare_value(16'd2)
    );

    // Confirm that the DUT remains in AlertHang.
    cfg.clk_rst_vif.wait_clks(100);

    csr_rd_check(
      .ptr(ral.main_sm_state.main_sm_state),
      .compare_value(entropy_src_main_sm_pkg::AlertHang)
    );

    // AlertHang must not produce a seed.
    `DV_CHECK(
      cfg.total_seeds_consumed == seed_count_before
    )

    // The CSRNG request must remain pending.
    `DV_CHECK(
      m_csrng_pull_seq.get_sequence_state() != UVM_FINISHED
    )

    // Check and clear the health-test-failed interrupt.
    check_interrupts(
      .interrupts(1 << HealthTestFailed),
      .check_set(1'b1)
    );

    // The pending CSRNG request was intentional. Reset only the
    // CSRNG interface so its push/pull driver can abort and clean up
    // the outstanding transaction normally.
    apply_reset(.kind("CSRNG_ONLY"));

    // Wait for the csrng_waiter thread to finish after CSRNG reset.
    wait fork;

    // MODULE_ENABLE=False releases the main state machine from AlertHang.
    disable_dut();

    csr_spinwait(
      .ptr(ral.main_sm_state.main_sm_state),
      .exp_data(entropy_src_main_sm_pkg::Idle),
      .timeout_ns(SpinwaitTimeoutNs)
    );

    `uvm_info(
      `gfn,
      "CASE 2 PASSED: ALERT_THRESHOLD reached and DUT stayed in AlertHang",
      UVM_LOW
    )
  endtask : test_consecutive_fail_alert_hang

  // ------------------------------------------------------------
  // Main test body
  // ------------------------------------------------------------
  task body();
    // Case 1: fail -> pass -> one seed.
    test_fail_then_pass();

    // Let the completed CSRNG/esfinal handshake settle.
    cfg.clk_rst_vif.wait_clks(5);

    // Clear the DUT state without immediately applying a hard reset.
    disable_dut();
    cfg.clk_rst_vif.wait_clks(5);

    // configure_bypass_mode() configures and enables the DUT again.
    // Case 2: fail -> fail -> AlertHang.
    test_consecutive_fail_alert_hang();
  endtask : body

endclass : entropy_src_bypass_ht_recovery_vseq
