`timescale 1ns/1ps

// TDC a catena di carry per timestamping di precisione (v16).
// Clock TDC: 375 MHz da MMCM alimentato da clk_ref_62m5 = TXUSRCLK2, il clock
// WR-disciplinato (SiT5359 sterzato via SDM) — lo stesso che misura il fmeter.
// NB: in questo design clk_sys_62m5 e' FREE-RUNNING (pl_clk0/2), NON usarlo.
// Il coarse counter e i fine tap vivono quindi nella base tempi White Rabbit.
// A link giu'/GT in reset TXUSRCLK2 balla -> mmcm_locked in STATUS va guardato.
// Ancoraggio al tempo assoluto: mux dell'ingresso sul PPS del WRPC -> il
// timestamp del PPS lega coarse/fine al confine di secondo TAI.
//
// Register map (AXI4-Lite, offset da base 0xA0060000):
//   0x00  CSR      r/w  [0] enable | [2:1] input_sel (0=PMOD 1=PPS 2=cal 3=sw)
//                       [3] fifo_reset (autoclear) | [4] sw_strobe (toggle: ogni
//                       scrittura con bit4=1 inverte la linea sw -> 1 fronte)
//   0x04  STATUS   r/o  [0] mmcm_locked | [1] fifo_empty | [2] ovfl (sticky,
//                       clear su lettura) | [31:16] fifo_count
//   0x08  TS_LO    r/o  {coarse[21:0], fine[9:0]} — la lettura fa pop e
//                       congela TS_HI del medesimo stamp
//   0x0C  TS_HI    r/o  {seq[7:0], 2'b00, coarse[43:22]}
//   0x10  TAPS     r/o  numero di tap della linea (per la calibrazione)
//   0x14  CLK_HZ   r/o  frequenza clock TDC in Hz
//   0x18  CNT_HITS r/o  conteggio hit totale (wrap 32 bit, anche a FIFO piena)
//
// Calibrazione (software, code-density): input_sel=2 (cal = aclk/6, asincrono
// rispetto al clock TDC), raccogliere ~1e5 stamp, istogramma dei fine ->
// larghezza dei bin in ps. fine=0 o fine=TAPS saturi = fronte fuori finestra.
module tdc_carry #(
    parameter integer N_C8         = 96,
    parameter integer TDC_CLK_HZ   = 375_000_000,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 8
) (
    input  wire clk_ref_62m5,     // TXUSRCLK2 62.5 MHz WR-disciplinato (rif. MMCM)
    input  wire tdc_hit_pmod,     // ingresso esterno (PMOD1 pin 3, E10)
    input  wire pps_i,            // PPS dal WRPC (dominio 62m5)
    input  wire s_axi_aclk,
    input  wire s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [2:0]                         s_axi_awprot,
    input  wire                               s_axi_awvalid,
    output reg                                s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                               s_axi_wvalid,
    output reg                                s_axi_wready,
    output wire [1:0]                         s_axi_bresp,
    output reg                                s_axi_bvalid,
    input  wire                               s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [2:0]                         s_axi_arprot,
    input  wire                               s_axi_arvalid,
    output reg                                s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                         s_axi_rresp,
    output reg                                s_axi_rvalid,
    input  wire                               s_axi_rready
);
    localparam integer NT = N_C8*8;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // ------------------------------------------------------------------
    // MMCM: 62.5 MHz -> VCO 1125 MHz (x18) -> /3 = 375 MHz
    // ------------------------------------------------------------------
    wire clk_fb, clk_tdc_raw, clk_tdc, mmcm_locked;
    MMCME4_BASE #(
        .CLKIN1_PERIOD   (16.000),
        .CLKFBOUT_MULT_F (18.000),
        .DIVCLK_DIVIDE   (1),
        .CLKOUT0_DIVIDE_F(3.000)
    ) u_mmcm (
        .CLKIN1   (clk_ref_62m5),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_tdc_raw),
        .CLKOUT0B (), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3  (), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );
    BUFG u_bufg_tdc (.I(clk_tdc_raw), .O(clk_tdc));

    // ------------------------------------------------------------------
    // Registri di controllo (dominio aclk) + sync verso clk_tdc
    // ------------------------------------------------------------------
    reg        csr_enable;
    reg  [1:0] csr_sel;
    reg        sw_line;          // linea toggle per input_sel=3
    reg  [2:0] cal_div;          // aclk/6 ~ 20.8 MHz per la calibrazione
    reg        cal_line;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            cal_div <= 0; cal_line <= 0;
        end else if (cal_div == 3'd2) begin
            cal_div <= 0; cal_line <= ~cal_line;
        end else
            cal_div <= cal_div + 1;
    end

    // mux ingresso: combinatorio, poi dentro la catena (l'asincronia e' il punto)
    wire hit_mux = (csr_sel == 2'd0) ? tdc_hit_pmod :
                   (csr_sel == 2'd1) ? pps_i        :
                   (csr_sel == 2'd2) ? cal_line     : sw_line;
    wire hit_gated = hit_mux & csr_enable;

    // ------------------------------------------------------------------
    // Dominio clk_tdc: coarse counter + delay line
    // ------------------------------------------------------------------
    reg [43:0] coarse_cnt = 44'd0;
    always @(posedge clk_tdc) coarse_cnt <= coarse_cnt + 1;

    wire        st_valid;
    wire [9:0]  st_fine;
    wire [43:0] st_coarse;
    tdc_delayline #(.N_C8(N_C8)) u_dl (
        .clk_i         (clk_tdc),
        .hit_i         (hit_gated),
        .coarse_i      (coarse_cnt),
        .stamp_valid_o (st_valid),
        .fine_o        (st_fine),
        .coarse_o      (st_coarse)
    );

    reg [7:0]  seq_cnt = 8'd0;
    reg [31:0] hit_cnt_tdc = 32'd0;
    always @(posedge clk_tdc)
        if (st_valid) begin
            seq_cnt     <= seq_cnt + 1;
            hit_cnt_tdc <= hit_cnt_tdc + 1;
        end

    // hit counter verso aclk: gray non necessario per un contatore di servizio;
    // si campiona via doppio FF accettando letture transitorie non coerenti
    (* ASYNC_REG = "true" *) reg [31:0] hit_cnt_m, hit_cnt_a;
    always @(posedge s_axi_aclk) begin
        hit_cnt_m <= hit_cnt_tdc;
        hit_cnt_a <= hit_cnt_m;
    end

    // ------------------------------------------------------------------
    // Reset FIFO: richiesto sincrono a wr_clk (XPM) -> toggle-sync verso
    // clk_tdc, esteso a 8 cicli; azzera anche lo sticky di overflow
    // ------------------------------------------------------------------
    reg fifo_rst_tgl = 1'b0;
    (* ASYNC_REG = "true" *) reg rst_tgl_m, rst_tgl_s;
    reg rst_tgl_d;
    reg [2:0] rst_stretch = 3'd0;
    wire fifo_rst_tdc = |rst_stretch;
    always @(posedge clk_tdc) begin
        rst_tgl_m <= fifo_rst_tgl;
        rst_tgl_s <= rst_tgl_m;
        rst_tgl_d <= rst_tgl_s;
        if (rst_tgl_s ^ rst_tgl_d)      rst_stretch <= 3'd7;
        else if (rst_stretch != 3'd0)   rst_stretch <= rst_stretch - 1;
    end

    // ------------------------------------------------------------------
    // FIFO asincrona 64 bit clk_tdc -> aclk (XPM)
    // ------------------------------------------------------------------
    wire [63:0] fifo_din = {seq_cnt, 2'b00, st_coarse, st_fine};
    wire [63:0] fifo_dout;
    wire fifo_full, fifo_empty, fifo_wr_rst_busy, fifo_rd_rst_busy;
    reg  fifo_rd_en;
    wire [9:0] fifo_rd_count;

    xpm_fifo_async #(
        .FIFO_WRITE_DEPTH (512),
        .WRITE_DATA_WIDTH (64),
        .READ_DATA_WIDTH  (64),
        .READ_MODE        ("fwft"),
        .FIFO_READ_LATENCY(0),
        .RD_DATA_COUNT_WIDTH(10),
        .WR_DATA_COUNT_WIDTH(10),
        .CDC_SYNC_STAGES  (3),
        .USE_ADV_FEATURES ("0400")   // solo rd_data_count
    ) u_fifo (
        .rst           (fifo_rst_tdc),
        .wr_clk        (clk_tdc),
        .wr_en         (st_valid & ~fifo_full & ~fifo_wr_rst_busy),
        .din           (fifo_din),
        .full          (fifo_full),
        .rd_clk        (s_axi_aclk),
        .rd_en         (fifo_rd_en & ~fifo_rd_rst_busy),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .rd_data_count (fifo_rd_count),
        .wr_rst_busy   (fifo_wr_rst_busy),
        .rd_rst_busy   (fifo_rd_rst_busy),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );

    // overflow sticky (dominio tdc -> sync ad aclk); si azzera col fifo_reset
    reg ovfl_tdc = 1'b0;
    always @(posedge clk_tdc)
        if (fifo_rst_tdc)             ovfl_tdc <= 1'b0;
        else if (st_valid & fifo_full) ovfl_tdc <= 1'b1;
    (* ASYNC_REG = "true" *) reg ovfl_m, ovfl_a;
    always @(posedge s_axi_aclk) begin ovfl_m <= ovfl_tdc; ovfl_a <= ovfl_m; end

    (* ASYNC_REG = "true" *) reg lock_m, lock_a;
    always @(posedge s_axi_aclk) begin lock_m <= mmcm_locked; lock_a <= lock_m; end

    // ------------------------------------------------------------------
    // AXI-lite
    // ------------------------------------------------------------------
    localparam [4:0] CSR_OFF  = 5'h00, STAT_OFF = 5'h04, TSLO_OFF = 5'h08,
                     TSHI_OFF = 5'h0C, TAPS_OFF = 5'h10, CLKF_OFF = 5'h14,
                     HITS_OFF = 5'h18;

    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r;
    reg aw_pend, w_pend;
    reg [31:0] wdata_r;
    reg [31:0] ts_hi_hold;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0;
            aw_pend <= 0; w_pend <= 0;
            csr_enable <= 0; csr_sel <= 0; sw_line <= 0;
        end else begin
            if (s_axi_awvalid && !s_axi_awready) begin
                s_axi_awready <= 1; awaddr_r <= s_axi_awaddr; aw_pend <= 1;
            end else s_axi_awready <= 0;
            if (s_axi_wvalid && !s_axi_wready) begin
                s_axi_wready <= 1; wdata_r <= s_axi_wdata; w_pend <= 1;
            end else s_axi_wready <= 0;
            if (aw_pend && w_pend) begin
                aw_pend <= 0; w_pend <= 0; s_axi_bvalid <= 1;
                if (awaddr_r[4:0] == CSR_OFF) begin
                    csr_enable <= wdata_r[0];
                    csr_sel    <= wdata_r[2:1];
                    if (wdata_r[3]) fifo_rst_tgl <= ~fifo_rst_tgl;
                    if (wdata_r[4]) sw_line <= ~sw_line;
                end
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0; fifo_rd_en <= 0;
        end else begin
            fifo_rd_en <= 0;
            if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
                s_axi_arready <= 1;
                s_axi_rvalid  <= 1;
                case (s_axi_araddr[4:0])
                    CSR_OFF:  s_axi_rdata <= {27'd0, sw_line, 1'b0, csr_sel, csr_enable};
                    STAT_OFF: s_axi_rdata <= {6'd0, fifo_rd_count, 13'd0,
                                              ovfl_a, fifo_empty, lock_a};
                    TSLO_OFF: begin
                        // pop + congela la meta' alta dello stesso stamp
                        s_axi_rdata <= {fifo_dout[31:10], fifo_dout[9:0]};
                        ts_hi_hold  <= {fifo_dout[63:56], 2'b00, fifo_dout[53:32]};
                        if (!fifo_empty) fifo_rd_en <= 1;
                    end
                    TSHI_OFF: s_axi_rdata <= ts_hi_hold;
                    TAPS_OFF: s_axi_rdata <= NT;
                    CLKF_OFF: s_axi_rdata <= TDC_CLK_HZ;
                    HITS_OFF: s_axi_rdata <= hit_cnt_a;
                    default:  s_axi_rdata <= 32'hDEAD_7DC0;
                endcase
            end else
                s_axi_arready <= 0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
        end
    end

endmodule
