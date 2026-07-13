`timescale 1ns/1ps

// Frequency counter: conta spigoli di meas_clk in una finestra di GATE_CYCLES cicli
// di s_axi_aclk (= pl_clk0, ~100 MHz). Free-running: misura → pausa → misura → ...
//
// Register map (AXI4-Lite, offset da base):
//   0x00  GATE_CYCLES  r/w  finestra in cicli aclk (default 100_000_000 = 1s @100MHz)
//   0x04  FREQ_CNT     r/o  spigoli meas_clk nell'ultima finestra
//   0x08  STATUS       r/o  bit[0]: 1 = nuovo risultato disponibile (si azzera su lettura STATUS)
//
// CDC: toggle-synchronizer da meas_clk → s_axi_aclk; aggiungere al XDC:
//   set_false_path -from [get_cells -hier -filter {NAME=~*meas_cnt_latch_reg*}] \
//                  -to   [get_cells -hier -filter {NAME=~*freq_count_reg*}]
module freq_counter #(
    parameter integer C_S_AXI_DATA_WIDTH  = 32,
    parameter integer C_S_AXI_ADDR_WIDTH  = 8,
    parameter integer DEFAULT_GATE_CYCLES = 100_000_000
) (
    input  wire meas_clk,
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

    localparam [3:0] GATE_OFF = 4'h0, CNT_OFF = 4'h4, STAT_OFF = 4'h8;
    localparam integer PAUSE_CYCLES = 16; // pausa tra misure: 160 ns @100 MHz > latenza sync

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // ---------------------------------------------------------------
    // Registri AXI (s_axi_aclk domain)
    // ---------------------------------------------------------------
    reg [31:0] gate_cycles;
    reg [31:0] freq_count;
    reg        new_result;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r;
    reg aw_pend, w_pend;

    // Scrittura AXI
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0;
            aw_pend <= 0; w_pend <= 0;
            gate_cycles <= DEFAULT_GATE_CYCLES;
        end else begin
            if (s_axi_awvalid && !s_axi_awready) begin
                s_axi_awready <= 1; awaddr_r <= s_axi_awaddr; aw_pend <= 1;
            end else s_axi_awready <= 0;
            if (s_axi_wvalid && !s_axi_wready) begin
                s_axi_wready <= 1; w_pend <= 1;
            end else s_axi_wready <= 0;
            if (aw_pend && w_pend) begin
                aw_pend <= 0; w_pend <= 0; s_axi_bvalid <= 1;
                if (awaddr_r[3:0] == GATE_OFF) gate_cycles <= s_axi_wdata;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
        end
    end

    // Lettura AXI + gestione new_result
    wire stat_read = s_axi_arvalid && !s_axi_arready && (s_axi_araddr[3:0] == STAT_OFF);

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rdata <= 0;
            freq_count <= 0; new_result <= 0;
        end else begin
            // Aggiorna risultato da CDC (priorità più alta)
            if (result_pulse_ref) begin
                freq_count <= meas_cnt_latch;
                new_result <= 1;
            end else if (stat_read) begin
                new_result <= 0;
            end
            // AXI read
            if (s_axi_arvalid && !s_axi_arready) begin
                s_axi_arready <= 1; s_axi_rvalid <= 1;
                case (s_axi_araddr[3:0])
                    GATE_OFF: s_axi_rdata <= gate_cycles;
                    CNT_OFF:  s_axi_rdata <= freq_count;
                    STAT_OFF: s_axi_rdata <= {31'b0, new_result};
                    default:  s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end else begin
                s_axi_arready <= 0;
                if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            end
        end
    end

    // ---------------------------------------------------------------
    // Generazione gate free-running (s_axi_aclk domain)
    // Stato MEASURE: gate_en=1 per gate_cycles cicli
    // Stato PAUSE:   gate_en=0 per PAUSE_CYCLES cicli (stabile per sync)
    // ---------------------------------------------------------------
    reg [31:0] ref_cnt;
    reg        gate_en;
    reg        in_pause;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            ref_cnt  <= PAUSE_CYCLES;
            gate_en  <= 1'b0;
            in_pause <= 1'b1;
        end else begin
            if (ref_cnt == 32'd1) begin
                // Transizione: in_pause corrente usato prima dell'assegnazione (non-blocking)
                in_pause <= ~in_pause;
                gate_en  <= in_pause;                                 // se era in pausa → ora misura
                ref_cnt  <= in_pause ? gate_cycles : PAUSE_CYCLES;    // se era in pausa → durata misura
            end else begin
                ref_cnt <= ref_cnt - 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Sync gate_en → meas_clk (2-FF)
    // ---------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] gate_en_meas_sync;
    wire gate_en_meas = gate_en_meas_sync[1];

    always @(posedge meas_clk)
        gate_en_meas_sync <= {gate_en_meas_sync[0], gate_en};

    // ---------------------------------------------------------------
    // Contatore misura (meas_clk domain)
    // ---------------------------------------------------------------
    reg [31:0] meas_cnt;
    reg [31:0] meas_cnt_latch;   // stabile dopo gate_en_meas falling edge
    reg        gate_prev;
    reg        result_toggle;    // toggles ad ogni nuovo meas_cnt_latch

    always @(posedge meas_clk) begin
        gate_prev <= gate_en_meas;
        meas_cnt  <= gate_en_meas ? (meas_cnt + 1) : 32'd0;
        // Cattura sul fronte di discesa di gate_en_meas
        if (gate_prev && !gate_en_meas) begin
            meas_cnt_latch <= meas_cnt;
            result_toggle  <= ~result_toggle;
        end
    end

    // ---------------------------------------------------------------
    // Sync result_toggle → s_axi_aclk; genera pulse per cattura
    // meas_cnt_latch è stabile quando result_pulse_ref sale:
    //   set_false_path dal latch al registro freq_count (vedi XDC)
    // ---------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] tog_ref_sync;
    reg tog_ref_prev;
    wire result_pulse_ref = tog_ref_sync[1] ^ tog_ref_prev;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            tog_ref_sync <= 2'b00; tog_ref_prev <= 1'b0;
        end else begin
            tog_ref_sync <= {tog_ref_sync[0], result_toggle};
            tog_ref_prev <= tog_ref_sync[1];
        end
    end

endmodule
