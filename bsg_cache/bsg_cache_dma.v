/**
 *  bsg_cache_dma.v
 */

`include "bsg_cache_pkt.vh"

module bsg_cache_dma
  #(parameter addr_width_p="inv"
   ,parameter data_width_p="inv"
   ,parameter block_size_in_words_p="inv"
   ,parameter lg_block_size_in_words_lp="inv"
   ,parameter lg_sets_lp="inv"
   ,parameter bsg_cache_dma_pkt_width_lp=`bsg_cache_dma_pkt_width(addr_width_p))
(
  input clock_i
  ,input reset_i
  
  // from miss_case
  ,input mc_send_fill_req_i
  ,input mc_send_evict_req_i
  ,input mc_fill_line_i
  ,input mc_evict_line_i
  ,input [addr_width_p-1:0] mc_pass_addr_i
  ,input start_set_i

  // to miss_case
  ,output logic finished_o

  ,input [lg_sets_lp-1:0] start_addr_i
  ,input [lg_block_size_in_words_lp-1:0] snoop_word_offset_i
  ,output logic [data_width_p-1:0] snoop_word_o
  
  // DMA request channel
  ,output logic [bsg_cache_dma_pkt_width_lp-1:0] dma_pkt_o
  ,output logic dma_pkt_v_o
  ,input dma_pkt_yumi_i

  // DMA read channel
  ,input [data_width_p-1:0] dma_data_i
  ,input dma_data_v_i
  ,output logic dma_data_ready_o

  // DMA write channel
  ,output logic [data_width_p-1:0] dma_data_o
  ,output logic dma_data_v_o
  ,input dma_data_yumi_i

  // data_mem
  ,output logic data_re_force_o
  ,output logic data_we_force_o
  ,output logic [7:0] data_mask_force_o
  ,output logic [lg_sets_lp+lg_block_size_in_words_lp-1:0] data_addr_force_o
  ,output logic [(2*data_width_p)-1:0] data_in_force_o
  ,input [(2*data_width_p)-1:0] raw_data_i
);

  typedef enum logic [2:0] {
    IDLE = 3'd0,
    REQ_SEND_FILL = 3'd1,
    REQ_SEND_EVICT = 3'd2,
    FILL_LINE = 3'd3,
    EVICT_LINE = 3'd4
  } dma_state_e;
  
  // incoming fill fifo
  // for fill, dequeue data from fifo.
  // each time data is dequeued, increment the counter.
  logic [data_width_p-1:0] dma_rdata;
  logic fill_fifo_v_lo;
  logic fill_fifo_yumi_li;
  bsg_two_fifo #(.width_p(data_width_p)) dma_fill_fifo (
    .clk_i(clock_i)
    ,.reset_i(reset_i)

    ,.ready_o(dma_data_ready_o)
    ,.data_i(dma_data_i)
    ,.v_i(dma_data_v_i)

    ,.v_o(fill_fifo_v_lo)
    ,.data_o(dma_rdata)
    ,.yumi_i(fill_fifo_yumi_li)
  );
  
  // outgoing evict fifo
  // for evict/flush, queue data read from data_meme to fifo.
  // each time data is queued, increment the counter. 
  logic [31:0] dma_wdata;
  logic evict_fifo_ready_lo;
  logic evict_fifo_v_li;
  assign dma_wdata = start_set_i
    ? raw_data_i[63:32]
    : raw_data_i[31:0];

  bsg_two_fifo #(.width_p(32)) dma_evict_fifo (
    .clk_i(clock_i)
    ,.reset_i(reset_i)

    ,.ready_o(evict_fifo_ready_lo)
    ,.data_i(dma_wdata)
    ,.v_i(evict_fifo_v_li)

    ,.v_o(dma_data_v_o)
    ,.data_o(dma_data_o)
    ,.yumi_i(dma_data_yumi_i)
  );

  dma_state_e dma_state_r;
  dma_state_e dma_state_n;

  logic [lg_block_size_in_words_lp:0] counter_r;
  logic [lg_block_size_in_words_lp:0] counter_n;

  always_ff @ (posedge clock_i) begin
    if (reset_i) begin
      dma_state_r <= IDLE;
      counter_r <= '0;
    end
    else begin
      dma_state_r <= dma_state_n;
      counter_r <= counter_n;
    end
  end

  `declare_bsg_cache_dma_pkt_s(addr_width_p);

  bsg_cache_dma_pkt_s dma_pkt_cast;
  assign dma_pkt_o = dma_pkt_cast;

  assign dma_pkt_cast.addr = mc_pass_addr_i;
  assign data_mask_force_o = start_set_i
    ? {4'b1111, 4'b0000}
    : {4'b0000, 4'b1111};

  assign data_addr_force_o = {start_addr_i, counter_r[lg_block_size_in_words_lp-1:0]};
  assign data_in_force_o = {2{dma_rdata}};


  always_comb begin
    finished_o = 1'b0;
    dma_pkt_v_o = 1'b0;
    counter_n = counter_r;
    dma_pkt_cast.write_not_read = 1'b0;
    data_we_force_o = 1'b0;
    data_re_force_o = 1'b0;
    fill_fifo_yumi_li = 1'b0;
    evict_fifo_v_li = 1'b0;
    
    case (dma_state_r)
      IDLE: begin
        dma_state_n = mc_send_fill_req_i ? REQ_SEND_FILL
          : (mc_send_evict_req_i ? REQ_SEND_EVICT
          : (mc_fill_line_i ? FILL_LINE
          : (mc_evict_line_i ? EVICT_LINE
          : IDLE)));
        counter_n = mc_fill_line_i ? (lg_block_size_in_words_lp+1)'(0)
          : (mc_evict_line_i ? (lg_block_size_in_words_lp+1)'(1)
          : counter_r);
        data_re_force_o = mc_evict_line_i;
      end
      
      REQ_SEND_FILL: begin
        dma_state_n = dma_pkt_yumi_i
          ? IDLE
          : REQ_SEND_FILL;
        dma_pkt_v_o = 1'b1;
        dma_pkt_cast.write_not_read = 1'b0;
        finished_o = dma_pkt_yumi_i;
      end

      REQ_SEND_EVICT: begin
        dma_state_n = dma_pkt_yumi_i
          ? IDLE
          : REQ_SEND_EVICT;
        dma_pkt_v_o = 1'b1;
        dma_pkt_cast.write_not_read = 1'b1;
        finished_o = dma_pkt_yumi_i;
      end
      
      FILL_LINE: begin
        dma_state_n = (counter_r == (block_size_in_words_p - 1)) & fill_fifo_v_lo
          ? IDLE
          : FILL_LINE;
        data_we_force_o = fill_fifo_v_lo;
        fill_fifo_yumi_li = fill_fifo_v_lo;
        counter_n = fill_fifo_v_lo
          ? counter_r + 1
          : counter_r;
        
        finished_o = (counter_r == (block_size_in_words_p - 1)) & fill_fifo_v_lo;

        if (snoop_word_offset_i == counter_r[lg_block_size_in_words_lp-1:0]
          & fill_fifo_v_lo) begin
          snoop_word_o <= dma_rdata;
        end
      end

      EVICT_LINE: begin
        dma_state_n = (counter_r == block_size_in_words_p) & evict_fifo_ready_lo
          ? IDLE
          : EVICT_LINE;
        counter_n = evict_fifo_ready_lo 
          ? counter_r + 1
          : counter_r;
        evict_fifo_v_li = 1'b1;
        data_re_force_o = evict_fifo_ready_lo & (counter_r != block_size_in_words_p);

        finished_o = (counter_r == block_size_in_words_p) & evict_fifo_ready_lo;
      end
    endcase
  end

endmodule 
