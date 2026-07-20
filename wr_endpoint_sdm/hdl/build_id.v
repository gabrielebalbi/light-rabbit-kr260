`timescale 1ns/1ps

// Registri di identificazione della build (v16): git hash del gateware e del
// software (wrpc-sw) embedded in wrc.bram, piu' timestamp e flag.
// I parametri sono sovrascritti a ogni build da rebuild_v16.tcl (legge git);
// i default 0xDEADxxxx segnalano una build fatta senza hook. Sono spezzati in
// mezze parole da 16 bit perche' il wrapper VHDL del BD li converte in integer
// (con segno, 32 bit): un hash con MSB=1 sforerebbe il massimo rappresentabile.
//
// Register map (AXI4-Lite, offset da base 0xA0050000):
//   0x00  FW_GITHASH  r/o  primi 8 esadecimali dell'hash del repo gateware
//   0x04  SW_GITHASH  r/o  primi 8 esadecimali dell'hash di wrpc-sw (wrc.bram)
//   0x08  BUILD_TS    r/o  unix time della synth
//   0x0C  FLAGS       r/o  [31:24] versione fw (16) | [1] sw_dirty | [0] fw_dirty
//                          dirty = repo con modifiche non committate al build:
//                          l'hash NON identifica esattamente cio' che gira
module build_id #(
    parameter [15:0] FW_HASH_HI = 16'hDEAD, parameter [15:0] FW_HASH_LO = 16'h0001,
    parameter [15:0] SW_HASH_HI = 16'hDEAD, parameter [15:0] SW_HASH_LO = 16'h0002,
    parameter [15:0] TS_HI      = 16'h0,    parameter [15:0] TS_LO      = 16'h0,
    parameter [15:0] FLAGS_HI   = 16'h1000, parameter [15:0] FLAGS_LO   = 16'h0003,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 8
) (
    input  wire                               s_axi_aclk,
    input  wire                               s_axi_aresetn,
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

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // Scritture: accettate e ignorate (registri di sola lettura)
    reg aw_pend, w_pend;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0;
            aw_pend <= 0; w_pend <= 0;
        end else begin
            if (s_axi_awvalid && !s_axi_awready) begin
                s_axi_awready <= 1; aw_pend <= 1;
            end else s_axi_awready <= 0;
            if (s_axi_wvalid && !s_axi_wready) begin
                s_axi_wready <= 1; w_pend <= 1;
            end else s_axi_wready <= 0;
            if (aw_pend && w_pend) begin
                aw_pend <= 0; w_pend <= 0; s_axi_bvalid <= 1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0;
        end else begin
            if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
                s_axi_arready <= 1;
                case (s_axi_araddr[3:2])
                    2'd0: s_axi_rdata <= {FW_HASH_HI, FW_HASH_LO};
                    2'd1: s_axi_rdata <= {SW_HASH_HI, SW_HASH_LO};
                    2'd2: s_axi_rdata <= {TS_HI, TS_LO};
                    2'd3: s_axi_rdata <= {FLAGS_HI, FLAGS_LO};
                endcase
                s_axi_rvalid <= 1;
            end else
                s_axi_arready <= 0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
        end
    end

endmodule
