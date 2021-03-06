/*
*
* Copyright (c) 2011-2012 fpgaminer@bitcoin-mining.com
*
*
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
* 
*/


// Provides a JTAG interface for reading and writing hashing data and other
// configuration options.
//
// Access is performed through the JTAG USER1 register.
//
// ----------------------------------------------------------------------------
// To Read a Register:
// First, write the following bits to USER1: C0AAAA
// Where AAAA is a 4-bit register address.
// Where C is a 1-bit checksum (1^C^A^A^A^A)
//
// Now read back 32-bits from USER1.
//
// NOTE: When reading back from USER1, you can write all 0s on JDI to cause
// a checksum fail, and thus cause no changes. However, if you'd like to read
// several registers consecutively, you may make another read request instead.
//
// ----------------------------------------------------------------------------
// To Write a Register:
// Write the following bits to USER1: C1AAAADDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
// Where AAAA is a 4-bit register address.
// Where C is a 1-bit checksum (1^C^1^A^A^A^A^(D*))
//
// You may read back 32-bits from USER1 to double check that the value was
// correctly written.
//
// ----------------------------------------------------------------------------
// To set the Hashing Clock Frequency:
// Register 0xD lets you set the desired frequency in MHZ.
// Maximum frequency is defined by MAXIMUM_FREQUENCY.
//
//
// ----------------------------------------------------------------------------
// NOTE: Writing to 0xB will cause midstate+data to latch to the mining core.
// So, when you're writing a new job, make sure that's the last thing you
// write.
//
// NOTE: On the controller side of things, it would be best to keep track of
// a history of at least one midstate+data. When a Golden Nonce is read, it
// may belong to an older midstate+data. Simply perform a SHA256 hash on the
// controller side to see which data a Golden Nonce belongs to.
//
// NOTE: There is a 127 entry FIFO to buffer Golden Nonces.
//
// NOTE: When reading the Golden Nonce register, 0xFFFFFFFF is used to
// indicate that there is no new Golden Nonce. Because of this, if a Golden
// Nonce is actually 0xFFFFFFFF it will be ignored. This should only cause
// a loss of 1 in 2**32 Golden Nonces though, so it is not a critical problem.
//
//
// ----------------------------------------------------------------------------
// -------- Register Map --------
// 0x0:		Interface/Firmware Version
// 0x1:		midstate[31:0]
// 0x2:		midstate[63:32]
// 0x3:		midstate[95:64]
// 0x4:		midstate[127:96]
// 0x5:		midstate[159:128]
// 0x6:		midstate[191:160]
// 0x7:		midstate[223:192]
// 0x8:		midstate[255:224]
// 0x9:		data[31:0]
// 0xA:		data[63:32]
// 0xB:		data[95:64]; Writing here also causes midstate+data to latch.
// 0xC:		--
// 0xD:		Clock Configuration (speed in MHz)
// 0xE:		Golden Nonce
// 0xF:		--

// TODO: Perhaps we should calculate a checksum for returned data?
module jtag_comm # (
	parameter INPUT_FREQUENCY = 100,
	parameter MAXIMUM_FREQUENCY = 200,
	parameter INITIAL_FREQUENCY = 50
) (
	input rx_hash_clk,
	input rx_new_nonce,
	input [31:0] rx_golden_nonce,
	output reg tx_new_work = 1'b0,
	output reg [255:0] tx_midstate = 256'd0,
	output reg [95:0] tx_data = 96'd0,

	input rx_dcm_progclk,
	output reg tx_dcm_progdata,
	output reg tx_dcm_progen,
	input rx_dcm_progdone
);

	// Configuration data
`ifndef SIM
	reg [351:0] current_job = 352'd0;
`else
	// Genesis block
	reg [351:0] current_job = { 96'hffff001e11f35052d554469e, 256'h3171e6831d493f45254964259bc31bade1b5bb1ae3c327bc54073d19f0ea633b };
