`timescale 1ns/1ps

// Linea di ritardo a catena di carry (CARRY8, UltraScale+) per TDC.
// Il segnale entra dal CI del primo CARRY8 e si propaga verso l'alto in modalita'
// propagate (S=FF, DI=00). UN SOLO rank di FF (ASYNC_REG) + popcount pipelinato
// bubble-tolerant: fine_o = numero di tap raggiunti dal fronte, rispetto al
// fronte di clk che campiona.
//
// ⚠️ POLARITA' (bug trovato il 21/7/2026 via simulazione xsim, NON su
// hardware — vedi sim/tb_polarity.v, sim/tb_delayline{2,3,4}.v): il modello
// ufficiale Xilinx di CARRY8 (unisims/CARRY8.v) fa `O = S_in ^ CO_fb`; con
// S=8'hFF (propagate costante) questo da' **O[i] = NOT(CI)**, non O[i]=CI
// come assunto nella prima stesura. A riposo la catena leggeva TUTTO A 1
// (fine=NT, non 0!), durante un hit sostenuto TUTTO A 0 — e la rivelazione
// del fronte (salita di therm_r1[0]) scattava sulla DISCESA dell'ingresso
// vero, non sulla salita. Risultato pratico: ogni campione fotografava uno
// stato gia' assestato invece di un fronte a meta' propagazione — combacia
// con `fine=768` su TUTTI i campioni del test PPS del 21/7 (non era rumore).
// **Fix**: si inverte `tap` al momento della cattura (`therm_r1 <= ~tap`),
// cosi' tutto il resto (popcount, edge-detect su therm_r1[0]) torna a
// funzionare con la semantica originaria (0=riposo, 1=fronte arrivato) senza
// toccare nient'altro.
// NB: due ipotesi precedenti (sorgente di calibrazione non incommensurabile;
// doppio stadio di registrazione) sono state provate e SMENTITE sul ferro —
// non c'entravano. Questo fix di polarita' e' una correzione logica vera,
// ma il modello unisim ha ritardo ZERO dichiarato su ogni tap: la sim NON
// dice se la catena reale e' troppo veloce rispetto al periodo di
// campionamento (2.667 ns) — quello va verificato di nuovo sul ferro.
//
// La catena si piazza da sola in colonna (CO->CI dedicato); DONT_TOUCH evita
// che la synth la ottimizzi via.
module tdc_delayline #(
    parameter integer N_C8 = 96              // 96 CARRY8 = 768 tap (~3.2 ns @~4.2ps)
) (
    input  wire                    clk_i,     // clock veloce TDC
    input  wire                    hit_i,     // ingresso asincrono da timestampare
    input  wire [43:0]             coarse_i,  // contatore coarse (dominio clk_i)
    output reg                     stamp_valid_o,  // 1 ciclo: fine/coarse validi
    output reg  [10:0]             fine_o,         // popcount dei tap (0..N_C8*8); 11 bit -> N_C8 fino a 255
    output reg  [43:0]             coarse_o        // coarse al ciclo di cattura
);
    localparam integer NT = N_C8*8;

    // --- catena di carry ------------------------------------------------
    (* DONT_TOUCH = "true" *) wire [NT-1:0] tap;
    (* DONT_TOUCH = "true" *) wire [NT-1:0] chain_co;

    genvar g;
    generate
        for (g = 0; g < N_C8; g = g + 1) begin : g_chain
            CARRY8 #(.CARRY_TYPE("SINGLE_CY8")) u_c8 (
                .CI     (g == 0 ? hit_i : chain_co[g*8-1]),
                .CI_TOP (1'b0),
                .DI     (8'h00),
                .S      (8'hFF),
                .O      (tap[g*8 +: 8]),
                .CO     (chain_co[g*8 +: 8])
            );
        end
    endgenerate

    // --- singolo rank di cattura, diretto sul vettore grezzo -------------
    // invertito: CARRY8 in propagate da' O=NOT(CI), qui si torna alla
    // semantica 0=riposo/1=fronte-arrivato (vedi nota di polarita' sopra)
    (* ASYNC_REG = "true", DONT_TOUCH = "true" *) reg [NT-1:0] therm_r1;
    always @(posedge clk_i) begin
        therm_r1 <= ~tap;
    end

    // --- rivelazione del fronte -----------------------------------------
    reg        tap0_d;
    reg        hit_ev;        // nuovo fronte visto in questo campione
    reg [43:0] coarse_ev;
    always @(posedge clk_i) begin
        tap0_d    <= therm_r1[0];
        hit_ev    <= therm_r1[0] & ~tap0_d;
        coarse_ev <= coarse_i;
    end

    // --- popcount pipelinato (3 stadi), coarse/valid in parallelo -------
    // stadio 1: 8 bit -> nibble per ogni CARRY8
    integer i;
    reg [3:0] pc1 [0:N_C8-1];
    reg        v1;   reg [43:0] c1;
    always @(posedge clk_i) begin
        for (i = 0; i < N_C8; i = i + 1)
            pc1[i] <= therm_r1[i*8]   + therm_r1[i*8+1] + therm_r1[i*8+2] + therm_r1[i*8+3]
                    + therm_r1[i*8+4] + therm_r1[i*8+5] + therm_r1[i*8+6] + therm_r1[i*8+7];
        v1 <= hit_ev;  c1 <= coarse_ev;
    end

    // stadio 2: somma a gruppi di 8 nibble (N_C8/8 somme parziali, <=64 -> 7 bit)
    localparam integer NG = N_C8/8;
    reg [6:0] pc2 [0:NG-1];
    reg        v2;   reg [43:0] c2;
    integer j;
    always @(posedge clk_i) begin
        for (j = 0; j < NG; j = j + 1)
            pc2[j] <= pc1[j*8]   + pc1[j*8+1] + pc1[j*8+2] + pc1[j*8+3]
                    + pc1[j*8+4] + pc1[j*8+5] + pc1[j*8+6] + pc1[j*8+7];
        v2 <= v1;  c2 <= c1;
    end

    // stadio 3: somma finale (NG termini)
    reg [10:0] sum3;
    integer k;
    always @(*) begin
        sum3 = 10'd0;
        for (k = 0; k < NG; k = k + 1)
            sum3 = sum3 + pc2[k];
    end
    always @(posedge clk_i) begin
        fine_o        <= sum3;
        coarse_o      <= c2;
        stamp_valid_o <= v2;
    end

endmodule
