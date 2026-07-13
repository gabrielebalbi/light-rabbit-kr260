`timescale 1ns/1ps

// AXI4-Lite slave → DRP master bridge
// Register map (matches drp.py offsets):
//   0x00  ADDR  r/w  DRP address [9:0]
//   0x04  DI    r/w  DRP data-in [15:0]
//   0x08  DO    r/o  DRP data-out [15:0]
//   0x0C  EN    r/w  write 1 to start transaction (auto-clears); clears RDY
//   0x10  WE    r/w  DRP write-enable (1=write, 0=read)
//   0x14  RDY   r/o  1 when transaction complete
module axi_drp_bridge #(
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
    input  wire                               s_axi_rready,
    // DRP master
    output wire        drpclk,
    output reg  [9:0]  drpaddr,
    output reg  [15:0] drpdi,
    input  wire [15:0] drpdo,
    output reg         drpen,
    output reg         drpwe,
    input  wire        drprdy
);
    localparam [5:0] ADDR_OFF=6'h00, DI_OFF=6'h04, DO_OFF=6'h08,
                     EN_OFF=6'h0C,   WE_OFF=6'h10,  RDY_OFF=6'h14;
    localparam [1:0] ST_IDLE=0, ST_PULSE=1, ST_WAIT=2;

    assign drpclk      = s_axi_aclk;
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    reg [9:0]  addr_r;
    reg [15:0] di_r, do_r;
    reg        we_r, rdy_r, en_trig;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r;
    reg aw_pend, w_pend;

    // Write channel
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready<=0; s_axi_wready<=0; s_axi_bvalid<=0;
            aw_pend<=0; w_pend<=0; en_trig<=0;
            addr_r<=0; di_r<=0; we_r<=0;
        end else begin
            en_trig <= 0;
            if (s_axi_awvalid && !s_axi_awready) begin
                s_axi_awready<=1; awaddr_r<=s_axi_awaddr; aw_pend<=1;
            end else s_axi_awready<=0;
            if (s_axi_wvalid && !s_axi_wready) begin
                s_axi_wready<=1; w_pend<=1;
            end else s_axi_wready<=0;
            if (aw_pend && w_pend) begin
                aw_pend<=0; w_pend<=0; s_axi_bvalid<=1;
                case (awaddr_r[5:0])
                    ADDR_OFF: addr_r <= s_axi_wdata[9:0];
                    DI_OFF:   di_r   <= s_axi_wdata[15:0];
                    WE_OFF:   we_r   <= s_axi_wdata[0];
                    // EN write: just pulse en_trig; rdy_r cleared in DRP SM
                    EN_OFF:   if (s_axi_wdata[0]) en_trig <= 1;
                    default: ;
                endcase
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
        end
    end

    // Read channel
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready<=0; s_axi_rvalid<=0; s_axi_rdata<=0;
        end else begin
            if (s_axi_arvalid && !s_axi_arready) begin
                s_axi_arready<=1; s_axi_rvalid<=1;
                case (s_axi_araddr[5:0])
                    ADDR_OFF: s_axi_rdata <= {22'b0, addr_r};
                    DI_OFF:   s_axi_rdata <= {16'b0, di_r};
                    DO_OFF:   s_axi_rdata <= {16'b0, do_r};
                    EN_OFF:   s_axi_rdata <= 32'b0;
                    WE_OFF:   s_axi_rdata <= {31'b0, we_r};
                    RDY_OFF:  s_axi_rdata <= {31'b0, rdy_r};
                    default:  s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end else begin
                s_axi_arready<=0;
                if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            end
        end
    end

    // DRP state machine — sole owner of rdy_r
    reg [1:0] state;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            drpen<=0; drpwe<=0; drpaddr<=0; drpdi<=0;
            do_r<=0; rdy_r<=0; state<=ST_IDLE;
        end else begin
            drpen <= 0;
            case (state)
                ST_IDLE:  if (en_trig) begin
                              drpaddr<=addr_r; drpdi<=di_r; drpwe<=we_r;
                              rdy_r<=0;   // clear RDY on new transaction
                              state<=ST_PULSE;
                          end
                ST_PULSE: begin drpen<=1; state<=ST_WAIT; end
                ST_WAIT:  if (drprdy) begin do_r<=drpdo; rdy_r<=1; state<=ST_IDLE; end
                default:  state<=ST_IDLE;
            endcase
        end
    end
endmodule
