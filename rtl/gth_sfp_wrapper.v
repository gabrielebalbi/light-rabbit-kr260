`timescale 1ns/1ps

// GTH wrapper per KR260 SFP+ cage — variante SDM
// SFP+ usa GTH_DP2 su K26 SOM (schema KR260 foglio 14)
// Refclk: 156.25 MHz LVDS da U90, GTH_REFCLK0_C2M_P/N (foglio 16)
// Data rate nominale: 10.3125 Gbps (QPLL0, FBDIV=66, SDM abilitato con data=0)
// LOC: GTHE4_CHANNEL_X0Y6 / GTHE4_COMMON_X0Y1
//
// Modifiche rispetto al progetto base sfp_drp_kr260:
//   - GTHE4_COMMON DRP esportato come porte drpcomm_* (accesso runtime ai registri SDM)
//   - QPLL0_SDM_CFG0/1/2: SDM abilitato, parola frazionaria = 0 (equivalente integer)
//     Usare DRP COMMON per cambiare SDM_DATA[21:0] a runtime (UG576 v1.7.1 Table C-1):
//       QPLL0_SDM_CFG0 @ DRP addr 0x0020: bits[12:0] = SDM_DATA[12:0], bit[14]=0 → SDM enable
//       QPLL0_SDM_CFG1 @ DRP addr 0x0021: bits[8:0]  = SDM_DATA[21:13]
//       QPLL0_SDM_CFG2 @ DRP addr 0x0024
//   - TXOUTCLK (TXPRGDIVCLK) esportato via BUFG_GT come txoutclk_o per il frequenzimetro
//   - GTTXRESET portato fuori come tx_reset; nel top viene cablato a 0 per TXOUTCLK valido
module gth_sfp_wrapper (
    input  wire refclk_p,
    input  wire refclk_n,
    output wire tx_p,
    output wire tx_n,
    input  wire rx_p,
    input  wire rx_n,
    input  wire tx_reset,
    input  wire rx_reset,
    // DRP GTHE4_CHANNEL
    input  wire        drpclk,
    input  wire [9:0]  drpaddr,
    input  wire [15:0] drpdi,
    output wire [15:0] drpdo,
    input  wire        drpen,
    input  wire        drpwe,
    output wire        drprdy,
    // DRP GTHE4_COMMON (registri SDM, QPLL)
    input  wire [9:0]  drpcomm_addr,
    input  wire [15:0] drpcomm_di,
    output wire [15:0] drpcomm_do,
    input  wire        drpcomm_en,
    input  wire        drpcomm_we,
    output wire        drpcomm_rdy,
    // TXOUTCLK buffered (TXPRGDIVCLK via BUFG_GT) per frequenzimetro
    output wire        txoutclk_o,
    output wire        tx_resetdone,
    output wire        rx_resetdone,
    output wire        qpll0_lock
);

    // ------------------------------------------------------------------
    // FIX 2026-07-02: sequenza di reset post-config (prima: reset statici,
    // TXPROGDIVRESET non cablato, TXPROGDIV_CFG assente -> TXPRGDIVCLK MORTO,
    // frequenzimetro muto al primo test HW).
    //  1. POR: pulse QPLL0RESET dopo la config (GSR non basta per i GT).
    //  2. Al lock QPLL0: pulse GTTXRESET, poi TXPROGDIVRESET, poi TXUSERRDY.
    // Tutto nel dominio drpclk (pl_clk0/AXI), qpll0_lock risincronizzato.
    // ------------------------------------------------------------------
    wire qpll0_lock_i;
    reg  [10:0] por_cnt = 11'd0;
    wire por_done = &por_cnt;
    always @(posedge drpclk) if (!por_done) por_cnt <= por_cnt + 1'b1;
    wire qpll0reset_int = ~por_done;

    reg [1:0] qlock_sync = 2'b00;
    always @(posedge drpclk) qlock_sync <= {qlock_sync[0], qpll0_lock_i};
    wire qpll0_locked_s = qlock_sync[1];

    reg [15:0] seq_cnt = 16'd0;
    reg gttxreset_int      = 1'b1;
    reg txprogdivreset_int = 1'b1;
    reg txuserrdy_int      = 1'b0;
    always @(posedge drpclk) begin
        if (tx_reset || !qpll0_locked_s) begin
            seq_cnt            <= 16'd0;
            gttxreset_int      <= 1'b1;
            txprogdivreset_int <= 1'b1;
            txuserrdy_int      <= 1'b0;
        end else begin
            if (!(&seq_cnt)) seq_cnt <= seq_cnt + 1'b1;
            gttxreset_int      <= (seq_cnt < 16'd1000);
            txprogdivreset_int <= (seq_cnt < 16'd2000);
            txuserrdy_int      <= (seq_cnt > 16'd3000);
        end
    end

    assign qpll0_lock = qpll0_lock_i;

    wire refclk_buf;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_ibufds_refclk (
        .I(refclk_p), .IB(refclk_n), .CEB(1'b0),
        .O(refclk_buf), .ODIV2()
    );

    wire qpll0clk, qpll0refclk;
    GTHE4_COMMON #(
        .SIM_RESET_SPEEDUP  ("TRUE"),
        // QPLL0: 156.25 MHz × 66 = 10312.5 MHz VCO → 10.3125 Gbps
        .QPLL0_FBDIV        (66),
        .QPLL0_REFCLK_DIV   (1),
        .QPLL0_CFG0         (16'h333C),
        .QPLL0_CFG1         (16'hD038),
        .QPLL0_CFG2         (16'h0FC0),
        .QPLL0_CFG3         (16'h0120),
        .QPLL0_CFG4         (16'h0002),
        .QPLL0_CP           (10'h1FF),
        .QPLL0_INIT_CFG0    (16'h02B2),
        .QPLL0_INIT_CFG1    (8'h00),
        .QPLL0_LOCK_CFG     (16'h25F8),
        .QPLL0_LPF          (10'h2FF),
        // SDM abilitato (bit[14]=0 in CFG0), parola frazionaria iniziale = 0
        // Riconfigurabile a runtime via DRP COMMON su drpcomm_*
        .QPLL0_SDM_CFG0     (16'h0000),
        .QPLL0_SDM_CFG1     (16'h0000),
        .QPLL0_SDM_CFG2     (16'h0000),
        .QPLL1_FBDIV        (66),
        .QPLL1_REFCLK_DIV   (1)
    ) u_gthe4_common (
        .QPLL0OUTCLK    (qpll0clk),    .QPLL0OUTREFCLK (qpll0refclk),
        .QPLL0LOCK      (qpll0_lock_i),.QPLL0FBCLKLOST (),
        .QPLL0REFCLKLOST(),            .QPLL0REFCLKSEL (3'b001),
        .QPLL0LOCKDETCLK(drpclk),      .QPLL0RESET     (qpll0reset_int),
        .QPLL0PD        (1'b0),        .REFCLKOUTMONITOR0(),
        .QPLL1OUTCLK    (),            .QPLL1OUTREFCLK (),
        .QPLL1LOCK      (),            .QPLL1FBCLKLOST (),
        .QPLL1REFCLKLOST(),            .QPLL1REFCLKSEL (3'b001),
        .QPLL1LOCKDETCLK(drpclk),      .QPLL1RESET     (1'b1),
        .QPLL1PD        (1'b1),        .REFCLKOUTMONITOR1(),
        .BGBYPASSB      (1'b1),        .BGMONITORENB   (1'b1),
        .BGPDB          (1'b1),        .BGRCALOVRD     (5'b11111),
        .BGRCALOVRDENB  (1'b1),
        .PMARSVDOUT0    (),            .PMARSVDOUT1    (),
        // DRP COMMON connesso alle porte esterne
        .DRPCLK         (drpclk),
        .DRPADDR        (drpcomm_addr[8:0]),
        .DRPDI          (drpcomm_di),
        .DRPDO          (drpcomm_do),
        .DRPEN          (drpcomm_en),
        .DRPWE          (drpcomm_we),
        .DRPRDY         (drpcomm_rdy),
        .GTREFCLK00     (refclk_buf),  .GTREFCLK10     (1'b0),
        .GTREFCLK01     (1'b0),        .GTREFCLK11     (1'b0),
        .GTNORTHREFCLK00(1'b0),        .GTNORTHREFCLK10(1'b0),
        .GTNORTHREFCLK01(1'b0),        .GTNORTHREFCLK11(1'b0),
        .GTSOUTHREFCLK00(1'b0),        .GTSOUTHREFCLK10(1'b0),
        .GTSOUTHREFCLK01(1'b0),        .GTSOUTHREFCLK11(1'b0),
        .PMARSVD0       (8'b0),        .PMARSVD1       (8'b0),
        .RCALENB        (1'b1)
    );

    wire txoutclk_raw;

    GTHE4_CHANNEL #(
        .SIM_RESET_SPEEDUP        ("TRUE"),
        .SIM_RECEIVER_DETECT_PASS ("TRUE"),
        .TX_DATA_WIDTH            (64),
        .TX_INT_DATAWIDTH         (1),
        .TXOUT_DIV                (1),
        .TXBUF_EN                 ("FALSE"),
        .TX_XCLK_SEL              ("TXUSR"),
        .RX_DATA_WIDTH            (64),
        .RX_INT_DATAWIDTH         (1),
        .RXOUT_DIV                (1),
        .RXBUF_EN                 ("FALSE"),
        .RX_XCLK_SEL              ("RXUSR"),
        .RXCDR_CFG0               (16'h0003),
        .RXCDR_CFG1               (16'h0000),
        .RXCDR_CFG2               (16'h0269),
        .RXCDR_CFG3               (16'h0000),
        .RXCDR_CFG4               (16'h0000),
        .CPLL_FBDIV               (4),
        .CPLL_FBDIV_45            (5),
        .CPLL_REFCLK_DIV          (1),
        // FIX 2/7: divisore PROGDIV esplicito (default 0.0 = spento!): TXPRGDIVCLK = 10.3125G/64 = 161.13 MHz
        .TX_PROGDIV_CFG           (64.0)
    ) u_gthe4_channel (
        .GTHTXP(tx_p), .GTHTXN(tx_n), .GTHRXP(rx_p), .GTHRXN(rx_n),
        .QPLL0CLK(qpll0clk), .QPLL0REFCLK(qpll0refclk),
        .QPLL1CLK(1'b0),     .QPLL1REFCLK(1'b0),
        // TX: TXUSRCLK = drpclk; TXOUTCLK (TXPRGDIVCLK) catturato per frequenzimetro
        .TXUSRCLK(drpclk), .TXUSRCLK2(drpclk),
        .TXOUTCLK(txoutclk_raw), .TXOUTCLKSEL(3'b101),
        .TXSYSCLKSEL(2'b11), .TXPLLCLKSEL(2'b11),
        .TXDATA(128'b0), .TXCTRL0(16'b0), .TXCTRL1(16'b0), .TXCTRL2(8'b0),
        // RX: in reset, non serve per la misura di frequenza
        .RXUSRCLK(drpclk), .RXUSRCLK2(drpclk),
        .RXOUTCLK(), .RXOUTCLKSEL(3'b101),
        .RXSYSCLKSEL(2'b11), .RXPLLCLKSEL(2'b11),
        .RXDATA(), .RXCTRL0(), .RXCTRL1(), .RXCTRL2(), .RXCTRL3(),
        // FIX 2/7: reset sequenziati dal FSM sopra (prima: statici, PROGDIV mai resettato)
        .GTTXRESET(gttxreset_int), .GTRXRESET(rx_reset),
        .TXUSERRDY(txuserrdy_int), .RXUSERRDY(!rx_reset),
        .TXPROGDIVRESET(txprogdivreset_int), .TXPRGDIVRESETDONE(),
        .RESETOVRD(1'b0),
        .TXRESETDONE(tx_resetdone), .RXRESETDONE(rx_resetdone),
        // DRP CHANNEL
        .DRPCLK(drpclk), .DRPADDR(drpaddr), .DRPDI(drpdi),
        .DRPDO(drpdo),   .DRPEN(drpen),     .DRPWE(drpwe), .DRPRDY(drprdy),
        .LOOPBACK(3'b000), .TXPD(2'b00), .RXPD(2'b00),
        .CPLLPD(1'b1), .CPLLRESET(1'b0), .CPLLLOCK(), .CPLLFREQLOCK(),
        .CPLLREFCLKSEL(3'b001),
        .GTREFCLK0(1'b0), .GTREFCLK1(1'b0),
        .GTNORTHREFCLK0(1'b0), .GTNORTHREFCLK1(1'b0),
        .GTSOUTHREFCLK0(1'b0), .GTSOUTHREFCLK1(1'b0),
        .TXDIFFCTRL(5'b11000), .TXMAINCURSOR(7'b0), .TXPOSTCURSOR(5'b0), .TXPRECURSOR(5'b0),
        .TXPOLARITY(1'b0), .RXPOLARITY(1'b0),
        .TXINHIBIT(1'b0),  .TXELECIDLE(1'b0),
        .TX8B10BEN(1'b0),  .RX8B10BEN(1'b0),
        .RXLPMEN(1'b0),
        .DMONITOROUT(), .DMONITORCLK(1'b0),
        .EYESCANDATAERROR(), .EYESCANRESET(1'b0), .EYESCANTRIGGER(1'b0),
        .RXCDRHOLD(1'b0), .RXCDRRESET(1'b0),
        .RXDFELFHOLD(1'b0), .RXDFELPMRESET(1'b0),
        .RXRATE(3'b0), .RXRATEDONE(), .TXRATE(3'b0), .TXRATEDONE(),
        .RXSLIDE(1'b0), .RXBUFRESET(1'b0), .RXBUFSTATUS(), .TXBUFSTATUS(),
        .RXGEARBOXSLIP(1'b0), .RXDATAVALID(), .RXHEADER(), .RXHEADERVALID(), .RXSTARTOFSEQ(),
        .TXHEADER(6'b0), .TXSEQUENCE(7'b0),
        .RXPRBSCNTRESET(1'b0), .RXPRBSSEL(4'b0), .RXPRBSERR(), .RXPRBSLOCKED(),
        .TXPRBSSEL(4'b0), .TXPRBSFORCEERR(1'b0),
        .TXDLYBYPASS(1'b1), .RXDLYBYPASS(1'b1),
        .TXDLYEN(1'b0), .TXDLYSRESET(1'b0), .TXDLYSRESETDONE(), .TXDLYOVRDEN(1'b0),
        .RXDLYEN(1'b0), .RXDLYSRESET(1'b0), .RXDLYSRESETDONE(), .RXDLYOVRDEN(1'b0),
        .TXPHALIGNEN(1'b0), .TXPHALIGN(1'b0), .TXPHALIGNDONE(),
        .RXPHALIGNEN(1'b0), .RXPHALIGN(1'b0), .RXPHALIGNDONE(),
        .PCSRSVDIN(16'b0), .PCSRSVDOUT(),
        .GTPOWERGOOD(), .TSTIN(20'hFFFFF),
        .CLKRSVD0(1'b0), .CLKRSVD1(1'b0),
        .TXDETECTRX(1'b0)
    );

    // BUFG_GT: portale di clock da GTHE4 verso fabric. DIV=000 → divide-by-1.
    // Vivado posiziona automaticamente il BUFG_GT nel clock region del GTHE4_CHANNEL_X0Y6.
    BUFG_GT u_bufg_txout (
        .I       (txoutclk_raw),
        .CE      (1'b1),
        .CEMASK  (1'b0),
        .CLR     (1'b0),
        .CLRMASK (1'b0),
        .DIV     (3'b000),
        .O       (txoutclk_o)
    );

endmodule