`endif	
	reg [255:0] midstate = 256'd0;
	reg [95:0] data = 96'd0;
	reg new_work_flag = 1'b0;
	reg [31:0] clock_config = INITIAL_FREQUENCY;

	// JTAG
	wire jt_capture, jt_drck, jt_reset, jt_sel, jt_shift, jt_tck, jt_tdi, jt_update;
	wire jt_tdo;

`ifndef SIM
	BSCAN_SPARTAN6 # (.JTAG_CHAIN(1)) jtag_blk (
		.CAPTURE(jt_capture),
		.DRCK(jt_drck),
		.RESET(jt_reset),
		.RUNTEST(),
		.SEL(jt_sel),
		.SHIFT(jt_shift),
		.TCK(jt_tck),
		.TDI(jt_tdi),
		.TDO(jt_tdo),
		.TMS(),
		.UPDATE(jt_update)
	);
`else
	// Test harness - not ideal to have it here, but we need to drive the jtag signals
	// which are not in the module I/O list
	reg [2:0] cnt_jt_clk = 0;
	reg [15:0] jt_cycle = 0;			// Test sequencer
	always @ (posedge rx_hash_clk)
		cnt_jt_clk <= cnt_jt_clk + 1;
	assign jt_tck = cnt_jt_clk[2];		// Clocks at 1/4 speed of rx_hash_clk

	reg rjt_capture = 1'b0;
	reg rjt_drck = 1'b0;
	reg rjt_reset = 1'b0;
	reg rjt_sel = 1'b0;
	reg rjt_shift = 1'b0;
	reg rjt_tdi = 1'b0;
	reg rjt_tdo = 1'b0;
	reg rjt_update = 1'b0;
	
	always @ (posedge jt_tck)
	begin
		jt_cycle <= jt_cycle + 1;
		case (jt_cycle)
		// Reset
		1 : rjt_reset <= 1;
		2 : rjt_reset <= 0;
		
		// NB There ought to be a jt_capture operation before the initial shift as the TAP controller
		// sequence is "jt_capture, jt_shift, jt_update" 
		
		// Shift in 38 bits 0e00000000 for C=0 W=0 A=E Data=00000000
		// ALTERNATIVELY C=0 WR=0 A=E Data=80000000 confirm it is ignored in checksum for read
		3 : begin
			rjt_sel <= 1;
			rjt_shift <= 1;
			rjt_tdi <= 0;
			end

		// Comment or uncomment the next two lines to set Data=00000000 or Data=80000000 (the ALTERNATIVE test above)
		34 : rjt_tdi <= 1;			// Uncomment to generate invalid checksum in original version by setting MSB of data
		35 : rjt_tdi <= 0;			// (this is ignored the fixed version as only 6 bits are used for the read checksum)

		36 : rjt_tdi <= 1;
		39 : rjt_tdi <= 0;
		41 : begin
			rjt_sel <= 0;
			rjt_shift <= 0;
			end
		43 : begin
			rjt_sel <= 1;			// OK to hold this for one or more cycles
			rjt_update <= 1;
			end
		44 : begin
			rjt_sel <= 0;
			rjt_update <= 0;
			end
		47 : begin
			rjt_sel <= 1;			// NB This operation must be for ONE cycle only (else dr is overwritten with FFFFFFFF)
			rjt_capture <= 1;
			end
		48 : begin
			rjt_sel <= 0;
			rjt_capture <= 0;
			end

		// And repeat to capture a second golden nonce. This is carefully timed in hashcore.v to either
		// fall within the capture window, or before/after it
		// Shift in 38 bits 0e00000000 for C=0 W=0 A=E Data=00000000 (shifting out the golden nonce)
		53: begin
			rjt_sel <= 1;
			rjt_shift <= 1;
			end
		86 : rjt_tdi <= 1;
		89 : rjt_tdi <= 0;
		91 : begin
			// rjt_tdi <= 0;
			rjt_sel <= 0;
			rjt_shift <= 0;
			end
		93 : begin
			rjt_sel <= 1;			// OK to hold this for one or more cycles
			rjt_update <= 1;
			end
		94 : begin
			rjt_sel <= 0;
			rjt_update <= 0;
			end
		97 : begin
			rjt_sel <= 1;			// NB This operation must be for ONE cycle only (else dr is overwritten with FFFFFFFF)
			rjt_capture <= 1;
			end
		98 : begin
			rjt_sel <= 0;
			rjt_capture <= 0;
			end

		// Test writing to clock_config and reading it back.
		// Confirm the bug in the original version using 6 bit read command and clock_config between 64MHz and 191MHz

`define TEST64		// Comment or uncomment to select test mode

