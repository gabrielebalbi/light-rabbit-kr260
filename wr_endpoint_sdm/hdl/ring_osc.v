`timescale 1ns/1ps

// Ring oscillator gate-abilitabile per la calibrazione del TDC (code-density
// test). Nessun PLL/riferimento: la frequenza dipende solo dal ritardo delle
// LUT e del routing (temperatura/tensione) -> genuinamente incommensurabile
// con qualunque clock derivato da PLL della scheda, con jitter termico reale.
// E' la sostituzione della vecchia sorgente "cal" (divisore di s_axi_aclk):
// quella, essendo periodica e derivata dallo stesso albero di riferimento
// della scheda, dava un istogramma di calibrazione concentrato invece che
// uniforme (visto su hardware il 20/7/2026).
//
// Primitive esplicite (non RTL comportamentale): un LUT2 configurato a NAND
// come primo stadio (funge da inverter quando en=1, tiene il ring fermo a
// en=0) + un numero PARI di LUT1 invertitori -> totale stadi DISPARI, oscilla
// quando abilitato. DONT_TOUCH/KEEP su ogni stadio perche' altrimenti la
// synth ottimizzerebbe via l'anello (nessun carico "utile" visibile).
module ring_osc #(
    parameter integer NUM_INV = 30   // pari: NAND + NUM_INV = stadi dispari
) (
    input  wire en,
    output wire osc_o
);
    (* DONT_TOUCH = "true", KEEP = "true" *) wire [NUM_INV:0] stage;

    (* DONT_TOUCH = "true", KEEP = "true" *)
    LUT2 #(.INIT(4'h7)) u_nand (        // O = ~(I0 & I1)
        .I0(stage[NUM_INV]),
        .I1(en),
        .O (stage[0])
    );

    genvar g;
    generate
        for (g = 0; g < NUM_INV; g = g + 1) begin : g_inv
            (* DONT_TOUCH = "true", KEEP = "true" *)
            LUT1 #(.INIT(2'h1)) u_inv (  // O = ~I0
                .I0(stage[g]),
                .O (stage[g+1])
            );
        end
    endgenerate

    assign osc_o = stage[NUM_INV];

endmodule
