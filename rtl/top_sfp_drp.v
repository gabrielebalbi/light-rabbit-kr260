`timescale 1ns/1ps

// Top-level: block design wrapper (PS + AXI bridge CH + AXI bridge COMMON + freq_counter)
//            + GTH wrapper SFP+
// Mappa AXI (base assegnata in create_project.tcl):
//   0xA0000000  axi_drp_bridge       DRP GTHE4_CHANNEL
//   0xA0010000  axi_iic_sfp          I2C SFP+ + GPO laser enable  (da add_axi_iic.tcl)
//   0xA0020000  axi_drp_bridge_common DRP GTHE4_COMMON (registri SDM QPLL0)
//   0xA0030000  freq_counter          frequenzimetro TXPRGDIVCLK
module top_sfp_drp (
    input  wire sfp_refclk_p,
    input  wire sfp_refclk_n,
    output wire sfp_tx_p,
    output wire sfp_tx_n,
    input  wire sfp_rx_p,
    input  wire sfp_rx_n,
    inout  wire sfp_iic_scl_io,
    inout  wire sfp_iic_sda_io,
    output wire sfp_tx_disable
);

    // DRP CHANNEL
    wire        drpclk;
    wire [9:0]  drpaddr;
    wire [15:0] drpdi, drpdo;
    wire        drpen, drpwe, drprdy;

    // DRP COMMON (registri SDM QPLL0)
    wire [9:0]  drpcomm_addr;
    wire [15:0] drpcomm_di, drpcomm_do;
    wire        drpcomm_en, drpcomm_we, drpcomm_rdy;

    // TXOUTCLK da GTHE4 (TXPRGDIVCLK via BUFG_GT)
    wire txoutclk;

    // Laser enable dal GPO AXI IIC
    wire [0:0] sfp_laser_en;
    assign sfp_tx_disable = ~sfp_laser_en[0];

    // Block design: PS + bridge CH + bridge COMMON + freq_counter
    design_1_wrapper u_bd (
        // DRP CHANNEL
        .drpclk         (drpclk),
        .drpaddr        (drpaddr),
        .drpdi          (drpdi),
        .drpdo          (drpdo),
        .drpen          (drpen),
        .drpwe          (drpwe),
        .drprdy         (drprdy),
        // DRP COMMON
        .drpcomm_addr   (drpcomm_addr),
        .drpcomm_di     (drpcomm_di),
        .drpcomm_do     (drpcomm_do),
        .drpcomm_en     (drpcomm_en),
        .drpcomm_we     (drpcomm_we),
        .drpcomm_rdy    (drpcomm_rdy),
        // TXOUTCLK per frequenzimetro
        .txoutclk_i     (txoutclk),
        // SFP I2C e laser
        .sfp_iic_scl_io (sfp_iic_scl_io),
        .sfp_iic_sda_io (sfp_iic_sda_io),
        .sfp_laser_en   (sfp_laser_en)
    );

    // GTH wrapper: tx_reset = 0 → TX esce dal reset → TXOUTCLK (TXPRGDIVCLK) valido
    gth_sfp_wrapper u_gth (
        .refclk_p       (sfp_refclk_p),
        .refclk_n       (sfp_refclk_n),
        .tx_p           (sfp_tx_p),
        .tx_n           (sfp_tx_n),
        .rx_p           (sfp_rx_p),
        .rx_n           (sfp_rx_n),
        .tx_reset       (1'b0),
        .rx_reset       (1'b1),
        .drpclk         (drpclk),
        .drpaddr        (drpaddr),
        .drpdi          (drpdi),
        .drpdo          (drpdo),
        .drpen          (drpen),
        .drpwe          (drpwe),
        .drprdy         (drprdy),
        .drpcomm_addr   (drpcomm_addr),
        .drpcomm_di     (drpcomm_di),
        .drpcomm_do     (drpcomm_do),
        .drpcomm_en     (drpcomm_en),
        .drpcomm_we     (drpcomm_we),
        .drpcomm_rdy    (drpcomm_rdy),
        .txoutclk_o     (txoutclk),
        .tx_resetdone   (),
        .rx_resetdone   (),
        .qpll0_lock     ()
    );

endmodule