`ifndef TEST64
		// Shift in 38 bits 3d0000003F for C=1 W=1 A=D Data=0000003F (63MHz)
		103 : begin
			rjt_sel <= 1;
			rjt_shift <= 1;
			rjt_tdi <= 1;
			end

		109 : rjt_tdi <= 0;
		135 : rjt_tdi <= 1;
		136 : rjt_tdi <= 0;
		137 : rjt_tdi <= 1;
`else
		// ALTERNATIVELY Shift in 1d00000040 for C=0 W=1 A=D Data=00000040 (64MHz) which tests read bug
		103 : begin
			rjt_sel <= 1;
			rjt_shift <= 1;
			rjt_tdi <= 0;
			end

		109 : rjt_tdi <= 1;
		110 : rjt_tdi <= 0;
		135 : rjt_tdi <= 1;
		136 : rjt_tdi <= 0;
		137 : rjt_tdi <= 1;
		140 : rjt_tdi <= 0;
`endif	
		141 : begin
			rjt_sel <= 0;
			rjt_shift <= 0;
			rjt_tdi <= 0;
			end
		143 : begin
			rjt_sel <= 1;			// OK to hold this for one or more cycles
			rjt_update <= 1;
			end
		144 : begin
			rjt_sel <= 0;
			rjt_update <= 0;
			end
		147 : begin
			rjt_sel <= 1;			// NB This operation must be for ONE cycle only (else dr is overwritten with FFFFFFFF)
			rjt_capture <= 1;
			end
		// We capture 000000003F which is the value previously written
		148 : begin
			rjt_sel <= 0;
			rjt_capture <= 0;
			end

		// Shift in 6 bits 0d for C=0 W=0 A=D
		153: begin
			rjt_sel <= 1;
			rjt_shift <= 1;
			rjt_tdi <= 1;
			end
		
		154 : rjt_tdi <= 0;
		155 : rjt_tdi <= 1;
		157 : rjt_tdi <= 0;
		159 : begin
			rjt_sel <= 0;
			rjt_shift <= 0;
			end
		162 : begin
			rjt_sel <= 1;			// OK to hold this for one or more cycles
			rjt_update <= 1;
			end
		163 : begin
			rjt_sel <= 0;
			rjt_update <= 0;
			end
		165 : begin
			rjt_sel <= 1;			// NB This operation must be for ONE cycle only (else dr is overwritten with FFFFFFFF)
			rjt_capture <= 1;
			end
		166 : begin
			rjt_sel <= 0;
			rjt_capture <= 0;
			end

		// Shift out result
		168: begin
			rjt_sel <= 1;
			rjt_shift <= 1;
			end

		endcase

		
	end
	
	assign jt_capture = rjt_capture;
	assign jt_drck = rjt_drck;
	assign jt_reset = rjt_reset;
	assign jt_sel = rjt_sel;
	assign jt_shift = rjt_shift;
	assign jt_tdi = rjt_tdi;
	assign jt_tdo = rjt_tdo;
	assign jt_update = rjt_update;
`endif

	reg [3:0] addr = 4'hF;
	reg fifo_data_valid = 1'b0;
	reg [37:0] dr;
	reg checksum;						// Full checksum on write
	reg rd_checksum;					// Partial checksum on read (see KRAMBLE note below)
	wire checksum_valid = ~checksum;
	wire rd_checksum_valid = ~rd_checksum;

	/*
	// Golden Nonce FIFO: from rx_hash_clk to TCK
	wire [31:0] tck_golden_nonce;
	wire fifo_empty, fifo_full;
	wire fifo_we = rx_new_nonce & (rx_golden_nonce != 32'hFFFFFFFF) & ~fifo_full;
	wire fifo_rd = checksum_valid & jt_update & ~jtag_we & (jtag_addr == 4'hE) & ~fifo_empty & ~jt_reset & jt_sel;
	wire jtag_we = dr[36];
	wire [3:0] jtag_addr = dr[35:32];

	golden_nonce_fifo rx_clk_to_tck_blk (
		.wr_clk(rx_hash_clk),
		.rd_clk(jt_tck),
		.din(rx_golden_nonce),
		.wr_en(fifo_we),
		.rd_en(fifo_rd),
		.dout(tck_golden_nonce),
		.full(fifo_full),
		.empty(fifo_empty)
	);
	*/
	
	reg [1:0] jt_tck_d = 0;
	always @ (posedge rx_dcm_progclk)	// 100Mhz
	begin
		jt_tck_d[1:0] <= { jt_tck_d[0], jt_tck };
	end
	
	`ifndef SIM
		BUFG jt_tck_inst (.I(jt_tck_d[1]), .O(jt_tck_buf));
	`else
		assign jt_tck_buf = jt_tck_d[1];
	`endif
	
	// Replace FIFO with simple latch in robust version
	reg [31:0] reg_golden_nonce = 32'hFFFFFFFF;
	reg [31:0] tck_golden_nonce = 32'hFFFFFFFF;
	reg fifo_empty = 1'b1;
	reg fifo_we = 1'b0;
	wire jtag_we = dr[36];
	wire [3:0] jtag_addr = dr[35:32];
	wire fifo_rd = rd_checksum_valid & jt_update & ~jtag_we & (jtag_addr == 4'hE) & ~fifo_empty & ~jt_reset & jt_sel;
	reg [3:0] rx_gn_flag = 4'b0;
	always @ (posedge jt_tck_buf)
	begin
		rx_gn_flag[3:1] <= rx_gn_flag[2:0];			// Clock crossing
		fifo_we <= rx_gn_flag[3] ^ rx_gn_flag[2];
		fifo_empty <= (fifo_empty & ~fifo_we) | fifo_rd;	// fifo_we just clears the empty flag
		if (fifo_rd)
			tck_golden_nonce <= reg_golden_nonce;			// since its not a real FIFO we capture on fifo_rd
	end
	always @ (posedge rx_hash_clk)
	begin
		if (rx_new_nonce)							// Assumes strobe of single clock duration
		begin
			rx_gn_flag[0] <= ~rx_gn_flag[0];		// Clock crossing (slight hazard of close matches cancelling flag)
			reg_golden_nonce <= rx_golden_nonce;	// Slight hazard of overwriting existing result across clock domains
		end
	end
	// END robust

	assign jt_tdo = dr[0];


	always @ (posedge jt_tck_buf or posedge jt_reset)
	begin
		if (jt_reset == 1'b1)
		begin
			dr <= 38'd0;
		end
		else if (jt_capture & jt_sel)
		begin
			// Capture-DR
			checksum <= 1'b1;
			rd_checksum <= 1'b1;
			dr[37:32] <= 6'd0;
			addr <= 4'hF;

			case (addr)
				4'h0: dr[31:0] <= 32'h01000100;
				4'h1: dr[31:0] <= midstate[31:0];
				4'h2: dr[31:0] <= midstate[63:32];
				4'h3: dr[31:0] <= midstate[95:64];
				4'h4: dr[31:0] <= midstate[127:96];
				4'h5: dr[31:0] <= midstate[159:128];
				4'h6: dr[31:0] <= midstate[191:160];
				4'h7: dr[31:0] <= midstate[223:192];
				4'h8: dr[31:0] <= midstate[255:224];
				4'h9: dr[31:0] <= data[31:0];
				4'hA: dr[31:0] <= data[63:32];
				4'hB: dr[31:0] <= data[95:64];
				4'hC: dr[31:0] <= 32'h55555555;
				4'hD: dr[31:0] <= clock_config;
				4'hE: begin
						dr[31:0] <= fifo_data_valid ? tck_golden_nonce : 32'hFFFFFFFF;
						fifo_data_valid <= 1'b0;
					  end
				4'hF: dr[31:0] <= 32'hFFFFFFFF;
			endcase
		end
		else if (jt_shift & jt_sel)
		begin
			dr <= {jt_tdi, dr[37:1]};
			checksum <= 1'b1^jt_tdi^dr[37]^dr[36]^dr[35]^dr[34]^dr[33]^dr[32]^dr[31]^dr[30]^dr[29]^dr[28]^dr[27]^dr[26]^dr[25]^dr[24]^dr[23]^dr[22]^dr[21]^dr[20]^dr[19]^dr[18]^dr[17]^dr[16]^dr[15]^dr[14]^dr[13]^dr[12]^dr[11]^dr[10]^dr[9]^dr[8]^dr[7]^dr[6]^dr[5]^dr[4]^dr[3]^dr[2]^dr[1];
			rd_checksum <= 1'b1^jt_tdi^dr[37]^dr[36]^dr[35]^dr[34]^dr[33];
		end
		else if (jt_update & jt_sel)
		// KRAMBLE: Added rd_checksum_valid to fix bug in readback of clock_config. This may appear superfluous
		// as the checksum is not used during jt_capture, and if reading clock_config immediately after writing
		// clock_config, it would appear that addr would be valid, but this is not the case. The TAP goes through
		// the sequence "jt_capture, jt_shift, jt_update" three times, first to write clock_config, then to set the
		// read address, then to read the user data register. The addr reg is set to F on the second jt_capture,
		// so we require the address to be valid on the second jt_update. Unfortunately if only 6 bits are shifted
		// as in the specification at the top of this file (and implemented in fpga.py), then the remaining 32 bits
		// will contain the previous C1AAAA plus the top 26 bits of the clock_config. For clock speeds between
		// 64MHZ and 191MHz, either 01 or 10 will remain in the LSB which gives an invalid checksum and addr is
		// not updated, so FFFFFFFF is read back (the default value for addr=F).
		begin
			if (~jtag_we & rd_checksum_valid)		// read mode
			begin
				addr <= jtag_addr;					// Set address for readback on next jr_capture

				// fifo_data_valid <= fifo_rd;		// Latch this since it failed in simulation (probably OK live)
				if (fifo_rd)
					fifo_data_valid <= 1'b1;
			end
			else if (jtag_we & checksum_valid)		// write mode
			begin
				addr <= jtag_addr;					// NB This permits immediate readback on next jr_capture
				
				// fifo_data_valid <= fifo_rd;		// Latch this since it failed in simulation (probably OK live)
				if (fifo_rd)
					fifo_data_valid <= 1'b1;

				// TODO: We should min/max the clock_config register
				// here to match the hard limits and resolution.
				case (jtag_addr)
					4'h1: midstate[31:0] <= dr[31:0];
					4'h2: midstate[63:32] <= dr[31:0];
					4'h3: midstate[95:64] <= dr[31:0];
					4'h4: midstate[127:96] <= dr[31:0];
					4'h5: midstate[159:128] <= dr[31:0];
					4'h6: midstate[191:160] <= dr[31:0];
					4'h7: midstate[223:192] <= dr[31:0];
					4'h8: midstate[255:224] <= dr[31:0];
					4'h9: data[31:0] <= dr[31:0];
					4'hA: data[63:32] <= dr[31:0];
					4'hB: data[95:64] <= dr[31:0];
					4'hD: clock_config <= dr[31:0];
				endcase
			end

			// Latch new work
			if (jtag_we && jtag_addr == 4'hB)
			begin
				current_job <= {dr[31:0], data[63:0], midstate};
				new_work_flag <= ~new_work_flag;
			end
		end
	end


	// Output Metastability Protection
	// This should be sufficient for the midstate and data signals,
	// because they rarely (relative to the clock) change and come
	// from a slower clock domain (rx_hash_clk is assumed to be fast).
	reg [351:0] tx_buffer = 352'd0;
	reg [2:0] tx_work_flag = 3'b0;

	always @ (posedge rx_hash_clk)
	begin
		tx_buffer <= current_job;
		{tx_data, tx_midstate} <= tx_buffer;

		tx_work_flag <= {tx_work_flag[1:0], new_work_flag};
		tx_new_work <= tx_work_flag[2] ^ tx_work_flag[1];
	end


	// DCM Frequency Synthesis Control
	// The DCM is configured with a SPI-like interface.
	// We implement a basic state machine based around a SPI cycle counter
	localparam MAXIMUM_FREQUENCY_MULTIPLIER = MAXIMUM_FREQUENCY >> 1;
	reg [7:0] dcm_multiplier = INITIAL_FREQUENCY >> 1, current_dcm_multiplier = 8'd0;
	reg [15:0] dcm_config_buf;
	reg [4:0] dcm_progstate = 5'd31;
	reg [15:0] dcm_data;
	wire [7:0] dcm_divider_s1 = (INPUT_FREQUENCY >> 1) - 8'd1;
	wire [7:0] dcm_multiplier_s1 = dcm_multiplier - 8'd1;

	always @ (posedge rx_dcm_progclk)
	begin
		// NOTE: Request frequency is divided by 2 to get the
		// multiplier (base clock is 2MHz).
		dcm_config_buf <= {clock_config[8:1], dcm_config_buf[15:8]};

		if (dcm_config_buf[7:0] > MAXIMUM_FREQUENCY_MULTIPLIER)
		       	dcm_multiplier <= MAXIMUM_FREQUENCY_MULTIPLIER;
		else if (dcm_config_buf[7:0] < 2)
			dcm_multiplier <= 8'd2;
		else
			dcm_multiplier <= dcm_config_buf[7:0];

		if (dcm_multiplier != current_dcm_multiplier && dcm_progstate == 5'd31 && rx_dcm_progdone)
		begin
			current_dcm_multiplier <= dcm_multiplier;
			dcm_progstate <= 5'd0;
			// DCM expects D-1 and M-1
			dcm_data <= {dcm_multiplier_s1, dcm_divider_s1};
		end

		if (dcm_progstate == 5'd0) {tx_dcm_progen, tx_dcm_progdata} <= 2'b11;
		if (dcm_progstate == 5'd1) {tx_dcm_progen, tx_dcm_progdata} <= 2'b10;
		if ((dcm_progstate >= 5'd2 && dcm_progstate <= 5'd9) || (dcm_progstate >= 5'd15 && dcm_progstate <= 5'd22))
		begin
			tx_dcm_progdata <= dcm_data[0];
			dcm_data <= {1'b0, dcm_data[15:1]};
		end

		if (dcm_progstate == 5'd10) {tx_dcm_progen, tx_dcm_progdata} <= 2'b00;
		if (dcm_progstate == 5'd11) {tx_dcm_progen, tx_dcm_progdata} <= 2'b00;
		if (dcm_progstate == 5'd12) {tx_dcm_progen, tx_dcm_progdata} <= 2'b00;

		if (dcm_progstate == 5'd13) {tx_dcm_progen, tx_dcm_progdata} <= 2'b11;
		if (dcm_progstate == 5'd14) {tx_dcm_progen, tx_dcm_progdata} <= 2'b11;

		if (dcm_progstate == 5'd23) {tx_dcm_progen, tx_dcm_progdata} <= 2'b00;
		if (dcm_progstate == 5'd24) {tx_dcm_progen, tx_dcm_progdata} <= 2'b00;
		if (dcm_progstate == 5'd25) {tx_dcm_progen, tx_dcm_progdata} <= 2'b10;
		if (dcm_progstate == 5'd26) {tx_dcm_progen, tx_dcm_progdata} <= 2'b00;

		if (dcm_progstate <= 5'd25) dcm_progstate <= dcm_progstate + 5'd1;

		if (dcm_progstate == 5'd26 && rx_dcm_progdone)
			dcm_progstate <= 5'd31;
	end

endmodule
